import Foundation
import ServiceManagement

enum AfterCapture: String, CaseIterable, Identifiable {
    /// Show the card and wait for «Скрыть».
    case ask
    /// Hide right away and show the card with «Вернуть».
    case auto
    var id: String { rawValue }
}

enum ClipboardScope: String, CaseIterable, Identifiable {
    /// Only bare images, the way screenshot tools put them on the clipboard.
    case screenshots
    /// Any image, including ones copied from a browser.
    case anyImage
    var id: String { rawValue }
}

/// User settings in UserDefaults. One shared instance, observed by SwiftUI.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var afterCapture: AfterCapture { didSet { d.set(afterCapture.rawValue, forKey: "afterCapture") } }
    @Published var fill: FillStyle { didSet { d.set(fill.rawValue, forKey: "fill") } }
    @Published var fillColor: FillColor { didSet { d.set(fillColor.rawValue, forKey: "fillColor") } }
    /// How long the original stays in memory for «Вернуть». 0 means not at all.
    @Published var keepOriginalMinutes: Int { didSet { d.set(keepOriginalMinutes, forKey: "keepOriginalMinutes") } }
    @Published var disabledKinds: Set<FindingKind> {
        didSet { d.set(disabledKinds.map(\.rawValue).sorted(), forKey: "disabledKinds") }
    }
    @Published var customWords: [String] { didSet { d.set(customWords, forKey: "customWords") } }
    @Published var watchFiles: Bool { didSet { d.set(watchFiles, forKey: "watchFiles") } }
    @Published var watchClipboard: Bool { didSet { d.set(watchClipboard, forKey: "watchClipboard") } }
    @Published var clipboardScope: ClipboardScope { didSet { d.set(clipboardScope.rawValue, forKey: "clipboardScope") } }
    /// Also replace CleanShot's own copy in its history folder, so its overlay hands out the
    /// cleaned picture too.
    @Published var replaceCleanShotHistory: Bool { didSet { d.set(replaceCleanShotHistory, forKey: "replaceCleanShotHistory") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var pausedUntil: Date? { didSet { d.set(pausedUntil, forKey: "pausedUntil") } }
    /// Folders where CleanShot saved files, learned from Spotlight. CleanShot keeps its export
    /// folder in a format that is not meant to be read by others.
    @Published var learnedFolders: [String] { didSet { d.set(learnedFolders, forKey: "learnedFolders") } }

    private init() {
        afterCapture = AfterCapture(rawValue: d.string(forKey: "afterCapture") ?? "") ?? .ask
        fill = FillStyle(rawValue: d.string(forKey: "fill") ?? "") ?? .solid
        fillColor = FillColor(rawValue: d.string(forKey: "fillColor") ?? "") ?? .ink
        keepOriginalMinutes = d.object(forKey: "keepOriginalMinutes") as? Int ?? 10
        disabledKinds = Set((d.stringArray(forKey: "disabledKinds") ?? []).compactMap(FindingKind.init(rawValue:)))
        customWords = d.stringArray(forKey: "customWords") ?? []
        watchFiles = d.object(forKey: "watchFiles") as? Bool ?? true
        watchClipboard = d.object(forKey: "watchClipboard") as? Bool ?? true
        clipboardScope = ClipboardScope(rawValue: d.string(forKey: "clipboardScope") ?? "") ?? .screenshots
        replaceCleanShotHistory = d.object(forKey: "replaceCleanShotHistory") as? Bool ?? true
        onboardingDone = d.bool(forKey: "onboardingDone")
        pausedUntil = d.object(forKey: "pausedUntil") as? Date
        learnedFolders = d.stringArray(forKey: "learnedFolders") ?? []
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    var detectorOptions: DetectorOptions {
        DetectorOptions(enabled: Set(FindingKind.allCases).subtracting(disabledKinds),
                        customWords: customWords, timeout: 60)
    }

    var redactStyle: RedactStyle { RedactStyle(fill: fill, color: fillColor) }

    func isEnabled(_ kind: FindingKind) -> Bool { !disabledKinds.contains(kind) }

    func setEnabled(_ kind: FindingKind, _ on: Bool) {
        if on { disabledKinds.remove(kind) } else { disabledKinds.insert(kind) }
    }

    // MARK: - Open at login (off unless the person turns it on)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("login item: \(error)")
            }
        }
    }
}
