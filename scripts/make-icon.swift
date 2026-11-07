// Draws the app icon: a marker-yellow tile with a sheet of text, one line covered with ink.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Tile.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x3A2A00, 0.35))
ctx.addPath(rounded(tile, 186))
ctx.setFillColor(color(0xF5B300))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(rounded(tile, 186))
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0xFFD24A), color(0xF2AA00)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Sheet of paper, slightly lifted.
let sheet = CGRect(x: 232, y: 262, width: 560, height: 500)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x5A3F00, 0.35))
ctx.addPath(rounded(sheet, 46))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Lines of text: grey bars of different lengths.
let lines: [(y: CGFloat, w: CGFloat)] = [(672, 380), (592, 300), (512, 420), (432, 250), (352, 340)]
for (i, l) in lines.enumerated() where i != 2 {
    ctx.addPath(rounded(CGRect(x: 300, y: l.y - 14, width: l.w, height: 28), 14))
    ctx.setFillColor(color(0xC9CDD2))
    ctx.fillPath()
}

// The hidden line: an ink bar wider and taller than the text it covers.
let bar = CGRect(x: 284, y: 512 - 34, width: 456, height: 68)
ctx.addPath(rounded(bar, 16))
ctx.setFillColor(color(0x16181B))
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
