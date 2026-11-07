import AppKit
import UniformTypeIdentifiers

/// A place where a captured picture lives and where the cleaned one goes back to.
enum Target: Equatable {
    /// A screenshot file: the system folder, CleanShot's export folder, a picked file.
    case file(URL)
    /// CleanShot's own copy in its history folder.
    case history(URL)
    case clipboard

    var place: String {
        switch self {
        case .file(let url):
            let folder = url.deletingLastPathComponent().standardizedFileURL
            if folder == ScreenshotPlaces.desktop.standardizedFileURL { return "Рабочий стол" }
            return FileManager.default.displayName(atPath: folder.path)
        case .history: return "история CleanShot"
        case .clipboard: return "буфер обмена"
        }
    }
}

/// One captured picture, from detection to «Скрыть» and «Вернуть».
@MainActor
final class Session: ObservableObject, Identifiable {
    enum State: Equatable {
        case analyzing, review, applied, clean
        case failed(String)
    }

    let id = UUID()
    let created = Date()
    let origin: CaptureOrigin
    let key: String
    let isDemo: Bool
    let type: UTType
    let dpi: Double?
    let size: CGSize

    @Published private(set) var targets: [Target] = []
    @Published var findings: [Finding] = []
    @Published var state: State = .analyzing
    /// Kept in memory only, and only for as long as the settings say.
    @Published private(set) var original: CGImage?
    @Published var cleaned: CGImage?
    /// A remark under the result, e.g. that the clipboard already holds something else.
    @Published var note: String?
    @Published var appliedAt: Date?

    /// Original bytes and attributes of every file target, for «Вернуть».
    private(set) var originalFiles: [URL: (data: Data, attributes: [String: Data])] = [:]
    var clipboardSnapshot: ClipboardSnapshot?
    var clipboardWrittenCount: Int?
    /// The cleaned picture as a PNG file, for dragging into a chat.
    var dragFile: URL?
    private var purgeTimer: Timer?

    init(origin: CaptureOrigin, loaded: LoadedImage, isDemo: Bool = false) {
        self.origin = origin
        self.key = ImageFile.key(loaded.image)
        self.isDemo = isDemo
        self.type = loaded.type
        self.dpi = loaded.dpi
        self.size = CGSize(width: loaded.image.width, height: loaded.image.height)
        self.original = loaded.image
    }

    // MARK: - Targets

    func add(_ target: Target, originalData: Data? = nil, attributes: [String: Data] = [:]) {
        guard !targets.contains(target) else { return }
        targets.append(target)
        switch target {
        case .file(let url), .history(let url):
            if let originalData { originalFiles[url] = (originalData, attributes) }
        case .clipboard:
            break
        }
    }

    func originalFile(_ url: URL) -> (data: Data, attributes: [String: Data])? { originalFiles[url] }

    /// Shown in the card when the session has somewhere to put the result.
    var hasRealTarget: Bool {
        targets.contains { if case .history = $0 { return Prefs.shared.replaceCleanShotHistory } else { return true } }
    }

    var placesText: String {
        let names = targets.map(\.place)
        var unique: [String] = []
        for n in names where !unique.contains(n) { unique.append(n) }
        return unique.joined(separator: ", ")
    }

    var fileName: String {
        for t in targets {
            if case .file(let url) = t { return url.deletingPathExtension().lastPathComponent }
        }
        return origin == .cleanShot ? "CleanShot" : "Снимок экрана"
    }

    // MARK: - Findings

    func toggle(_ id: UUID) {
        guard let i = findings.firstIndex(where: { $0.id == id }) else { return }
        if findings[i].kind == .manual {
            findings.remove(at: i)
        } else {
            findings[i].enabled.toggle()
        }
    }

    func toggleKind(_ kind: FindingKind) {
        let on = !findings.filter { $0.kind == kind }.allSatisfy(\.enabled)
        for i in findings.indices where findings[i].kind == kind { findings[i].enabled = on }
    }

    func addManual(_ rect: CGRect) {
        let bounded = rect.intersection(CGRect(origin: .zero, size: size)).integral
        guard bounded.width >= 4, bounded.height >= 4 else { return }
        findings.append(Finding(kind: .manual, rects: [bounded]))
    }

    var enabledRects: [CGRect] { findings.filter(\.enabled).flatMap(\.rects) }

    // MARK: - Keeping the original

    var canUndo: Bool { state == .applied && original != nil && !isDemo }

    /// Forgets the original after `minutes`. Zero forgets it at once.
    func schedulePurge(after minutes: Int) {
        purgeTimer?.invalidate()
        if minutes <= 0 { purgeOriginal(); return }
        let t = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeOriginal() }
        }
        RunLoop.main.add(t, forMode: .common)
        purgeTimer = t
    }

    /// Drops the original from memory and overwrites the byte buffers this session owns. The
    /// decoded bitmap is released, not overwritten: CoreGraphics owns that memory.
    func purgeOriginal() {
        purgeTimer?.invalidate()
        purgeTimer = nil
        for url in Array(originalFiles.keys) {
            let count = originalFiles[url]?.data.count ?? 0
            originalFiles[url]?.data.resetBytes(in: 0..<count)
        }
        originalFiles = [:]
        if var snap = clipboardSnapshot {
            clipboardSnapshot = nil
            for i in snap.items.indices {
                for k in Array(snap.items[i].keys) {
                    let count = snap.items[i][k]?.count ?? 0
                    snap.items[i][k]?.resetBytes(in: 0..<count)
                }
            }
        }
        if state == .applied || state == .clean { original = nil }
        Log.write("original purged for \(id)")
    }

    func discardDragFile() {
        if let dragFile { try? FileManager.default.removeItem(at: dragFile.deletingLastPathComponent()) }
        dragFile = nil
    }
}

/// «1 место», «3 места», «5 мест».
func places(_ n: Int) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return "\(n) место" }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) места" }
    return "\(n) мест"
}
