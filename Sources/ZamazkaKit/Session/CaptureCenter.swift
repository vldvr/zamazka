import AppKit
import Combine
import UniformTypeIdentifiers

/// Receives pictures from every source, runs the detector, and puts the cleaned picture back
/// where each one came from.
@MainActor
final class CaptureCenter: ObservableObject {
    static let shared = CaptureCenter()

    /// Recent sessions, newest first.
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var busy = false

    private let prefs = Prefs.shared
    private lazy var folders = FolderWatcher { [weak self] url in self?.fileEvent(url) }
    private lazy var spotlight = SpotlightWatcher { [weak self] url in self?.fileEvent(url) }
    private(set) lazy var clipboard = ClipboardWatcher(pasteboard: pasteboard) { [weak self] snap, data in self?.clipboardImage(snap, data) }
    private let pasteboard: NSPasteboard

    /// The shared instance uses the general pasteboard; checks make their own with a private one.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    private var seen: [String: Date] = [:]
    private var ownWrites: [String: Date] = [:]
    private var lastCleanShotCapture: Date?
    private let launched = Date()
    private var timers: [Timer] = []
    private var bag: Set<AnyCancellable> = []
    private var running = 0 { didSet { busy = running > 0 } }

    /// Cleaned copies for dragging. A subfolder of its own: the app's Caches folder also holds
    /// Vision's compiled model (com.apple.e5rt.e5bundlecache), and deleting that one breaks text
    /// recognition until the next launch.
    static let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.vldvr.zamazka", isDirectory: true)
        .appendingPathComponent("Drag", isDirectory: true)

    // MARK: - Sources

    private(set) var started = false

    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.removeItem(at: Self.cacheFolder)
        clipboard.allowFileItems = { [weak self] in
            guard let t = self?.lastCleanShotCapture else { return false }
            return Date().timeIntervalSince(t) < 600
        }
        refreshSources()
        spotlight.start()
        // The system folder can change in ⌘⇧5 at any time; there is no notification for it.
        add(timer: 10) { [weak self] in self?.refreshSources() }
        // Keeps the text recogniser loaded, so a screenshot after a long pause is not slow.
        add(timer: 240) { if !Prefs.shared.isPaused { Detector.prewarm() } }

        Publishers.MergeMany(prefs.$watchFiles.map { _ in () }.eraseToAnyPublisher(),
                             prefs.$watchClipboard.map { _ in () }.eraseToAnyPublisher(),
                             prefs.$clipboardScope.map { _ in () }.eraseToAnyPublisher(),
                             prefs.$learnedFolders.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refreshSources() }
            .store(in: &bag)
    }

    private func add(timer interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    /// Stops every source, for a host app that hands screenshots back to a standalone Zamazka.
    func stop() {
        guard started else { return }
        started = false
        folders.stop()
        spotlight.stop()
        clipboard.stop()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        bag.removeAll()
    }

    func refreshSources() {
        guard started else { return }
        if prefs.watchFiles {
            var list = [ScreenshotPlaces.systemFolder, ScreenshotPlaces.desktop]
            list += prefs.learnedFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
            if FileManager.default.fileExists(atPath: ScreenshotPlaces.cleanShotMedia.path) {
                list.append(ScreenshotPlaces.cleanShotMedia)
            }
            folders.watch(list.filter { FileManager.default.fileExists(atPath: $0.path) })
        } else {
            folders.stop()
        }
        clipboard.scope = prefs.clipboardScope
        if prefs.watchClipboard { clipboard.start() } else { clipboard.stop() }
    }

    var watchedFolders: [URL] { folders.folders }

    // MARK: - Files

    private func fileEvent(_ url: URL) {
        guard prefs.watchFiles, !prefs.isPaused else { return }
        let path = url.standardizedFileURL.path
        if let t = ownWrites[path], Date().timeIntervalSince(t) < 5 { return }
        guard FileManager.default.fileExists(atPath: path), ScreenshotPlaces.isScreenshot(url) else { return }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate ?? .distantPast
        // Only new pictures: renaming or moving an old screenshot is not a new capture.
        guard Date().timeIntervalSince(created) < 120, created > launched.addingTimeInterval(-5) else { return }
        let stamp = path + "|" + String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        guard seen[stamp] == nil else { return }
        seen[stamp] = Date()
        seen = seen.filter { Date().timeIntervalSince($0.value) < 600 }

        let inHistory = ScreenshotPlaces.isInCleanShotMedia(url)
        if inHistory { lastCleanShotCapture = Date() }
        learnFolder(of: url, inHistory: inHistory)
        Log.write("file \(inHistory ? "history" : "screenshot") \(url.lastPathComponent)")

        Task {
            guard let loaded = await ImageFile.load(url) else {
                // CleanShot writes under a temporary name and renames it; that file is gone, not unreadable.
                if FileManager.default.fileExists(atPath: url.path) { Log.write("could not read \(url.lastPathComponent)") }
                return
            }
            Log.write("loaded \(loaded.image.width)x\(loaded.image.height)")
            let attrs = ImageFile.attributes(url, ImageFile.keptAttributes)
            let target: Target = inHistory ? .history(url) : .file(url)
            await handle(loaded, origin: ScreenshotPlaces.origin(of: url), target: target, originalData: loaded.data, attributes: attrs)
        }
    }

    /// Remembers a folder Spotlight found a screenshot in, so next time file events see it at once.
    private func learnFolder(of url: URL, inHistory: Bool) {
        guard !inHistory else { return }
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard !folders.folders.contains(where: { folder.path.hasPrefix($0.path) }),
              !folder.path.contains("/Library/") else { return }
        if !prefs.learnedFolders.contains(folder.path) {
            prefs.learnedFolders = Array((prefs.learnedFolders + [folder.path]).suffix(6))
        }
    }

    // MARK: - Clipboard

    private func clipboardImage(_ snapshot: ClipboardSnapshot, _ data: Data) {
        guard prefs.watchClipboard, !prefs.isPaused, let loaded = ImageFile.decode(data) else { return }
        Task {
            await handle(loaded, origin: lastCleanShotRecently ? .cleanShot : .system, target: .clipboard, snapshot: snapshot)
        }
    }

    private var lastCleanShotRecently: Bool {
        guard let t = lastCleanShotCapture else { return false }
        return Date().timeIntervalSince(t) < 600
    }

    // MARK: - Manual checks

    func checkFile(_ url: URL) {
        Task {
            guard let loaded = await ImageFile.load(url) else {
                NSSound.beep()
                return
            }
            let attrs = ImageFile.attributes(url, ImageFile.keptAttributes)
            await handle(loaded, origin: .other, target: .file(url), originalData: loaded.data, attributes: attrs, manual: true)
        }
    }

    func checkClipboard() {
        let pb = NSPasteboard.general
        let snapshot = ClipboardSnapshot.read(pb)
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let loaded = ImageFile.decode(data) else {
            NSSound.beep()
            return
        }
        Task { await handle(loaded, origin: .other, target: .clipboard, snapshot: snapshot, manual: true) }
    }

    func showDemo() {
        let image = SyntheticImage.chat(scale: 2)
        guard let data = ImageFile.png(image, dpi: 144), let loaded = ImageFile.decode(data) else { return }
        let session = Session(origin: .other, loaded: loaded, isDemo: true)
        insert(session)
        Task { await analyze(session, manual: true) }
    }

    // MARK: - Pipeline

    private func handle(_ loaded: LoadedImage, origin: CaptureOrigin, target: Target, originalData: Data? = nil,
                        attributes: [String: Data] = [:], snapshot: ClipboardSnapshot? = nil, manual: Bool = false) async {
        let key = ImageFile.key(loaded.image)
        // The same capture seen through another source (CleanShot history + clipboard + export).
        if !manual, let existing = sessions.first(where: { $0.key == key && Date().timeIntervalSince($0.created) < 180 && !$0.isDemo }) {
            existing.add(target, originalData: originalData, attributes: attributes)
            if target == .clipboard { existing.clipboardSnapshot = snapshot }
            Log.write("same capture, added \(target.place)")
            if existing.state == .applied, let cleaned = existing.cleaned { write(cleaned, to: target, of: existing) }
            if existing.state == .review || existing.state == .applied, existing.hasRealTarget {
                CardController.shared.show(existing)
            }
            return
        }
        let session = Session(origin: origin, loaded: loaded)
        session.add(target, originalData: originalData, attributes: attributes)
        if target == .clipboard { session.clipboardSnapshot = snapshot }
        insert(session)
        await analyze(session, manual: manual)
    }

    private func insert(_ session: Session) {
        sessions.insert(session, at: 0)
        if sessions.count > 8 {
            for old in sessions.dropFirst(8) {
                old.purgeOriginal()
                old.discardDragFile()
            }
            sessions = Array(sessions.prefix(8))
        }
    }

    private func analyze(_ session: Session, manual: Bool) async {
        guard let image = session.original else { return }
        Log.write("analysing \(session.id)")
        running += 1
        defer { running -= 1 }
        do {
            let analysis = try await Detector.analyze(image, options: prefs.detectorOptions)
            session.findings = analysis.findings
            Log.write(String(format: "analysed in %.2fs: %@", analysis.seconds, analysis.findings.kinds.map(\.rawValue).joined(separator: ",")))
            guard analysis.findings.hasStrong || manual else {
                session.state = .clean
                session.schedulePurge(after: 0)
                return
            }
            session.state = .review
            guard session.hasRealTarget || session.isDemo || manual else { return }
            if prefs.afterCapture == .auto, analysis.findings.hasStrong, !session.isDemo {
                apply(session)
            }
            CardController.shared.show(session)
        } catch {
            session.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            CardController.shared.show(session)
        }
    }

    func retry(_ session: Session) {
        session.state = .analyzing
        Task { await analyze(session, manual: true) }
    }

    // MARK: - Hide and undo

    func apply(_ session: Session) {
        guard let original = session.original else { return }
        guard let cleaned = Redactor.render(original, rects: session.enabledRects, style: prefs.redactStyle) else {
            session.state = .failed("Не удалось нарисовать заливку.")
            return
        }
        session.cleaned = cleaned
        session.note = nil
        if !session.isDemo {
            for target in session.targets { write(cleaned, to: target, of: session) }
        }
        makeDragFile(session, cleaned)
        session.state = .applied
        session.appliedAt = Date()
        session.schedulePurge(after: session.isDemo ? 60 : prefs.keepOriginalMinutes)
    }

    private func write(_ cleaned: CGImage, to target: Target, of session: Session) {
        switch target {
        case .file(let url), .history(let url):
            if case .history = target, !prefs.replaceCleanShotHistory { return }
            guard let data = ImageFile.encode(cleaned, as: session.type, dpi: session.dpi) else { return }
            let attrs = session.originalFile(url)?.attributes ?? ImageFile.attributes(url, ImageFile.keptAttributes)
            ownWrites[url.standardizedFileURL.path] = Date()
            do {
                try ImageFile.replace(url, with: data, attributes: attrs, markCleaned: true)
            } catch {
                session.note = "Файл не удалось заменить: \(error.localizedDescription)"
            }
        case .clipboard:
            guard let png = ImageFile.png(cleaned, dpi: session.dpi) else { return }
            let expected = session.clipboardWrittenCount ?? session.clipboardSnapshot?.changeCount
            if let count = clipboard.writeCleaned(png, tiff: nil, replacing: expected) {
                session.clipboardWrittenCount = count
            } else {
                session.note = "В буфере обмена уже другое, его Замазка не трогала. Перетащите картинку из карточки."
            }
        }
    }

    func undo(_ session: Session) {
        guard session.canUndo else { return }
        for target in session.targets {
            switch target {
            case .file(let url), .history(let url):
                guard let original = session.originalFile(url) else { continue }
                ownWrites[url.standardizedFileURL.path] = Date()
                try? ImageFile.replace(url, with: original.data, attributes: original.attributes, markCleaned: false)
            case .clipboard:
                if let snap = session.clipboardSnapshot, let count = session.clipboardWrittenCount,
                   clipboard.restore(snap, replacing: count) {
                    session.clipboardWrittenCount = nil
                    session.clipboardSnapshot = ClipboardSnapshot.read(NSPasteboard.general)
                }
            }
        }
        session.cleaned = nil
        session.discardDragFile()
        session.state = .review
        session.appliedAt = nil
    }

    private func makeDragFile(_ session: Session, _ cleaned: CGImage) {
        session.discardDragFile()
        let folder = Self.cacheFolder.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(session.fileName + ".png")
        guard let data = ImageFile.png(cleaned, dpi: session.dpi) else { return }
        try? data.write(to: url)
        session.dragFile = url
    }

    func shutdown() {
        for s in sessions { s.purgeOriginal() }
        try? FileManager.default.removeItem(at: Self.cacheFolder)
    }
}
