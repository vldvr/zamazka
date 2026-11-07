import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded image plus what is needed to write a replacement in the same format.
struct LoadedImage {
    let data: Data
    let image: CGImage
    let type: UTType
    let dpi: Double?
}

enum ImageFile {
    static func decode(_ data: Data) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let typeID = CGImageSourceGetType(source) as String? ?? UTType.png.identifier
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double
        return LoadedImage(data: data, image: image, type: UTType(typeID) ?? .png, dpi: dpi)
    }

    /// Reads a file that may still be being written: retries for about two seconds.
    static func load(_ url: URL) async -> LoadedImage? {
        var lastSize = -1
        for attempt in 0..<14 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            // Wait until the size stops changing, then decode.
            if data.count != lastSize { lastSize = data.count; if attempt < 13 { continue } }
            if let loaded = decode(data) { return loaded }
        }
        return nil
    }

    /// Encodes `image` in `type`. Only resolution is carried over: no EXIF, no thumbnails, no
    /// comments, nothing else from the original file.
    static func encode(_ image: CGImage, as type: UTType, dpi: Double?) -> Data? {
        let out = NSMutableData()
        let writable: UTType = [UTType.png, .jpeg, .heic, .tiff].first { type.conforms(to: $0) } ?? .png
        guard let dest = CGImageDestinationCreateWithData(out, writable.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
        if writable == .jpeg || writable == .heic { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func png(_ image: CGImage, dpi: Double? = nil) -> Data? { encode(image, as: .png, dpi: dpi) }

    // MARK: - Writing in place

    /// Attributes worth keeping on a replaced screenshot so Finder and Spotlight still know what
    /// it is. Everything else is dropped.
    static let keptAttributes = [
        "com.apple.metadata:kMDItemIsScreenCapture",
        "com.apple.metadata:kMDItemScreenCaptureType",
    ]

    static func attributes(_ url: URL, _ names: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        for name in names {
            let size = getxattr(url.path, name, nil, 0, 0, 0)
            guard size >= 0 else { continue }
            var buf = Data(count: size)
            let read = buf.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
            if read >= 0 { out[name] = buf }
        }
        return out
    }

    static func setAttributes(_ url: URL, _ attrs: [String: Data]) {
        for (name, value) in attrs {
            _ = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, 0) }
        }
    }

    /// Replaces the file's contents. The write goes to a temporary file in the same folder and
    /// is then swapped in, so a reader never sees half a picture.
    static func replace(_ url: URL, with data: Data, attributes attrs: [String: Data], markCleaned: Bool) throws {
        try data.write(to: url, options: .atomic)
        var all = attrs
        if markCleaned { all[ScreenshotPlaces.cleanedAttribute] = Data("1".utf8) }
        else { removexattr(url.path, ScreenshotPlaces.cleanedAttribute, 0) }
        setAttributes(url, all)
    }

    // MARK: - Identity

    /// Same picture, whatever the encoding: size plus a hash of a 16×16 grey thumbnail. Used to
    /// notice that CleanShot's history file, its exported file and its clipboard copy are one
    /// capture.
    static func key(_ image: CGImage) -> String {
        let side = 16
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return "\(image.width)x\(image.height)"
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = Data(bytes: ctx.data!, count: side * side).map { $0 >> 3 } // ignore tiny re-encoding noise
        let digest = SHA256.hash(data: Data(bytes))
        return "\(image.width)x\(image.height)-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
