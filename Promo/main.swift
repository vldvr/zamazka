// A 9:16 promo video for Reels, Shorts and TikTok, drawn frame by frame from the app's own parts:
// the invented screenshots, the real detector and the real redactor. No screen recording, no
// real data, no third-party music (sounds are synthesized here).
//   swift run zamazka-reel                       build/reel/zamazka-reel.mp4, 1080×1920, 60 fps
//   swift run zamazka-reel out.mp4
//   swift run zamazka-reel --frames 1,7.5 dir    single frames as PNG, to check a moment

import AppKit
import AVFoundation
import CoreImage
@testable import ZamazkaKit

// MARK: - Canvas, palette, timing helpers

let W: CGFloat = 1080, H: CGFloat = 1920
let fps = 60
let rate = 48_000
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

let yellow = NSColor(hex: 0xFFC21A)
let ink = NSColor(hex: 0x16181B)
let chalk = NSColor(hex: 0xF1F1EE)
let markerEdge = NSColor(hex: 0xC98A00)
let labelColor = NSColor(hex: 0x1D1D1F)
let secondaryColor = NSColor(hex: 0x86868B)
let mutedColor = NSColor(hex: 0x6B737D)

extension NSColor {
    func a(_ v: CGFloat) -> NSColor { withAlphaComponent(v) }
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
/// Progress of `t` through [a, b], clamped.
func p(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
func out3(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func back(_ x: Double) -> Double { let s = 1.7; return 1 + (s + 1) * pow(x - 1, 3) + s * pow(x - 1, 2) }
func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t)) }

// MARK: - Drawing helpers (top-left origin, AppKit and CG share one context)

var cg: CGContext!
var groupAlpha: CGFloat = 1

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let rr = max(0, min(radius, r.width / 2, r.height / 2))
    return rr > 0 ? CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil) : CGPath(rect: r, transform: nil)
}

func fill(_ r: CGRect, _ c: NSColor, _ radius: CGFloat = 0) {
    cg.setFillColor(c.cgColor)
    cg.addPath(roundedPath(r, radius))
    cg.fillPath()
}

func stroke(_ r: CGRect, _ c: NSColor, _ radius: CGFloat, _ width: CGFloat, dash: [CGFloat] = []) {
    cg.saveGState()
    cg.setStrokeColor(c.cgColor)
    cg.setLineWidth(width)
    if !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash) }
    cg.addPath(roundedPath(r.insetBy(dx: width / 2, dy: width / 2), radius))
    cg.strokePath()
    cg.restoreGState()
}

/// Shadow offsets and blur are in device pixels, so world drawing passes its zoom.
func withShadow(blur: CGFloat, dy: CGFloat, alpha: CGFloat, _ body: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: NSColor.black.a(alpha).cgColor)
    body()
    cg.restoreGState()
}

/// Draws `body` with extra opacity. With `group`, overlapping parts fade as one picture.
func faded(_ a: Double, group: Bool = false, _ body: () -> Void) {
    guard a > 0.001 else { return }
    let saved = groupAlpha
    cg.saveGState()
    if group, a < 0.999 {
        cg.setAlpha(saved * CGFloat(a))
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        groupAlpha = 1
        cg.setAlpha(1)
        body()
        cg.endTransparencyLayer()
    } else {
        groupAlpha = saved * CGFloat(a)
        cg.setAlpha(groupAlpha)
        body()
    }
    cg.restoreGState()
    groupAlpha = saved
}

func scaled(_ s: CGFloat, around c: CGPoint, _ body: () -> Void) {
    cg.saveGState()
    cg.translateBy(x: c.x, y: c.y)
    cg.scaleBy(x: s, y: s)
    cg.translateBy(x: -c.x, y: -c.y)
    body()
    cg.restoreGState()
}

func draw(_ image: CGImage, in r: CGRect) {
    cg.saveGState()
    cg.translateBy(x: r.minX, y: r.maxY)
    cg.scaleBy(x: 1, y: -1)
    cg.interpolationQuality = .high
    cg.draw(image, in: CGRect(origin: .zero, size: r.size))
    cg.restoreGState()
}

func attrs(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0, line: CGFloat = 0, mono: Bool = false) -> [NSAttributedString.Key: Any] {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byWordWrapping
    if line > 0 { para.minimumLineHeight = line; para.maximumLineHeight = line }
    return [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: para]
}

func text(_ s: String, _ a: [NSAttributedString.Key: Any], at p: CGPoint) {
    NSAttributedString(string: s, attributes: a).draw(at: p)
}

func measure(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGSize {
    NSAttributedString(string: s, attributes: a).size()
}

/// Laid-out text that knows where its words are, so a phrase can be marked or inked.
final class TextBlock {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer

    init(_ s: String, _ a: [NSAttributedString.Key: Any], width: CGFloat) {
        storage = NSTextStorage(string: s, attributes: a)
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    var size: CGSize {
        let r = manager.usedRect(for: container)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    func draw(at p: CGPoint) {
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: p)
    }

    /// One rect per line that `phrase` occupies, relative to the text origin.
    func rects(of phrase: String) -> [CGRect] {
        let r = (storage.string as NSString).range(of: phrase)
        guard r.location != NSNotFound else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var out: [CGRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in out.append(rect) }
        return out
    }
}

var blocks: [String: TextBlock] = [:]
func block(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, width: CGFloat = 936,
           kern: CGFloat = 0, line: CGFloat = 0, mono: Bool = false) -> TextBlock {
    let key = "\(s)|\(size)|\(weight.rawValue)|\(color)|\(width)|\(kern)|\(line)|\(mono)"
    if let b = blocks[key] { return b }
    let b = TextBlock(s, attrs(size, weight, color, kern: kern, line: line, mono: mono), width: width)
    blocks[key] = b
    return b
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: CGPoint) {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let s = image.size
    image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func cursor(_ c: NSCursor, at p: CGPoint) {
    let image = c.image, hot = c.hotSpot
    image.draw(in: CGRect(x: p.x - hot.x, y: p.y - hot.y, width: image.size.width, height: image.size.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

/// Draws with the helpers above into a new bitmap; `w`×`h` in points.
func offscreen(_ w: CGFloat, _ h: CGFloat, scale: CGFloat, _ body: () -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let saved = cg
    cg = ctx
    ctx.translateBy(x: 0, y: h * scale)
    ctx.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    cg = saved
    return ctx.makeImage()!
}

/// A caption on a strip of marker, the same yellow as the findings. `reveal` swipes it in from the left.
@discardableResult
func sticker(_ s: String, x: CGFloat = 72, y: CGFloat, size: CGFloat = 50, reveal: Double, alpha: Double = 1,
             timer: Double? = nil) -> CGRect {
    let padX: CGFloat = 26, padY: CGFloat = 15
    let b = block(s, size, .semibold, ink, width: 936 - padX * 2, kern: -0.4, line: size * 1.18)
    let r = CGRect(x: x, y: y, width: b.size.width + padX * 2, height: b.size.height + padY * 2)
    guard reveal > 0 else { return r }
    faded(alpha) {
        cg.saveGState()
        cg.clip(to: CGRect(x: r.minX - 2, y: r.minY - 4, width: (r.width + 4) * CGFloat(out3(reveal)), height: r.height + 8))
        fill(r, yellow, 18)
        b.draw(at: CGPoint(x: r.minX + padX, y: r.minY + padY))
        if let timer, timer > 0 {
            fill(CGRect(x: r.minX + padX, y: r.maxY - 9, width: (r.width - padX * 2) * CGFloat(timer), height: 4), ink.a(0.85), 2)
        }
        cg.restoreGState()
    }
    return r
}

/// Region covered by a diagonal wipe moving left to right, like a wide marker stroke.
func wipePath(_ t: Double) -> CGPath {
    let slant: CGFloat = 260
    let x = mix(-slant, W + slant, inOut(t))
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: -10, y: -10), CGPoint(x: x + slant / 2, y: -10),
                            CGPoint(x: x - slant / 2, y: H + 10), CGPoint(x: -10, y: H + 10)])
    path.closeSubpath()
    return path
}

// MARK: - Content: the invented screenshots and what the real detector finds on them

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func analyze(_ image: CGImage, _ name: String) -> [Finding] {
    guard let a = try? Detector.analyzeSync(image, options: DetectorOptions(timeout: 120)) else {
        FileHandle.standardError.write(Data("cannot analyze \(name)\n".utf8))
        exit(1)
    }
    let found = a.findings.filter(\.enabled).sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
    FileHandle.standardError.write(Data("\(name): \(found.map(\.kind.title).joined(separator: ", "))\n".utf8))
    return found
}

func scaledRects(_ f: Finding, _ k: CGFloat) -> [CGRect] {
    f.rects.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k) }
}

// Scene A: the chat from the README, narrow like a phone.
let chatWidth: CGFloat = 480
let chatImage = SyntheticImage.chat(scale: 3, width: chatWidth)
let chatFindings = analyze(SyntheticImage.chat(scale: 2, width: chatWidth), "chat")
let chatHeight = CGFloat(chatImage.height) / 3

// Scene C: a profile page that a shop's support asks a screenshot of.
let world = CGSize(width: 720, height: 1130)
let orderRect = CGRect(x: 24, y: 84, width: 440, height: 300)
let messengerRect = CGRect(x: 236, y: 520, width: 460, height: 520)
let wallTop = NSColor(hex: 0x7F93A9), wallBottom = NSColor(hex: 0xD3DAE2)

let orderNumber = "4815162342"
let orderRows: [(String, String)] = [
    ("Получатель:", "Петров Иван Сергеевич"),
    ("Телефон:", "+7 916 123-45-67"),
    ("Почта:", "i.petrov@example.ru"),
    ("Адрес:", "Москва, ул. Тверская, д. 7, кв. 12"),
]

/// An order page in a shop: the order number support needs, and the buyer's details it doesn't.
func drawOrderWindow(zoom: CGFloat?) {
    let r = CGRect(origin: .zero, size: orderRect.size)
    let dark = NSColor(hex: 0x15181C)
    if let zoom {
        withShadow(blur: 26 * zoom, dy: 10 * zoom, alpha: 0.28) { fill(r, .white, 12) }
    } else {
        fill(r, .white, 12)
    }
    stroke(r, NSColor.black.a(0.08), 12, 0.5)
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        fill(CGRect(x: 16 + CGFloat(i) * 20, y: 13, width: 12, height: 12), NSColor(hex: UInt32(c)), 6)
    }
    let title = attrs(13, .semibold, NSColor(hex: 0x3A3F45))
    let ts = measure("Мои заказы", title)
    text("Мои заказы", title, at: CGPoint(x: r.midX - ts.width / 2, y: 10))
    fill(CGRect(x: 0, y: 38, width: r.width, height: 0.5), NSColor.black.a(0.08))

    text("Заказ № \(orderNumber)", attrs(16, .semibold, dark), at: CGPoint(x: 24, y: 54))
    let status = attrs(12, .medium, NSColor(hex: 0xB4351F))
    let ss = measure("Не доставлен", status)
    let pill = CGRect(x: r.width - 24 - ss.width - 20, y: 55, width: ss.width + 20, height: 22)
    fill(pill, NSColor(hex: 0xFCE9E5), 11)
    text("Не доставлен", status, at: CGPoint(x: pill.minX + 10, y: pill.minY + 3))
    text("Наушники беспроводные, 1 шт.", attrs(13, .regular, mutedColor), at: CGPoint(x: 24, y: 84))
    let price = attrs(13, .semibold, dark)
    text("4 990 ₽", price, at: CGPoint(x: r.width - 24 - measure("4 990 ₽", price).width, y: 84))
    fill(CGRect(x: 24, y: 112, width: r.width - 48, height: 0.5), NSColor.black.a(0.1))
    for (i, row) in orderRows.enumerated() {
        let y = 126 + CGFloat(i) * 30
        text(row.0, attrs(13, .regular, mutedColor), at: CGPoint(x: 24, y: y))
        text(row.1, attrs(13, .regular, dark), at: CGPoint(x: 128, y: y))
    }
    text("Доставка ожидалась 5 ноября.", attrs(12, .regular, mutedColor), at: CGPoint(x: 24, y: 262))
}

func orderShot(scale: CGFloat) -> CGImage {
    offscreen(orderRect.width, orderRect.height, scale: scale) {
        // Corners of the window show the wallpaper, as in a real region screenshot.
        fill(CGRect(origin: .zero, size: orderRect.size), NSColor(hex: 0x9DAEC0))
        drawOrderWindow(zoom: nil)
    }
}

let shotDetect = orderShot(scale: 2)
let shotImage = orderShot(scale: 3)
let shotFindings = analyze(shotDetect, "order")
let shotRects = shotFindings.map { scaledRects($0, 1.5) }
/// The finding the person keeps visible in the video: support needs the order number.
let keptIndex: Int = {
    guard let i = shotFindings.firstIndex(where: { $0.kind == .order }) else {
        FileHandle.standardError.write(Data("no order number found\n".utf8))
        exit(1)
    }
    return i
}()
let hiddenCount = shotFindings.count - 1
let shotCleaned = Redactor.render(shotImage, rects: shotRects.enumerated().filter { $0.offset != keptIndex }.flatMap(\.element),
                                  style: RedactStyle())!

// MARK: - The card, laid out like CardView

enum Card {
    /// Same sizing as CardController.previewSize: up to 340×230, keeping the picture's proportions.
    static let previewSize: CGSize = {
        let aspect = orderRect.width / orderRect.height
        let w = max(min(340, 230 * aspect), 220).rounded()
        return CGSize(width: w, height: (w / aspect).rounded())
    }()
    static let width: CGFloat = max(previewSize.width + 24, 340)
    static let origin = CGPoint(x: world.width - 8 - width, y: 30)
    static let titleFont = attrs(13, .semibold, labelColor)
    static let subFont = attrs(11, .regular, secondaryColor)
    static let header: CGFloat = 12 + 16 + 2 + 13 + 10
    static let preview = CGRect(x: 12, y: header, width: previewSize.width, height: previewSize.height)
    static let previewScale = preview.width / CGFloat(shotImage.width)
    static let chipFont = attrs(11, .medium, ink)
    static let hint = "Нажмите на отметку, чтобы оставить это место видимым. Протяните мышью, чтобы скрыть ещё."
    static let applied = "Файл заменён очищенной копией. Картинку можно перетащить в чат."
    static let note = "Оригинал в памяти ещё 10 минут, на диск не пишется."

    /// Room for the chip's symbol: the eye of a switched-off chip is wider than the tick.
    static func icon(_ k: FindingKind) -> CGFloat { k == .order ? 14 : 10 }

    static let kinds: [FindingKind] = {
        var out: [FindingKind] = []
        for f in shotFindings where !out.contains(f.kind) { out.append(f.kind) }
        return out
    }()

    static let chips: [CGRect] = {
        var x: CGFloat = 0, y: CGFloat = 0
        var out: [CGRect] = []
        for k in kinds {
            let w = 8 + icon(k) + 5 + ceil(measure(k.title, chipFont).width) + 8
            if x > 0, x + w > preview.width { x = 0; y += 22 + 6 }
            out.append(CGRect(x: preview.minX + x, y: preview.maxY + 10 + y, width: w, height: 22))
            x += w + 6
        }
        return out
    }()

    static let hintY = (chips.last?.maxY ?? preview.maxY + 10) + 8
    static let hintHeight = ceil(NSAttributedString(string: hint, attributes: attrs(11, .regular, secondaryColor))
        .boundingRect(with: CGSize(width: preview.width, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    static let reviewHeight = hintY + hintHeight + 12 + 28 + 12
    static let appliedHeight: CGFloat = {
        let a = NSAttributedString(string: applied, attributes: attrs(12, .regular, labelColor))
            .boundingRect(with: CGSize(width: preview.width, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return preview.maxY + 10 + ceil(a) + 4 + 14 + 12 + 28 + 12
    }()
    static var rect: CGRect { CGRect(origin: origin, size: CGSize(width: width, height: reviewHeight)) }
    static let hideButton: CGRect = {
        let w = ceil(measure("Скрыть", attrs(13, .semibold, .white)).width) + 28
        return CGRect(x: width - 12 - w, y: reviewHeight - 12 - 28, width: w, height: 28)
    }()
    static func onScreen(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }
    static func previewRect(_ r: CGRect) -> CGRect {
        CGRect(x: preview.minX + r.minX * previewScale, y: preview.minY + r.minY * previewScale,
               width: r.width * previewScale, height: r.height * previewScale)
    }
}

struct CardMoment {
    var appear: Double = 1
    var marks: (Int) -> Double = { _ in 1 }   // pop-in of each mark and chip
    var inked: (Int) -> Double = { _ in 0 }   // ink sweep over each mark
    var applied = false
    var height: CGFloat = Card.reviewHeight
    var pressed = false
    var zoom: CGFloat = 1
    /// 0 → 1 as the order number is clicked and left visible.
    var kept: Double = 0
}

func button(_ title: String, _ r: CGRect, prominent: Bool, pressed: Bool = false) {
    scaled(pressed ? 0.98 : 1, around: CGPoint(x: r.midX, y: r.midY)) {
        faded(pressed && prominent ? 0.85 : 1) {
            fill(r, prominent ? ink : NSColor.black.a(pressed ? 0.14 : 0.07), 7)
            let a = attrs(13, prominent ? .semibold : .regular, prominent ? .white : labelColor)
            let s = measure(title, a)
            text(title, a, at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }
}

func drawCard(_ m: CardMoment) {
    let origin = CGPoint(x: Card.origin.x, y: Card.origin.y - 8 * CGFloat(1 - m.appear))
    let r = CGRect(origin: origin, size: CGSize(width: Card.width, height: m.height))
    faded(m.appear, group: true) {
        withShadow(blur: 26 * m.zoom, dy: 9 * m.zoom, alpha: 0.26) { fill(r, .white, 14) }
        stroke(r, NSColor.black.a(0.12), 14, 0.5)
        cg.saveGState()
        cg.translateBy(x: origin.x, y: origin.y)

        // Header
        text(m.applied ? "Скрыто \(places(hiddenCount))" : "Личные данные на снимке", Card.titleFont, at: CGPoint(x: 14, y: 12))
        text("Снимок экрана, Рабочий стол", Card.subFont, at: CGPoint(x: 14, y: 30))
        symbol("xmark", size: 11, weight: .semibold, color: secondaryColor, center: CGPoint(x: Card.width - 14 - 11, y: 21))
        symbol("arrow.up.left.and.arrow.down.right", size: 11, weight: .semibold, color: secondaryColor,
               center: CGPoint(x: Card.width - 14 - 22 - 8 - 11, y: 21))

        // Preview with marks
        let pv = Card.preview
        cg.saveGState()
        cg.addPath(roundedPath(pv, 8))
        cg.clip()
        draw(m.applied ? shotCleaned : shotImage, in: pv)
        if !m.applied {
            for (i, rects) in shotRects.enumerated() {
                let pop = m.marks(i)
                guard pop > 0 else { continue }
                for raw in rects {
                    let v = Card.previewRect(raw)
                    let radius = min(4, v.height * 0.2)
                    let off = i == keptIndex ? m.kept : 0
                    scaled(1 + 0.25 * CGFloat(1 - back(pop)), around: CGPoint(x: v.midX, y: v.midY)) {
                        faded(min(1, pop * 2) * (1 - off)) {
                            fill(v, yellow.a(0.38), radius)
                            stroke(v, markerEdge, radius, 1.25)
                        }
                        faded(off) { stroke(v, secondaryColor, radius, 1, dash: [3, 2.5]) }
                    }
                    guard i != keptIndex else { continue }
                    let ink0 = m.inked(i)
                    if ink0 > 0 { fill(CGRect(x: v.minX, y: v.minY, width: v.width * CGFloat(ink0), height: v.height), ink, radius) }
                }
            }
        }
        cg.restoreGState()
        stroke(pv, NSColor.black.a(0.12), 8, 0.5)

        if m.applied {
            let a = attrs(12, .regular, labelColor)
            NSAttributedString(string: Card.applied, attributes: a)
                .draw(with: CGRect(x: 12, y: pv.maxY + 10, width: pv.width, height: 60), options: [.usesLineFragmentOrigin, .usesFontLeading])
            text(Card.note, attrs(11, .regular, secondaryColor), at: CGPoint(x: 12, y: m.height - 12 - 28 - 12 - 14))
            button("Вернуть", CGRect(x: 12, y: m.height - 40, width: ceil(measure("Вернуть", attrs(13, .regular, labelColor)).width) + 28, height: 28), prominent: false)
            let w = ceil(measure("Готово", attrs(13, .semibold, .white)).width) + 28
            button("Готово", CGRect(x: Card.width - 12 - w, y: m.height - 40, width: w, height: 28), prominent: true)
        } else {
            for (i, kind) in Card.kinds.enumerated() {
                let c = Card.chips[i]
                let pop = m.marks(shotFindings.firstIndex { $0.kind == kind } ?? i)
                guard pop > 0 else { continue }
                let off = kind == .order ? m.kept : 0
                scaled(0.6 + 0.4 * CGFloat(back(pop)), around: CGPoint(x: c.midX, y: c.midY)) {
                    faded(min(1, pop * 2) * (1 - off)) {
                        fill(c, yellow, 11)
                        symbol("checkmark", size: 10, weight: .bold, color: ink, center: CGPoint(x: c.minX + 8 + 5, y: c.midY))
                        text(kind.title, Card.chipFont, at: CGPoint(x: c.minX + 8 + Card.icon(kind) + 5, y: c.midY - 7))
                    }
                    faded(off) {
                        stroke(c, secondaryColor.a(0.6), 11, 1, dash: [3, 2])
                        symbol("eye", size: 10, weight: .bold, color: secondaryColor, center: CGPoint(x: c.minX + 8 + 7, y: c.midY))
                        text(kind.title, attrs(11, .medium, secondaryColor), at: CGPoint(x: c.minX + 8 + Card.icon(kind) + 5, y: c.midY - 7))
                    }
                }
            }
            NSAttributedString(string: Card.hint, attributes: attrs(11, .regular, secondaryColor))
                .draw(with: CGRect(x: 12, y: Card.hintY, width: pv.width, height: Card.hintHeight + 4), options: [.usesLineFragmentOrigin, .usesFontLeading])
            button("Оставить как есть", CGRect(x: 12, y: m.height - 40, width: ceil(measure("Оставить как есть", attrs(13, .regular, labelColor)).width) + 28, height: 28), prominent: false)
            button("Скрыть", Card.hideButton, prominent: true, pressed: m.pressed)
        }
        cg.restoreGState()
    }
}

// MARK: - The rest of the desktop

func wallpaper() {
    let g = CGGradient(colorsSpace: srgb, colors: [wallTop.cgColor, wallBottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: world.width * 0.6, y: world.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // One soft light, so the desktop is not a flat card.
    let glow = CGGradient(colorsSpace: srgb, colors: [NSColor.white.a(0.35).cgColor, NSColor.white.a(0).cgColor] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 560, y: 760), startRadius: 0, endCenter: CGPoint(x: 560, y: 760), endRadius: 520, options: [])
}

func menuBar(busy: Double) {
    fill(CGRect(x: 0, y: 0, width: world.width, height: 24), NSColor.white.a(0.72))
    fill(CGRect(x: 0, y: 24, width: world.width, height: 0.5), NSColor.black.a(0.08))
    text("Finder", attrs(13, .bold, labelColor), at: CGPoint(x: 18, y: 4))
    var x: CGFloat = 80
    for item in ["Файл", "Правка", "Вид", "Окно"] {
        text(item, attrs(13, .regular, labelColor), at: CGPoint(x: x, y: 4))
        x += measure(item, attrs(13, .regular, labelColor)).width + 18
    }
    symbol("wifi", size: 13, weight: .semibold, color: labelColor, center: CGPoint(x: 566, y: 12))
    symbol("battery.75percent", size: 13, weight: .regular, color: labelColor, center: CGPoint(x: 598, y: 12))
    let blink = busy > 0 && busy < 1 ? 0.35 + 0.65 * abs(cos(busy * .pi * 3)) : 1
    faded(blink) {
        symbol("text.redaction", size: 13, weight: .semibold, color: labelColor, center: CGPoint(x: 633, y: 12))
    }
    text("Сб 18:09", attrs(13, .regular, labelColor), at: CGPoint(x: 652, y: 4))
}

let supportText = "Здравствуйте! Пришлите, пожалуйста, скриншот заказа, проверим доставку."
let replyText = "Спасибо, видим заказ \(orderNumber). Курьер привезёт завтра."
let bubbleImageSize = CGSize(width: 260, height: 260 * orderRect.height / orderRect.width)

func messengerBubble(_ s: String, y: CGFloat, time: String) -> CGRect {
    let a = attrs(14, .regular, NSColor(hex: 0x15181C))
    let maxW: CGFloat = 300
    let size = NSAttributedString(string: s, attributes: a)
        .boundingRect(with: CGSize(width: maxW - 28 - 36, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    let r = CGRect(x: 14, y: y, width: ceil(size.width) + 28 + 36, height: ceil(size.height) + 18)
    fill(r, .white, 15)
    NSAttributedString(string: s, attributes: a)
        .draw(with: CGRect(x: r.minX + 14, y: r.minY + 9, width: ceil(size.width) + 1, height: ceil(size.height) + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let ta = attrs(11, .regular, mutedColor)
    text(time, ta, at: CGPoint(x: r.maxX - 12 - measure(time, ta).width, y: r.maxY - 8 - 13))
    return r
}

func drawMessenger(zoom: CGFloat, bubble: Double, reply: Double, hover: Double) {
    let r = CGRect(origin: .zero, size: messengerRect.size)
    withShadow(blur: 30 * zoom, dy: 12 * zoom, alpha: 0.3) { fill(r, .white, 12) }
    cg.saveGState()
    cg.addPath(roundedPath(r, 12))
    cg.clip()
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        fill(CGRect(x: 16 + CGFloat(i) * 20, y: 13, width: 12, height: 12), NSColor(hex: UInt32(c)), 6)
    }
    let avatar = CGRect(x: 16, y: 38, width: 38, height: 38)
    fill(avatar, NSColor(hex: 0x5B8DEF), 19)
    let ia = attrs(15, .semibold, .white)
    let isz = measure("П", ia)
    text("П", ia, at: CGPoint(x: avatar.midX - isz.width / 2, y: avatar.midY - isz.height / 2))
    text("Поддержка магазина", attrs(14, .semibold, NSColor(hex: 0x15181C)), at: CGPoint(x: 64, y: 39))
    text("онлайн", attrs(12, .regular, mutedColor), at: CGPoint(x: 64, y: 58))
    let area = CGRect(x: 0, y: 86, width: r.width, height: r.height - 86 - 56)
    fill(area, NSColor(hex: 0xECEFF3))
    fill(CGRect(x: 0, y: 85.5, width: r.width, height: 0.5), NSColor.black.a(0.1))

    let first = messengerBubble(supportText, y: area.minY + 16, time: "18:08")
    var y = first.maxY + 12
    if bubble > 0 {
        let b = CGRect(x: r.width - 14 - bubbleImageSize.width - 12, y: y, width: bubbleImageSize.width + 12, height: bubbleImageSize.height + 12)
        scaled(0.9 + 0.1 * CGFloat(back(bubble)), around: CGPoint(x: b.maxX, y: b.maxY)) {
            faded(min(1, bubble * 2)) {
                fill(b, NSColor(hex: 0xDCE7F5), 15)
                let img = b.insetBy(dx: 6, dy: 6)
                cg.saveGState()
                cg.addPath(roundedPath(img, 10))
                cg.clip()
                draw(shotCleaned, in: img)
                cg.restoreGState()
                let pill = CGRect(x: img.maxX - 46, y: img.maxY - 24, width: 40, height: 18)
                fill(pill, NSColor.black.a(0.45), 9)
                text("18:09", attrs(10, .medium, .white), at: CGPoint(x: pill.minX + 7, y: pill.minY + 3))
            }
        }
        y = b.maxY + 12
    }
    if reply > 0 {
        scaled(0.9 + 0.1 * CGFloat(back(reply)), around: CGPoint(x: 14, y: y + 20)) {
            faded(min(1, reply * 2)) { _ = messengerBubble(replyText, y: y, time: "18:09") }
        }
    }
    if hover > 0 {
        stroke(area.insetBy(dx: 4, dy: 4), NSColor(hex: 0x2F7CF6).a(CGFloat(hover) * 0.9), 10, 2.5)
    }
    // Composer
    let field = CGRect(x: 14, y: r.height - 46, width: r.width - 70, height: 36)
    fill(field, NSColor(hex: 0xF1F3F6), 18)
    text("Сообщение", attrs(14, .regular, NSColor(hex: 0x8A939D)), at: CGPoint(x: field.minX + 16, y: field.minY + 9))
    symbol("paperplane.fill", size: 17, weight: .regular, color: NSColor(hex: 0x8A939D), center: CGPoint(x: r.width - 30, y: field.midY))
    cg.restoreGState()
    stroke(r, NSColor.black.a(0.1), 12, 0.5)
}

func keycap(_ glyph: String, center: CGPoint, appear: Double, press: Double) {
    guard appear > 0 else { return }
    let side: CGFloat = 150
    scaled(0.7 + 0.3 * CGFloat(back(appear)), around: center) {
        faded(min(1, appear * 2)) {
            let base = CGRect(x: center.x - side / 2, y: center.y - side / 2 + 10, width: side, height: side)
            withShadow(blur: 30, dy: 14, alpha: 0.35) { fill(base, NSColor(hex: 0xB9C0C8), 30) }
            let top = base.offsetBy(dx: 0, dy: -10 + 8 * CGFloat(press))
            fill(top, .white, 30)
            stroke(top, NSColor.black.a(0.08), 30, 1)
            let a = attrs(72, .medium, ink)
            let s = measure(glyph, a)
            text(glyph, a, at: CGPoint(x: top.midX - s.width / 2, y: top.midY - s.height / 2))
        }
    }
}

// MARK: - Camera over the desktop

struct Camera {
    var cx, cy, z, fy: CGFloat
    static func mix(_ a: Camera, _ b: Camera, _ t: Double) -> Camera {
        // Zoom moves in log space so the push feels even.
        let z = exp(Main.mix(log(a.z), log(b.z), t))
        return Camera(cx: Main.mix(a.cx, b.cx, t), cy: Main.mix(a.cy, b.cy, t), z: z, fy: Main.mix(a.fy, b.fy, t))
    }
}
enum Main {
    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

/// The screen starts 230 px down, under the app's own header in Reels.
let camWide = Camera(cx: 360, cy: (960 - 230) / 1.5, z: 1.5, fy: 960)
let camCard: Camera = {
    let z: CGFloat = 2.45
    let cy = Card.origin.y + Card.reviewHeight / 2
    return Camera(cx: Card.origin.x + Card.width / 2, cy: cy, z: z, fy: 222 + cy * z)
}()
let camChat = Camera(cx: messengerRect.midX, cy: 800, z: 1.9, fy: 980)

// MARK: - Scenes

/// A: a chat full of personal data and a challenge to find it.
func sceneA(_ t: Double) {
    fill(CGRect(x: 0, y: 0, width: W, height: H), ink)
    let k: CGFloat = 860 / chatWidth
    let panel = CGRect(x: 110, y: 456 - 24 * CGFloat(inOut(p(t, 0, 3.9))), width: 860, height: chatHeight * k)
    withShadow(blur: 60, dy: 20, alpha: 0.55) { fill(panel, .white, 26) }
    cg.saveGState()
    cg.addPath(roundedPath(panel, 26))
    cg.clip()
    draw(chatImage, in: panel)
    let s = panel.width / CGFloat(chatImage.width) * 1.5   // findings are in 2x pixels
    for (i, f) in chatFindings.enumerated() {
        let start = 1.4 + Double(i) * 0.17
        let pop = p(t, start, start + 0.32)
        guard pop > 0 else { continue }
        for r in f.rects {
            let v = CGRect(x: panel.minX + r.minX * s, y: panel.minY + r.minY * s, width: r.width * s, height: r.height * s)
            scaled(1 + 0.3 * CGFloat(1 - back(pop)), around: CGPoint(x: v.midX, y: v.midY)) {
                faded(min(1, pop * 3)) {
                    fill(v, yellow.a(0.38 + 0.55 * CGFloat(1 - pop)), 6)
                    stroke(v, markerEdge, 6, 2.5)
                }
            }
        }
    }
    cg.restoreGState()

    let total = chatFindings.count
    let found = (0..<total).filter { t >= 1.4 + Double($0) * 0.17 }.count
    if found == 0 {
        sticker("Найди на скриншоте\n\(total) мест с личными данными", y: 262, size: 56, reveal: 1, timer: p(t, 0.1, 1.4))
    } else if t < 1.4 + Double(total) * 0.17 + 0.25 {
        scaled(1 + 0.04 * CGFloat(1 - p(t, 1.4 + Double(found - 1) * 0.17, 1.4 + Double(found - 1) * 0.17 + 0.12)), around: CGPoint(x: 72, y: 300)) {
            sticker("Найдено \(found) из \(total)", y: 262, size: 56, reveal: 1)
        }
    } else {
        sticker("Замазка нашла все \(total)", y: 262, size: 56, reveal: p(t, 1.4 + Double(total) * 0.17 + 0.25, 1.4 + Double(total) * 0.17 + 0.5))
    }
}

/// B: the name and what it does; the private part of the sentence gets inked.
func sceneB(_ b: Double) {
    fill(CGRect(x: 0, y: 0, width: W, height: H), yellow)
    let title = block("Замазка", 168, .heavy, ink, kern: -5)
    let a1 = out3(p(b, 0.3, 0.7))
    faded(a1) { title.draw(at: CGPoint(x: 66, y: 640 + 40 * CGFloat(1 - a1))) }
    let body = block("прячет личные данные на скриншотах, пока они не ушли в чат", 76, .bold, ink, kern: -1.2, line: 86)
    let a2 = out3(p(b, 0.45, 0.85))
    let origin = CGPoint(x: 72, y: 880 + 40 * CGFloat(1 - a2))
    faded(a2) { body.draw(at: origin) }
    let lines = body.rects(of: "личные данные")
    for (j, r) in lines.enumerated() {
        let start = 1.2 + Double(j) * 0.2
        let lp = out3(p(b, start, start + 0.3))
        guard lp > 0 else { continue }
        let bar = CGRect(x: origin.x + r.minX - 8, y: origin.y + r.minY + 12, width: (r.width + 16) * CGFloat(lp), height: r.height - 14)
        fill(bar, ink, 8)
    }
}

/// C: the app at work on a desktop.
enum C {
    // Local times inside the scene, seconds.
    static let keys = [0.85, 0.95, 1.05]
    static let release = 1.35
    static let drag = (1.8, 2.45)
    static let shot = 2.5
    static let toCard = (2.55, 3.4)
    static let cardIn = 2.95
    static let marks = 3.4
    static let markStep = 0.09
    static let toKeep = (4.15, 4.8)
    static let keep = 4.9
    static let toHide = (5.55, 6.15)
    static let press = 6.3
    static let ink = 6.4
    static let inkStep = 0.07
    static let applied = 7.2
    static let toWide = (8.45, 9.25)
    static let toPreview = (8.7, 9.3)
    static let grab = 9.4
    static let drop = 10.45
    static let toChat = (10.0, 10.85)
    static let reply = 11.2
    static let end = 12.1

    static let selectFrom = CGPoint(x: orderRect.minX, y: orderRect.minY)
    static let selectTo = CGPoint(x: orderRect.maxX, y: orderRect.maxY)
    static let hideTarget = CGPoint(x: Card.onScreen(Card.hideButton).midX + 6, y: Card.onScreen(Card.hideButton).midY + 4)
    static let keepTarget: CGPoint = {
        let r = Card.onScreen(Card.previewRect(shotRects[keptIndex][0]))
        return CGPoint(x: r.midX, y: r.midY + 1)
    }()
    static let previewCenter = CGPoint(x: Card.onScreen(Card.preview).midX, y: Card.onScreen(Card.preview).midY)
    static let dropPoint = CGPoint(x: messengerRect.midX + 40, y: messengerRect.minY + 300)
}

func sceneC(_ c: Double) {
    fill(CGRect(x: 0, y: 0, width: W, height: H), ink)

    var cam = camWide
    if c >= C.toCard.0 { cam = Camera.mix(camWide, camCard, inOut(p(c, C.toCard.0, C.toCard.1))) }
    if c >= C.toWide.0 { cam = Camera.mix(camCard, camWide, inOut(p(c, C.toWide.0, C.toWide.1))) }
    if c >= C.toChat.0 { cam = Camera.mix(camWide, camChat, inOut(p(c, C.toChat.0, C.toChat.1))) }

    cg.saveGState()
    cg.translateBy(x: 540, y: cam.fy)
    cg.scaleBy(x: cam.z, y: cam.z)
    cg.translateBy(x: -cam.cx, y: -cam.cy)
    cg.saveGState()
    cg.addPath(roundedPath(CGRect(origin: .zero, size: world), 16))
    cg.clip()

    wallpaper()
    cg.saveGState()
    cg.translateBy(x: orderRect.minX, y: orderRect.minY)
    drawOrderWindow(zoom: cam.z)
    cg.restoreGState()

    cg.saveGState()
    cg.translateBy(x: messengerRect.minX, y: messengerRect.minY)
    let overChat = c > C.grab ? p(c, C.drop - 0.35, C.drop - 0.15) * (1 - p(c, C.drop, C.drop + 0.15)) : 0
    drawMessenger(zoom: cam.z, bubble: p(c, C.drop, C.drop + 0.35), reply: p(c, C.reply, C.reply + 0.3), hover: overChat)
    cg.restoreGState()

    menuBar(busy: p(c, C.shot + 0.05, C.cardIn))

    // Region selection and the shot
    if c >= C.drag.0 && c < C.shot + 0.3 {
        let q = inOut(p(c, C.drag.0, C.drag.1))
        let end = mix(C.selectFrom, C.selectTo, q)
        let sel = CGRect(x: C.selectFrom.x, y: C.selectFrom.y, width: end.x - C.selectFrom.x, height: end.y - C.selectFrom.y)
        if c < C.shot {
            fill(sel, NSColor(white: 0.45, alpha: 0.28))
            stroke(sel, NSColor.white.a(0.9), 0, 1)
        } else {
            fill(sel, NSColor.white.a(0.6 * CGFloat(1 - p(c, C.shot, C.shot + 0.3))))
        }
    }

    // The card
    if c >= C.cardIn {
        var m = CardMoment()
        m.zoom = cam.z
        m.appear = out3(p(c, C.cardIn, C.cardIn + 0.3))
        m.marks = { i in p(c, C.marks + Double(i) * C.markStep, C.marks + Double(i) * C.markStep + 0.3) }
        m.inked = { i in
            let start = C.ink + Double(i > keptIndex ? i - 1 : i) * C.inkStep
            return out3(p(c, start, start + 0.38))
        }
        m.kept = out3(p(c, C.keep, C.keep + 0.18))
        m.pressed = c >= C.press && c < C.press + 0.12
        m.applied = c >= C.applied
        m.height = m.applied ? mix(Card.reviewHeight, Card.appliedHeight, out3(p(c, C.applied, C.applied + 0.25))) : Card.reviewHeight
        drawCard(m)
    }

    // Dragging the cleaned picture into the chat
    if c >= C.grab && c < C.drop + 0.15 {
        let q = inOut(p(c, C.grab + 0.05, C.drop - 0.05))
        var pos = mix(C.previewCenter, C.dropPoint, q)
        pos.x -= CGFloat(sin(q * .pi)) * 60
        let ghost = CGRect(x: pos.x - 90, y: pos.y - 61, width: 180, height: 180 * orderRect.height / orderRect.width)
        faded(0.8 * (1 - p(c, C.drop, C.drop + 0.12))) {
            withShadow(blur: 18 * cam.z, dy: 8 * cam.z, alpha: 0.3) { fill(ghost, .white, 4) }
            draw(shotCleaned, in: ghost)
        }
    }

    // The pointer
    let cursorAlpha = 1 - p(c, C.reply + 0.2, C.reply + 0.5)
    faded(cursorAlpha) {
        if c >= 1.4 && c < C.shot {
            let start = CGPoint(x: 250, y: 470)
            let pos = c < C.drag.0 ? mix(start, C.selectFrom, inOut(p(c, 1.4, 1.72))) : mix(C.selectFrom, C.selectTo, inOut(p(c, C.drag.0, C.drag.1)))
            cursor(.crosshair, at: pos)
        } else if c >= C.shot {
            var pos = C.selectTo
            if c >= C.toKeep.0 { pos = mix(C.selectTo, C.keepTarget, inOut(p(c, C.toKeep.0, C.toKeep.1))) }
            if c >= C.toHide.0 { pos = mix(C.keepTarget, C.hideTarget, inOut(p(c, C.toHide.0, C.toHide.1))) }
            if c >= C.toPreview.0 { pos = mix(C.hideTarget, C.previewCenter, inOut(p(c, C.toPreview.0, C.toPreview.1))) }
            if c >= C.grab {
                let q = inOut(p(c, C.grab + 0.05, C.drop - 0.05))
                pos = mix(C.previewCenter, C.dropPoint, q)
                pos.x -= CGFloat(sin(q * .pi)) * 60
            }
            cursor(.arrow, at: pos)
        }
    }

    cg.restoreGState()
    cg.restoreGState()

    // Keys, in screen space
    let keyAppear = { (i: Int) in p(c, 0.45 + Double(i) * 0.08, 0.45 + Double(i) * 0.08 + 0.3) }
    let keyFade = 1 - p(c, C.release + 0.05, C.release + 0.25)
    faded(keyFade) {
        for (i, g) in ["⌘", "⇧", "4"].enumerated() {
            let press = c >= C.keys[i] && c < C.release ? 1.0 : 0.0
            keycap(g, center: CGPoint(x: 540 + CGFloat(i - 1) * 180, y: 908), appear: keyAppear(i), press: press)
        }
    }

    // Captions
    let captions: [(String, Double, Double, CGFloat)] = [
        ("Делаешь скриншот как обычно", 0.3, 2.55, 1380),
        ("Замазка показывает, что нашла", 3.3, 4.55, 1380),
        ("Номер заказа поддержке нужен: нажимаешь, и он остаётся", 4.6, 6.2, 1380),
        ("Жмёшь «Скрыть»", 6.2, 7.2, 1380),
        ("Файл уже заменён чистой копией", 7.3, 8.9, 1380),
        ("Перетаскиваешь в чат", 9.05, 11.95, 1380),
    ]
    for (s, a, b, y) in captions where c >= a && c < b {
        sticker(s, y: y, reveal: p(c, a, a + 0.28), alpha: 1 - p(c, b - 0.15, b))
    }
}

/// D: why a fill and not blur or pixels.
let stripSize = CGSize(width: 936, height: 210)
let stripNumber = SyntheticImage.cardGrouped
let stripImage = offscreen(stripSize.width, stripSize.height, scale: 1) {
    fill(CGRect(origin: .zero, size: stripSize), .white)
    let b = block(stripNumber, 72, .semibold, ink, width: 936, kern: 1, mono: true)
    b.draw(at: CGPoint(x: (stripSize.width - b.size.width) / 2, y: (stripSize.height - b.size.height) / 2))
}
let pixelated: [CGImage] = {
    let ci = CIImage(cgImage: stripImage)
    let ctx = CIContext()
    return [34, 26, 19, 13, 8, 4].map { s in
        let out = ci.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: s, kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: ci.extent)
        return ctx.createCGImage(out, from: ci.extent)!
    }
}()

enum D {
    static let recover = (1.45, 2.45)
    static let swap = 2.95
    static let mark = 3.15
    static let ink = 3.4
    static let end = 4.45
}

func sceneD(_ d: Double, alpha: Double = 1) {
    faded(alpha) {
        let strip = CGRect(x: 72, y: 820, width: stripSize.width, height: stripSize.height)
        let swap = p(d, D.swap, D.swap + 0.3)
        let t1 = block("Пиксели и размытие восстанавливают", 82, .bold, chalk, kern: -1.5, line: 92)
        let t2 = block("Под заливкой восстанавливать нечего", 82, .bold, chalk, kern: -1.5, line: 92)
        let ta = out3(p(d, 0.35, 0.7))
        faded(ta * (1 - swap)) { t1.draw(at: CGPoint(x: 72, y: 460 + 30 * CGFloat(1 - ta))) }
        faded(swap) { t2.draw(at: CGPoint(x: 72, y: 460 + 30 * CGFloat(1 - swap))) }

        let sa = out3(p(d, 0.45, 0.8))
        faded(sa) {
            withShadow(blur: 40, dy: 14, alpha: 0.5) { fill(strip, .white, 22) }
            cg.saveGState()
            cg.addPath(roundedPath(strip, 22))
            cg.clip()
            let step = Int(p(d, D.recover.0, D.recover.1) * Double(pixelated.count))
            draw(step < pixelated.count ? pixelated[step] : stripImage, in: strip)
            if d > D.recover.0 && d < D.recover.1 {
                let x = strip.minX + strip.width * CGFloat(p(d, D.recover.0, D.recover.1) * Double(pixelated.count)).truncatingRemainder(dividingBy: 1)
                fill(CGRect(x: x - 3, y: strip.minY, width: 6, height: strip.height), yellow)
            }
            // Marker, then ink over the number.
            let b = block(stripNumber, 72, .semibold, ink, width: 936, kern: 1, mono: true)
            let num = CGRect(x: strip.minX + (strip.width - b.size.width) / 2 - 14, y: strip.minY + (strip.height - b.size.height) / 2 + 4,
                             width: b.size.width + 28, height: b.size.height - 8)
            let mk = out3(p(d, D.mark, D.mark + 0.22))
            if mk > 0 {
                fill(CGRect(x: num.minX, y: num.minY, width: num.width * CGFloat(mk), height: num.height), yellow.a(0.38), 10)
                stroke(CGRect(x: num.minX, y: num.minY, width: num.width * CGFloat(mk), height: num.height), markerEdge, 10, 3)
            }
            let ik = out3(p(d, D.ink, D.ink + 0.38))
            if ik > 0 { fill(CGRect(x: num.minX, y: num.minY, width: num.width * CGFloat(ik), height: num.height), ink, 10) }
            cg.restoreGState()
        }

        let l1 = block("Depix подбирает текст под пиксельные блоки, Unredacter делает то же с размытием", 40, .regular, chalk.a(0.62), line: 52)
        let l2 = block("Замазка закрашивает сплошным цветом: пикселей оригинала в файле не остаётся", 40, .regular, chalk.a(0.62), line: 52)
        faded(p(d, 0.8, 1.1) * (1 - swap)) { l1.draw(at: CGPoint(x: 72, y: strip.maxY + 44)) }
        faded(swap) { l2.draw(at: CGPoint(x: 72, y: strip.maxY + 44)) }
    }
}

/// E: three plain facts, each on a strip of marker.
let facts: [(String, String)] = [
    ("Работает без интернета", "Всё считается на твоём Mac"),
    ("Знает российские форматы", "Паспорт, СНИЛС, ИНН, полис ОМС, карты, госномера"),
    ("Бесплатно, код открыт", "Для macOS 14 и новее"),
]

func sceneE(_ e: Double, alpha: Double = 1) {
    faded(alpha) {
        var y: CGFloat = 520
        for (i, f) in facts.enumerated() {
            let start = 0.25 + Double(i) * 0.5
            let r = sticker(f.0, y: y, size: 66, reveal: p(e, start, start + 0.35))
            let sub = block(f.1, 40, .regular, chalk.a(0.7), line: 50)
            let sa = out3(p(e, start + 0.2, start + 0.5))
            faded(sa) { sub.draw(at: CGPoint(x: 72, y: r.maxY + 20 + 14 * CGFloat(1 - sa))) }
            y = r.maxY + 20 + sub.size.height + 86
        }
    }
}

/// F: the end card.
let appIcon: CGImage = {
    let url = packageRoot.appendingPathComponent("Resources/AppIcon.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("no icon at \(url.path)\n".utf8))
        exit(1)
    }
    return img
}()

func sceneF(_ f: Double) {
    fill(CGRect(x: 0, y: 0, width: W, height: H), yellow)
    let ia = p(f, 0.3, 0.75)
    let icon = CGRect(x: 44, y: 470, width: 280, height: 280)
    scaled(0.82 + 0.18 * CGFloat(back(ia)), around: CGPoint(x: icon.midX, y: icon.midY)) {
        faded(min(1, ia * 2)) { draw(appIcon, in: icon) }
    }
    let name = block("Замазка", 168, .heavy, ink, kern: -5)
    let na = out3(p(f, 0.45, 0.85))
    faded(na) { name.draw(at: CGPoint(x: 66, y: 770 + 30 * CGFloat(1 - na))) }
    let line = block("Бесплатно для macOS", 64, .bold, ink, kern: -1)
    let la = out3(p(f, 0.6, 1.0))
    faded(la) { line.draw(at: CGPoint(x: 72, y: 980 + 30 * CGFloat(1 - la))) }
    let link = "github.com/vldvr/zamazka"
    let a = attrs(46, .semibold, chalk)
    let s = measure(link, a)
    let pill = CGRect(x: 72, y: 1120, width: s.width + 64, height: 92)
    let pa = out3(p(f, 0.75, 1.15))
    faded(pa) {
        fill(pill.offsetBy(dx: 0, dy: 24 * CGFloat(1 - pa)), ink, 46)
        text(link, a, at: CGPoint(x: pill.minX + 32, y: pill.midY - s.height / 2 + 24 * CGFloat(1 - pa)))
    }
}

// MARK: - Timeline

enum T {
    static let abWipe = (3.55, 3.9)
    static let bcSlide = (5.75, 6.2)
    static let cStart = bcSlide.0
    static let cdWipe = (cStart + C.end - 0.35, cStart + C.end)
    static let dStart = cdWipe.0
    static let eStart = dStart + D.end
    static let efWipe = (eStart + 3.15, eStart + 3.5)
    static let fStart = efWipe.0
    static let end = fStart + 3.9
}

func frame(_ t: Double) {
    if t < T.abWipe.1 { sceneA(t) }
    if t >= T.abWipe.0 && t < T.bcSlide.1 {
        if t >= T.bcSlide.0 { sceneC(t - T.cStart) }
        cg.saveGState()
        if t < T.abWipe.1 { cg.addPath(wipePath(p(t, T.abWipe.0, T.abWipe.1))); cg.clip() }
        let slide = CGFloat(inOut(p(t, T.bcSlide.0, T.bcSlide.1)))
        cg.translateBy(x: 0, y: -H * slide)
        if slide > 0 { withShadow(blur: 60, dy: 20, alpha: 0.4) { fill(CGRect(x: 0, y: 0, width: W, height: H), yellow) } }
        sceneB(t - T.abWipe.0)
        cg.restoreGState()
    }
    if t >= T.bcSlide.1 && t < T.cdWipe.1 { sceneC(t - T.cStart) }
    if t >= T.dStart && t < T.eStart + 0.35 {
        cg.saveGState()
        if t < T.cdWipe.1 { cg.addPath(wipePath(p(t, T.cdWipe.0, T.cdWipe.1))); cg.clip() }
        fill(CGRect(x: 0, y: 0, width: W, height: H), ink)
        sceneD(t - T.dStart, alpha: 1 - p(t, T.eStart, T.eStart + 0.3))
        cg.restoreGState()
    }
    if t >= T.eStart && t < T.efWipe.1 {
        if t >= T.eStart + 0.35 { fill(CGRect(x: 0, y: 0, width: W, height: H), ink) }
        sceneE(t - T.eStart)
    }
    if t >= T.fStart {
        cg.saveGState()
        if t < T.efWipe.1 { cg.addPath(wipePath(p(t, T.efWipe.0, T.efWipe.1))); cg.clip() }
        sceneF(t - T.fStart)
        cg.restoreGState()
    }
}

func render(_ ctx: CGContext, _ t: Double) {
    cg = ctx
    groupAlpha = 1
    ctx.saveGState()
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    fill(CGRect(x: 0, y: 0, width: W, height: H), ink)
    frame(t)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

// MARK: - Sound: a few synthesized interface sounds, no samples

struct Noise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)
    }
}
var noise = Noise()
let sr = Double(rate)

func synth(_ seconds: Double, _ f: (Double) -> Double) -> [Float] {
    (0..<Int(seconds * sr)).map { Float(f(Double($0) / sr)) }
}

func pop(_ freq: Double) -> [Float] {
    var phase = 0.0
    return synth(0.16) { t in
        let f = freq * (1 + 0.7 * exp(-t / 0.012))
        phase += 2 * .pi * f / sr
        return (sin(phase) + 0.2 * sin(2 * phase)) * min(1, t / 0.002) * exp(-t / 0.05)
    }
}

func click() -> [Float] {
    var last = 0.0
    return synth(0.05) { t in
        let n = noise.next(); let hp = n - last; last = n
        return hp * 0.5 * exp(-t / 0.0035) + sin(2 * .pi * 2300 * t) * 0.25 * exp(-t / 0.006) + sin(2 * .pi * 170 * t) * 0.5 * exp(-t / 0.012)
    }
}

func shutter() -> [Float] {
    var last = 0.0, low = 0.0
    return synth(0.16) { t in
        let n = noise.next(); let hp = n - last; last = n
        low += 0.08 * (n - low)
        let a = exp(-t / 0.005) + 0.8 * (t > 0.055 ? exp(-(t - 0.055) / 0.006) : 0)
        return hp * 0.55 * a + low * 1.6 * exp(-t / 0.03)
    }
}

/// Filtered noise that sweeps up (or down) in pitch: a whoosh.
func whoosh(_ seconds: Double, from f0: Double = 250, to f1: Double = 2800) -> [Float] {
    var y1 = 0.0, y2 = 0.0
    return synth(seconds) { t in
        let x = t / seconds
        let fc = f0 * pow(f1 / f0, x)
        let a = 1 - exp(-2 * .pi * fc / sr)
        y1 += a * (noise.next() - y1)
        y2 += a * (y1 - y2)
        return y2 * pow(sin(.pi * x), 1.6) * 2.2
    }
}

/// A marker or a brush on paper: band of noise with a little grain.
func swish(_ seconds: Double) -> [Float] {
    var lp = 0.0, lp2 = 0.0
    return synth(seconds) { t in
        let x = t / seconds
        let n = noise.next()
        lp += 0.45 * (n - lp)
        lp2 += 0.12 * (lp - lp2)
        let band = lp - lp2
        let env = min(1, x / 0.08) * min(1, (1 - x) / 0.25)
        return band * env * (1 + 0.3 * sin(2 * .pi * 41 * t)) * 1.4
    }
}

func thud() -> [Float] {
    var phase = 0.0
    return synth(0.22) { t in
        phase += 2 * .pi * (150 * exp(-t / 0.06) + 60) / sr
        return sin(phase) * exp(-t / 0.07) * 0.9
    }
}

func tick() -> [Float] {
    synth(0.04) { t in sin(2 * .pi * 3100 * t) * exp(-t / 0.007) * 0.5 }
}

func chime() -> [Float] {
    synth(1.4) { t in
        var v = 0.0
        for (f, d) in [(1046.5, 0.0), (1568.0, 0.09)] where t >= d {
            let u = t - d
            v += (sin(2 * .pi * f * u) + 0.12 * sin(4 * .pi * f * u)) * min(1, u / 0.004) * exp(-u / 0.45)
        }
        return v * 0.45
    }
}

final class Mixer {
    let frames: Int
    var data: [Float]
    init(seconds: Double) {
        frames = Int(seconds * sr)
        data = [Float](repeating: 0, count: frames * 2)
    }
    func add(_ t: Double, _ s: [Float], gain: Float, pan: Float = 0) {
        let start = Int(t * sr)
        let gl = gain * (pan > 0 ? 1 - pan : 1), gr = gain * (pan < 0 ? 1 + pan : 1)
        for i in 0..<s.count {
            let j = start + i
            guard j >= 0 && j < frames else { continue }
            data[2 * j] += s[i] * gl
            data[2 * j + 1] += s[i] * gr
        }
    }
    func master() {
        let peak = data.map { abs($0) }.max() ?? 1
        let k = peak > 0 ? 0.8 / peak : 1
        for i in 0..<data.count { data[i] = tanh(data[i] * k * 1.1) / tanh(1.1) * 0.9 }
    }
}

func soundtrack() -> Mixer {
    let m = Mixer(seconds: T.end)
    let notes = [659.3, 740.0, 830.6, 880.0, 987.8, 1108.7, 1244.5, 1318.5]
    for i in 0..<chatFindings.count { m.add(1.4 + Double(i) * 0.17, pop(notes[min(i, notes.count - 1)]), gain: 0.5, pan: Float(i % 2 == 0 ? -0.15 : 0.15)) }
    m.add(T.abWipe.0, whoosh(0.4), gain: 0.5)
    m.add(T.abWipe.0 + 1.2, swish(0.45), gain: 0.6)
    m.add(T.bcSlide.0, whoosh(0.5, from: 1800, to: 300), gain: 0.5)
    let c = T.cStart
    for k in C.keys { m.add(c + k, click(), gain: 0.8) }
    m.add(c + C.shot, shutter(), gain: 0.7)
    m.add(c + C.cardIn, whoosh(0.3, from: 600, to: 2400), gain: 0.35)
    for i in 0..<shotFindings.count { m.add(c + C.marks + Double(i) * C.markStep, pop(notes[min(i + 2, notes.count - 1)]), gain: 0.3) }
    m.add(c + C.keep, click(), gain: 0.6)
    m.add(c + C.press, click(), gain: 0.7)
    m.add(c + C.ink, swish(0.75), gain: 0.65)
    m.add(c + C.applied, tick(), gain: 0.5)
    m.add(c + C.grab, click(), gain: 0.45)
    m.add(c + C.drop, thud(), gain: 0.55)
    m.add(c + C.drop, pop(880), gain: 0.35)
    m.add(c + C.reply, pop(1046.5), gain: 0.35)
    m.add(T.cdWipe.0, whoosh(0.4), gain: 0.5)
    let d = T.dStart
    for i in 0...pixelated.count { m.add(d + D.recover.0 + Double(i) * (D.recover.1 - D.recover.0) / Double(pixelated.count), tick(), gain: 0.5) }
    m.add(d + D.mark, swish(0.22), gain: 0.35)
    m.add(d + D.ink, swish(0.4), gain: 0.65)
    for i in 0..<facts.count { m.add(T.eStart + 0.25 + Double(i) * 0.5, swish(0.3), gain: 0.35) }
    m.add(T.efWipe.0, whoosh(0.4), gain: 0.5)
    m.add(T.fStart + 0.4, chime(), gain: 0.55)
    m.master()
    return m
}

// MARK: - Output

func writeFrames(_ times: [Double], to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for t in times {
        let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        render(ctx, t)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = dir.appendingPathComponent(String(format: "frame-%05.2f.png", t))
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}

func audioSample(_ mixer: Mixer, from: Int, count: Int) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                           mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let bytes = count * 8
    var blockBuffer: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &blockBuffer)
    guard let format, let blockBuffer else { return nil }
    mixer.data.withUnsafeBytes { raw in
        _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + from * 8, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes)
    }
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
                                                         sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(from), timescale: CMTimeScale(rate)),
                                                         packetDescriptions: nil, sampleBufferOut: &sample)
    return sample
}

func writeVideo(to url: URL) throws {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 16_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
        ],
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
    ])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
    ])
    audio.expectsMediaDataInRealTime = false
    writer.add(video)
    writer.add(audio)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "reel", code: 1) }
    writer.startSession(atSourceTime: .zero)

    let mixer = soundtrack()
    var audioPos = 0
    func pumpAudio(until frame: Int) {
        while audioPos < min(frame, mixer.frames) && audio.isReadyForMoreMediaData {
            let count = min(1024, mixer.frames - audioPos)
            if let s = audioSample(mixer, from: audioPos, count: count) { audio.append(s) }
            audioPos += count
        }
    }

    let total = Int(T.end * Double(fps))
    for i in 0..<total {
        autoreleasepool {
            let t = Double(i) / Double(fps)
            pumpAudio(until: Int((t + 0.5) * sr))
            while !video.isReadyForMoreMediaData {
                pumpAudio(until: Int((t + 1.5) * sr))
                usleep(1000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let pb = buffer else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(W), height: Int(H), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            render(ctx, t)
            CVPixelBufferUnlockBaseAddress(pb, [])
            // Tag the sRGB pixels as BT.709 as they are, the way phones play video. Letting the
            // encoder convert sRGB to the 709 curve darkens every colour on playback.
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            if i % 120 == 0 { print(String(format: "%5.1f / %.1f s", t, T.end)) }
        }
    }
    while audioPos < mixer.frames {
        if audio.isReadyForMoreMediaData { pumpAudio(until: mixer.frames) } else { usleep(1000) }
    }
    video.markAsFinished()
    audio.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "reel", code: 2) }
    print("wrote \(url.path), \(String(format: "%.1f", T.end)) s")
}

// MARK: - Main

_ = NSApplication.shared
let args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--frames"), i + 2 < args.count {
    let times = args[i + 1].split(separator: ",").compactMap { Double($0) }
    writeFrames(times, to: URL(fileURLWithPath: args[i + 2]))
} else {
    let out = args.first.map { URL(fileURLWithPath: $0) } ?? packageRoot.appendingPathComponent("build/reel/zamazka-reel.mp4")
    do { try writeVideo(to: out) } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
