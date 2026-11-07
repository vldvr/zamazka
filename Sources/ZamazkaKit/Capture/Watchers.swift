import AppKit
import CoreServices
import Foundation

/// File-system events for a set of folders. Reports image files that were created or moved in.
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private(set) var folders: [URL] = []
    private let onFile: (URL) -> Void

    init(onFile: @escaping (URL) -> Void) {
        self.onFile = onFile
    }

    func watch(_ newFolders: [URL]) {
        let unique = Array(Set(newFolders.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        guard unique != folders else { return }
        stop()
        folders = unique
        guard !unique.isEmpty else { return }
        Log.write("watching \(unique.map(\.path))")

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var urls: [URL] = []
            for i in 0..<count {
                let f = Int(flags[i])
                let isFile = f & kFSEventStreamEventFlagItemIsFile != 0
                let relevant = f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemXattrMod) != 0
                if isFile, relevant, i < list.count { urls.append(URL(fileURLWithPath: list[i])) }
            }
            MainActor.assumeIsolated {
                for url in urls { watcher.onFile(url) }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, unique.map(\.path) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.12, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        folders = []
    }
}

/// Spotlight's live query for files flagged as screen captures anywhere in the home folder.
/// Catches folders nobody told us about (CleanShot's export folder, a changed system folder).
/// A second or so slower than file events, so it is the safety net, not the main path.
@MainActor
final class SpotlightWatcher {
    private let query = NSMetadataQuery()
    private let onFile: (URL) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onFile: @escaping (URL) -> Void) {
        self.onFile = onFile
    }

    func start() {
        guard !query.isStarted else { return }
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.2
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let urls = added.compactMap { ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map(URL.init(fileURLWithPath:)) }
            MainActor.assumeIsolated {
                for url in urls { self?.onFile(url) }
            }
        })
        query.start()
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// What was on the clipboard, item by item, so it can be put back exactly.
struct ClipboardSnapshot {
    var items: [[NSPasteboard.PasteboardType: Data]]
    var changeCount: Int

    static func read(_ pb: NSPasteboard) -> ClipboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type] = data } }
            return out
        }
        return ClipboardSnapshot(items: items, changeCount: pb.changeCount)
    }

    /// Writes the items back. Returns the new change count.
    @discardableResult
    func restore(to pb: NSPasteboard) -> Int {
        pb.clearContents()
        let objects = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(objects)
        return pb.changeCount
    }
}

/// Watches the clipboard change counter, which can be read without asking anyone. Contents are
/// read only when the types say it is an image, and only then can macOS ask the person whether
/// Замазка may paste from other apps.
@MainActor
final class ClipboardWatcher {
    static let cleanedType = NSPasteboard.PasteboardType("com.vldvr.zamazka.cleaned")
    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
    /// Types that mean the image came from a web page or a document, not from a screenshot tool.
    private static let documentTypes: Set<String> = [
        "public.html", "Apple HTML pasteboard type", "public.rtf", "com.apple.webarchive", "public.url",
        "org.chromium.source-url", "org.chromium.internal.source-rfh-token", "com.apple.flat-rtfd",
        "org.mozilla.custom-clipdata",
    ]
    /// Password managers and clipboard tools mark private items this way (nspasteboard.org).
    private static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    private let pb: NSPasteboard
    private var timer: Timer?
    private var lastCount: Int
    private var ownCounts: Set<Int> = []
    private let onImage: (ClipboardSnapshot, Data) -> Void
    var scope: ClipboardScope = .screenshots
    var allowFileItems: () -> Bool = { false }

    /// `pasteboard` is the general one except in checks, which use a private one.
    init(pasteboard: NSPasteboard = .general, onImage: @escaping (ClipboardSnapshot, Data) -> Void) {
        self.pb = pasteboard
        self.onImage = onImage
        lastCount = pasteboard.changeCount
    }

    /// One poll, for checks.
    func poll() { tick() }

    func start() {
        guard timer == nil else { return }
        lastCount = pb.changeCount
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Our own writes must not be checked again.
    func noteOwnWrite(_ count: Int) {
        ownCounts.insert(count)
        lastCount = max(lastCount, count)
    }

    var accessDenied: Bool {
        if #available(macOS 15.4, *) { return pb.accessBehavior == .alwaysDeny }
        return false
    }

    var accessAsksEveryTime: Bool {
        if #available(macOS 15.4, *) { return pb.accessBehavior == .ask }
        return false
    }

    private func tick() {
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard !ownCounts.contains(count) else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        Log.write("clipboard changed \(count): \(types.sorted())")
        guard !types.contains(Self.cleanedType.rawValue), types.isDisjoint(with: Self.privateTypes) else { return }
        let imageType = Self.imageTypes.first(where: { types.contains($0.rawValue) })
        let hasFile = types.contains("public.file-url")
        guard imageType != nil || hasFile else { return }
        if scope == .screenshots, !hasFile, !types.isDisjoint(with: Self.documentTypes) { return }
        guard !accessDenied else { Log.write("clipboard access denied"); return }

        if hasFile {
            // A copied file. Finder puts the file's icon next to its URL, CleanShot's Copy may put
            // the capture file there. Reading the URL is reading the clipboard, so it is done only
            // when a screenshot tool is around: CleanShot just took a picture or is running.
            guard allowFileItems() || cleanShotRunning else { return }
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            Log.write("clipboard files: \(urls.map(\.lastPathComponent))")
            let shot = urls.first { url in
                ScreenshotPlaces.imageExtensions.contains(url.pathExtension.lowercased())
                    && (ScreenshotPlaces.isInCleanShotMedia(url) || ScreenshotPlaces.hasAttribute(ScreenshotPlaces.screenCaptureAttribute, url))
            }
            guard shot != nil || (scope == .anyImage && imageType != nil) else { return }
            let snapshot = ClipboardSnapshot.read(pb)
            guard snapshot.changeCount == count else { return }
            let data = imageType.flatMap { snapshot.items.first?[$0] } ?? shot.flatMap { try? Data(contentsOf: $0) }
            if let data { onImage(snapshot, data) }
            return
        }

        guard let imageType else { return }
        let snapshot = ClipboardSnapshot.read(pb)
        guard snapshot.changeCount == count,
              let data = snapshot.items.first?[imageType] ?? pb.data(forType: imageType) else { return }
        onImage(snapshot, data)
    }

    private var cleanShotRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ScreenshotPlaces.cleanShotBundleID).isEmpty
    }

    /// Puts a cleaned PNG on the clipboard. Returns the change count, or nil if the clipboard
    /// changed since `expected` (the person copied something else; we must not overwrite it).
    func writeCleaned(_ png: Data, tiff: Data?, replacing expected: Int?) -> Int? {
        if let expected, pb.changeCount != expected { return nil }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff { item.setData(tiff, forType: .tiff) }
        item.setData(Data(), forType: Self.cleanedType)
        pb.writeObjects([item])
        let c = pb.changeCount
        noteOwnWrite(c)
        return c
    }

    func restore(_ snapshot: ClipboardSnapshot, replacing expected: Int) -> Bool {
        guard pb.changeCount == expected else { return false }
        let c = snapshot.restore(to: pb)
        noteOwnWrite(c)
        return true
    }

    var currentCount: Int { pb.changeCount }

    /// Reads the clipboard once on request, so macOS shows its paste permission prompt while the
    /// person is looking at the onboarding window rather than after their first screenshot.
    func requestAccess() {
        _ = pb.data(forType: .png) ?? pb.data(forType: .string)
    }
}
