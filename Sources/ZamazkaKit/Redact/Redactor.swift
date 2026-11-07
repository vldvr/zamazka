import CoreGraphics
import Foundation

/// How hidden areas look. Neither style keeps anything from the pixels underneath.
public enum FillStyle: String, CaseIterable, Identifiable, Sendable {
    /// One flat colour.
    case solid
    /// Random blocks in the colours around the area. Looks like a mosaic but is made from
    /// noise, not from the hidden pixels, so there is nothing to reverse.
    case noise

    public var id: String { rawValue }
    public var title: String { self == .solid ? "Сплошная заливка" : "Шум" }
}

public enum FillColor: String, CaseIterable, Identifiable, Sendable {
    case ink, background
    public var id: String { rawValue }
    public var title: String { self == .ink ? "Тёмная" : "Под цвет фона" }
}

public struct RedactStyle: Equatable, Sendable {
    public var fill: FillStyle
    public var color: FillColor
    public init(fill: FillStyle = .solid, color: FillColor = .ink) {
        self.fill = fill
        self.color = color
    }
}

/// Paints over areas of an image. The result is a new bitmap: the hidden pixels are gone, there
/// are no layers or objects that could be moved aside later.
public enum Redactor {
    /// The ink colour, also used in the interface for the "hidden" state.
    public static let ink: (r: UInt8, g: UInt8, b: UInt8) = (0x16, 0x18, 0x1B)

    /// `rects` are in pixels with the origin at the top left.
    public static func render(_ image: CGImage, rects: [CGRect], style: RedactStyle) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        // Sample every ring before painting anything, so neighbouring areas don't sample paint.
        let areas = rects.map { $0.integral.intersection(bounds) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        let rings = areas.map { ringColours(around: $0, pixels: pixels, width: w, height: h) }

        var rng = SystemRandomNumberGenerator()
        for (area, ring) in zip(areas, rings) {
            // CGContext has its origin at the bottom left.
            let flipped = CGRect(x: area.minX, y: CGFloat(h) - area.maxY, width: area.width, height: area.height)
            switch style.fill {
            case .solid:
                let c = style.color == .ink ? RGB(ink.r, ink.g, ink.b) : (ring.median ?? RGB(ink.r, ink.g, ink.b))
                ctx.setFillColor(c.cgColor)
                let radius = min(area.height * 0.16, 6)
                ctx.addPath(CGPath(roundedRect: flipped, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            case .noise:
                // Flat base first: rounding of block sizes must never leave a pixel uncovered.
                let base = ring.median ?? RGB(ink.r, ink.g, ink.b)
                ctx.setFillColor(base.cgColor)
                ctx.fill(flipped)
                let block = max(4, (area.height / 3).rounded())
                var y = flipped.minY
                while y < flipped.maxY {
                    var x = flipped.minX
                    while x < flipped.maxX {
                        let pick = ring.samples.isEmpty ? base : ring.samples[Int.random(in: 0..<ring.samples.count, using: &rng)]
                        let jitter = Int.random(in: -18...18, using: &rng)
                        ctx.setFillColor(pick.shifted(jitter).cgColor)
                        ctx.fill(CGRect(x: x, y: y, width: min(block, flipped.maxX - x), height: min(block, flipped.maxY - y)))
                        x += block
                    }
                    y += block
                }
            }
        }
        return ctx.makeImage()
    }

    struct RGB: Equatable {
        var r: UInt8, g: UInt8, b: UInt8
        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
        var cgColor: CGColor {
            CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        var luma: Int { (Int(r) * 299 + Int(g) * 587 + Int(b) * 114) / 1000 }
        func shifted(_ d: Int) -> RGB {
            func c(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, Int(v) + d))) }
            return RGB(c(r), c(g), c(b))
        }
    }

    struct Ring {
        var samples: [RGB]
        var median: RGB? {
            guard !samples.isEmpty else { return nil }
            return samples.sorted { $0.luma < $1.luma }[samples.count / 2]
        }
    }

    /// Pixels in a thin band just outside the area. Only those decide the colour, so the fill
    /// says nothing about what was inside.
    static func ringColours(around r: CGRect, pixels: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int) -> Ring {
        let band = 3
        let x0 = max(0, Int(r.minX) - band), x1 = min(w - 1, Int(r.maxX) + band - 1)
        let y0 = max(0, Int(r.minY) - band), y1 = min(h - 1, Int(r.maxY) + band - 1)
        guard x0 <= x1, y0 <= y1 else { return Ring(samples: []) }
        var out: [RGB] = []
        let step = max(1, (x1 - x0 + y1 - y0) / 400)
        func sample(_ x: Int, _ yTop: Int) {
            // Buffer rows run bottom-up relative to our top-left coordinates.
            let row = h - 1 - yTop
            let i = (row * w + x) * 4
            let a = Int(pixels[i + 3])
            guard a > 200 else { return } // skip transparent window-shadow pixels
            out.append(RGB(pixels[i], pixels[i + 1], pixels[i + 2]))
        }
        let innerTop = Int(r.minY), innerBottom = Int(r.maxY)
        let innerLeft = Int(r.minX), innerRight = Int(r.maxX)
        for y in stride(from: y0, through: y1, by: 1) {
            if y >= innerTop && y < innerBottom {
                if y % step != 0 { continue }
                for x in stride(from: x0, to: innerLeft, by: 1) { sample(x, y) }
                for x in stride(from: innerRight, through: x1, by: 1) { sample(x, y) }
            } else {
                for x in stride(from: x0, through: x1, by: step) { sample(x, y) }
            }
        }
        return Ring(samples: out)
    }
}
