import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Load the text recogniser now: the first request after launch can take 20+ seconds.
        Detector.prewarm()
        StatusItemController.shared.install()
        CaptureCenter.shared.start()

        let args = CommandLine.arguments
        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CaptureCenter.shared.showDemo() }
        } else if !Prefs.shared.onboardingDone || args.contains("--onboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { OnboardingWindowController.shared.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaptureCenter.shared.shutdown()
    }
}

public enum ZamazkaMain {
    private static var delegate: AppDelegate?

    @MainActor
    public static func run() {
        if CLI.handle(CommandLine.arguments) { return }
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.run()
    }
}
