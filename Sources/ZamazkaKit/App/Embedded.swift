import AppKit

/// Zamazka inside another app (Redakciya): the same sources, detector and cards, while the host owns
/// the menu bar icon, the login item and the first-run window. The standalone app does not use this.
@MainActor
public enum ZamazkaEmbedded {
    public private(set) static var isEmbedded = false
    /// Where cards appear: the host's menu bar button.
    public static var anchorScreen: () -> NSScreen? = { nil }
    public static var anchorFrame: () -> CGRect? = { nil }

    public static var isRunning: Bool { CaptureCenter.shared.started }

    public static func start() {
        isEmbedded = true
        Detector.prewarm()
        CaptureCenter.shared.start()
    }

    public static func stop() {
        CaptureCenter.shared.stop()
    }

    /// Before the host quits: originals kept in memory and drag copies go away, as in Zamazka.
    public static func shutdown() {
        CaptureCenter.shared.shutdown()
    }

    /// Zamazka's own menu items: status, recent screenshots, check a file or the clipboard, pause, settings.
    public static func addMenuItems(to menu: NSMenu) {
        StatusItemController.shared.addItems(to: menu, embedded: true)
    }

    public static func showSettings() { SettingsWindowController.shared.show() }
    public static func showDemo() { CaptureCenter.shared.showDemo() }

    /// Zamazka's own first-run steps (screenshot folder, thumbnail), once.
    public static func showOnboardingIfNeeded() {
        guard !Prefs.shared.onboardingDone else { return }
        OnboardingWindowController.shared.show()
    }
}
