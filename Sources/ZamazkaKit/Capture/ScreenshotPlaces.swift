import AppKit
import Foundation

/// Where screenshots land and how to recognise one.
enum ScreenshotPlaces {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    static let cleanShotBundleID = "pl.maketheweb.cleanshotx"
    /// CleanShot keeps every capture here for its overlay and history.
    static let cleanShotMedia = home.appendingPathComponent("Library/Application Support/CleanShot/media", isDirectory: true)

    // MARK: - System screenshot settings

    private static func screencapture(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, "com.apple.screencapture" as CFString)
    }

    /// Folder for ⌘⇧3/⌘⇧4/⌘⇧5. Recent macOS keeps it under `location-screenshot`, older under
    /// `location`; with neither it is the Desktop.
    static var systemFolder: URL {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        for key in ["location-screenshot", "location"] {
            if let path = screencapture(key) as? String, !path.isEmpty {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
            }
        }
        return desktop
    }

    /// ⌘⇧5 can be set to put every screenshot on the clipboard instead of a file. macOS 27
    /// keeps it under `target-screenshot`, older versions under `target`.
    static var systemTargetIsClipboard: Bool {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        let value = (screencapture("target-screenshot") as? String) ?? (screencapture("target") as? String)
        return value == "clipboard"
    }

    /// The floating thumbnail after a screenshot. While it is on screen the file is not saved
    /// yet, and dragging the thumbnail into a chat sends the original before anyone can check it.
    static var showsThumbnail: Bool {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        return (screencapture("show-thumbnail") as? Bool) ?? true
    }

    static func setThumbnail(_ on: Bool) {
        CFPreferencesSetAppValue("show-thumbnail" as CFString, on as CFBoolean, "com.apple.screencapture" as CFString)
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
    }

    static func setSystemFolder(_ url: URL) {
        for key in ["location-screenshot", "location"] {
            CFPreferencesSetAppValue(key as CFString, url.path as CFString, "com.apple.screencapture" as CFString)
        }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // The screenshot service reads the folder at start.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["SystemUIServer"]
        try? task.run()
    }

    /// A folder outside iCloud for people whose Desktop syncs.
    static var suggestedLocalFolder: URL {
        home.appendingPathComponent("Pictures/Снимки экрана", isDirectory: true)
    }

    /// True when files in `folder` are uploaded somewhere by a sync client: iCloud Desktop and
    /// Documents, iCloud Drive, or anything under CloudStorage (Dropbox, Яндекс Диск, Google Drive).
    /// The original can be uploaded before it is replaced.
    static func isSynced(_ folder: URL) -> Bool {
        // iCloud Desktop and Documents mark the folder itself as ubiquitous.
        if let v = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]), v.isUbiquitousItem == true { return true }
        let path = folder.resolvingSymlinksInPath().path
        if path.hasPrefix(home.appendingPathComponent("Library/Mobile Documents").path) { return true }
        if path.hasPrefix(home.appendingPathComponent("Library/CloudStorage").path) { return true }
        // A subfolder of a synced Desktop or Documents.
        for root in [desktop, home.appendingPathComponent("Documents", isDirectory: true)] where path.hasPrefix(root.path + "/") {
            if let v = try? root.resourceValues(forKeys: [.isUbiquitousItemKey]), v.isUbiquitousItem == true { return true }
        }
        return false
    }

    // MARK: - CleanShot

    static var cleanShotInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleanShotBundleID) != nil
    }

    static func isInCleanShotMedia(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(cleanShotMedia.standardizedFileURL.path)
    }

    // MARK: - Recognising a screenshot file

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    /// Set on files this app wrote, so they are not checked again.
    static let cleanedAttribute = "com.vldvr.zamazka.cleaned"

    /// Both the system and CleanShot put the Spotlight "screen capture" flag on the file itself,
    /// as an extended attribute, before Spotlight indexes it. Reading it is instant.
    static func hasAttribute(_ name: String, _ url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, 0) >= 0
    }

    static func isScreenshot(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              !url.lastPathComponent.hasPrefix("."),
              !hasAttribute(cleanedAttribute, url) else { return false }
        return hasAttribute(screenCaptureAttribute, url) || nameLooksLikeScreenshot(url.lastPathComponent)
    }

    /// Fallback for files without the flag: the localized «Screenshot» word in every language the
    /// screenshot service ships, plus CleanShot's own prefix.
    static func nameLooksLikeScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        return screenshotWords.contains { lower.hasPrefix($0) }
    }

    static let screenshotWords: [String] = {
        var words: Set<String> = ["screenshot", "screen shot", "снимок экрана", "cleanshot "]
        let table = URL(fileURLWithPath: "/System/Library/CoreServices/screencaptureui.app/Contents/Resources/Localizable.loctable")
        if let data = try? Data(contentsOf: table),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for case let strings as [String: Any] in plist.values {
                if let word = strings["Screenshot"] as? String { words.insert(word.lowercased()) }
            }
        }
        return Array(words)
    }()

    /// What took this screenshot, for the card's caption.
    static func origin(of url: URL) -> CaptureOrigin {
        if isInCleanShotMedia(url) || url.lastPathComponent.hasPrefix("CleanShot ") { return .cleanShot }
        return .system
    }
}

enum CaptureOrigin: String {
    case system, cleanShot, other

    var title: String {
        switch self {
        case .system: return "Снимок экрана"
        case .cleanShot: return "CleanShot"
        case .other: return "Картинка"
        }
    }
}
