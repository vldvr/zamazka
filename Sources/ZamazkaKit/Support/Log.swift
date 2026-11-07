import Foundation

/// Opt-in trace for debugging capture sources:
///   defaults write com.vldvr.zamazka debugLog -bool true
/// then read ~/Library/Logs/Zamazka.log. Never logs recognised text or image contents,
/// only events, paths and pasteboard type names.
enum Log {
    static let enabled = UserDefaults.standard.bool(forKey: "debugLog") || ProcessInfo.processInfo.environment["ZAMAZKA_LOG"] != nil
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Zamazka.log")
    private static let lock = NSLock()

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        lock.lock(); defer { lock.unlock() }
        if ProcessInfo.processInfo.environment["ZAMAZKA_LOG"] == "stderr" {
            FileHandle.standardError.write(Data(line.utf8))
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
