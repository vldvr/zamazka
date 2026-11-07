import AppKit
import CoreGraphics
import Foundation
import Vision

/// One recognised line of text with a way to find where any part of it sits in the image.
struct OCRLine {
    let text: String
    /// Line box in image pixels, origin top-left.
    let box: CGRect
    let candidate: VNRecognizedText
    /// The part of the image this line was read from (a tile, or the whole image).
    let crop: CGRect

    /// Pixel box of a UTF-16 range of `text`.
    ///
    /// Vision answers with whole-word boxes: asking for «s3cr3tPass» inside
    /// «postgres://app:s3cr3tPass@db» returns the box of the whole URL. When the range is part of a
    /// word, the word box is cut down by where the range sits in the word, estimated two ways
    /// (equal-width characters and proportional system-font widths) and widened to cover both
    /// plus half a character, so the estimate errs on the side of hiding more.
    func box(for range: NSRange, imageSize: CGSize) -> CGRect? {
        let ns = text as NSString
        let word = Self.wordRange(around: range, in: ns)
        guard let r = Range(word, in: text),
              let obs = try? candidate.boundingBox(for: r) else { return nil }
        let wordBox = Detector.pixelRect(obs.boundingBox, in: crop)
        guard word != range, word.length > 0 else { return wordBox }

        let n = CGFloat(word.length)
        let monoStart = CGFloat(range.location - word.location) / n
        let monoEnd = CGFloat(range.location + range.length - word.location) / n
        let font = NSFont.systemFont(ofSize: 20)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let whole = max(1, width(ns.substring(with: word)))
        let before = width(ns.substring(with: NSRange(location: word.location, length: range.location - word.location)))
        let through = width(ns.substring(with: NSRange(location: word.location, length: range.location + range.length - word.location)))
        let propStart = before / whole, propEnd = through / whole
        let margin = 0.5 / n
        let start = max(0, min(monoStart, propStart) - margin)
        let end = min(1, max(monoEnd, propEnd) + margin)
        return CGRect(x: wordBox.minX + wordBox.width * start, y: wordBox.minY,
                      width: wordBox.width * (end - start), height: wordBox.height)
    }

    /// Grows a range to whole whitespace-separated words.
    static func wordRange(around range: NSRange, in ns: NSString) -> NSRange {
        func isSpace(_ i: Int) -> Bool {
            guard let u = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(u)
        }
        var start = range.location, end = range.location + range.length
        while start > 0, !isSpace(start - 1) { start -= 1 }
        while end < ns.length, !isSpace(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}

public struct DetectorOptions: Sendable {
    public var enabled: Set<FindingKind>
    public var customWords: [String]
    public var timeout: TimeInterval

    public init(enabled: Set<FindingKind> = Set(FindingKind.allCases), customWords: [String] = [], timeout: TimeInterval = 20) {
        self.enabled = enabled
        self.customWords = customWords
        self.timeout = timeout
    }
}

public struct Analysis: Sendable {
    public let size: CGSize
    public var findings: [Finding]
    /// Recognised lines, for the debug CLI.
    public let lines: [String]
    public let seconds: Double
}

public enum DetectorError: Error, LocalizedError {
    case timeout(TimeInterval)
    case vision(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let s): return "Распознавание текста не ответило за \(Int(s)) с."
        case .vision(let message): return "Системное распознавание текста вернуло ошибку три раза подряд. Обычно помогает «Проверить ещё раз». (\(message))"
        }
    }
}

/// Finds things to hide on an image: text through Vision OCR and the text scanner, plus faces and
/// QR codes and barcodes. Everything runs on this Mac.
public enum Detector {
    private static let queue = DispatchQueue(label: "com.vldvr.zamazka.vision", qos: .userInitiated, attributes: .concurrent)

    /// On macOS 27 the very first accurate OCR request in a session can take 20+ seconds while the
    /// model loads (later ones take a fraction of a second). Doing a tiny request at launch keeps
    /// that wait away from the first real screenshot.
    public static func prewarm() {
        warming.enter()
        queue.async {
            defer { warming.leave() }
            guard let image = tinyTextImage() else { return }
            let request = makeTextRequest()
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                Log.write("vision prewarmed")
            } catch {
                Log.write("vision prewarm failed: \(error)")
            }
        }
    }

    /// Held while the model loads. A second request during the load can fail with
    /// CRImageReaderError, so real checks wait for it.
    private static let warming = DispatchGroup()

    public static func analyze(_ image: CGImage, options: DetectorOptions) async throws -> Analysis {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<Analysis, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            queue.async {
                do { finish(.success(try analyzeSync(image, options: options))) }
                catch { finish(.failure(error)) }
            }
            // Vision has been seen to hang on some systems; never wait forever. The stuck work
            // keeps running on its own thread and its result is dropped.
            DispatchQueue.global().asyncAfter(deadline: .now() + options.timeout) {
                finish(.failure(DetectorError.timeout(options.timeout)))
            }
        }
    }

    static func analyzeSync(_ image: CGImage, options: DetectorOptions) throws -> Analysis {
        let started = Date()
        let size = CGSize(width: image.width, height: image.height)
        let wantsFaces = options.enabled.contains(.face)
        let wantsCodes = options.enabled.contains(.code)

        _ = warming.wait(timeout: .now() + 40)

        // Vision occasionally fails right after the model loads; a second try a moment later
        // works. Fresh requests each time.
        var text = makeTextRequest()
        var faces = VNDetectFaceRectanglesRequest()
        var codes = VNDetectBarcodesRequest()
        var failure: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: Double(attempt))
                text = makeTextRequest()
                faces = VNDetectFaceRectanglesRequest()
                codes = VNDetectBarcodesRequest()
            }
            var requests: [VNRequest] = [text]
            if wantsFaces { requests.append(faces) }
            if wantsCodes { requests.append(codes) }
            do {
                try VNImageRequestHandler(cgImage: image).perform(requests)
                failure = nil
                break
            } catch {
                failure = error
                Log.write("vision error on attempt \(attempt + 1): \(error)")
            }
        }
        if let failure { throw DetectorError.vision(failure.localizedDescription) }

        let whole = CGRect(origin: .zero, size: size)
        var lines = ocrLines(text, crop: whole)

        // On a big image Vision skips some lines outright (dense code on a dark background was
        // the case that showed it). Reading overlapping quarters again finds them; lines already
        // read in the first pass are not duplicated.
        if max(size.width, size.height) >= 1400 {
            for tile in tiles(of: size) {
                guard let crop = image.cropping(to: tile) else { continue }
                let request = makeTextRequest()
                try? VNImageRequestHandler(cgImage: crop).perform([request])
                for extra in ocrLines(request, crop: tile) {
                    // A line that runs into the tile's inner edge was cut by the crop; another
                    // tile or the full pass has it whole.
                    let m = extra.box.height * 0.6
                    let cut = (tile.minX > 0 && extra.box.minX - tile.minX < m)
                        || (tile.maxX < size.width && tile.maxX - extra.box.maxX < m)
                        || (tile.minY > 0 && extra.box.minY - tile.minY < m * 0.5)
                        || (tile.maxY < size.height && tile.maxY - extra.box.maxY < m * 0.5)
                    if cut { continue }
                    let covered = lines.contains { line in
                        let i = line.box.intersection(extra.box)
                        return !i.isNull && i.width * i.height > extra.box.width * extra.box.height * 0.3
                    }
                    if !covered { lines.append(extra) }
                }
            }
        }
        var findings = findText(in: lines, size: size, options: options)

        if wantsFaces {
            for face in faces.results ?? [] {
                let r = pixelRect(face.boundingBox, in: size)
                guard r.width >= 10, r.height >= 10 else { continue }
                // Face boxes are tight; widen to cover hair, ears and chin.
                let grown = r.insetBy(dx: -r.width * 0.22, dy: -r.height * 0.28).intersection(CGRect(origin: .zero, size: size))
                findings.append(Finding(kind: .face, rects: [grown], weak: r.width < 22))
            }
        }
        if wantsCodes {
            for code in codes.results ?? [] {
                let r = pixelRect(code.boundingBox, in: size)
                let pad = max(4, min(r.width, r.height) * 0.06)
                let grown = r.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: size))
                // The same code can be reported once per symbology guess.
                if findings.contains(where: { $0.kind == .code && $0.bounds.intersects(grown) }) { continue }
                findings.append(Finding(kind: .code, rects: [grown], text: code.payloadStringValue))
            }
        }

        return Analysis(size: size, findings: findings, lines: lines.map(\.text),
                        seconds: Date().timeIntervalSince(started))
    }

    static func ocrLines(_ request: VNRecognizeTextRequest, crop: CGRect) -> [OCRLine] {
        (request.results ?? []).compactMap { obs -> OCRLine? in
            guard let c = obs.topCandidates(1).first else { return nil }
            return OCRLine(text: c.string, box: pixelRect(obs.boundingBox, in: crop), candidate: c, crop: crop)
        }
    }

    /// Four overlapping quarters, each 60% of the width and height.
    static func tiles(of size: CGSize) -> [CGRect] {
        let tw = (size.width * 0.6).rounded(), th = (size.height * 0.6).rounded()
        return [CGPoint(x: 0, y: 0), CGPoint(x: size.width - tw, y: 0),
                CGPoint(x: 0, y: size.height - th), CGPoint(x: size.width - tw, y: size.height - th)]
            .map { CGRect(x: $0.x, y: $0.y, width: tw, height: th) }
    }

    static func makeTextRequest(languages: [String] = ["ru-RU", "en-US"]) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        // Language correction "fixes" numbers and codes into words. We want raw characters.
        request.usesLanguageCorrection = false
        // Screenshots of a whole screen have small text relative to the image height.
        request.minimumTextHeight = 0
        return request
    }

    /// Runs the text scanner on every line with its neighbours as context and turns matched
    /// ranges into padded pixel rectangles.
    static func findText(in lines: [OCRLine], size: CGSize, options: DetectorOptions) -> [Finding] {
        let scanner = TextScanner(enabled: options.enabled, customWords: options.customWords)
        let sorted = lines.sorted { $0.box.minY == $1.box.minY ? $0.box.minX < $1.box.minX : $0.box.minY < $1.box.minY }
        let bounds = CGRect(origin: .zero, size: size)
        var out: [Finding] = []
        for block in blocks(of: sorted) {
            // Scan the wrapped paragraph as one string so a phone split over two lines is found.
            var text = ""
            var offsets: [Int] = []
            for line in block {
                if !text.isEmpty { text += " " }
                offsets.append((text as NSString).length)
                text += line.text
            }
            let context = contextText(for: block, among: sorted)
            for match in scanner.scan(text, context: context.above + " " + context.left, label: context.label) {
                var rects: [CGRect] = []
                for (line, offset) in zip(block, offsets) {
                    let lineRange = NSRange(location: offset, length: (line.text as NSString).length)
                    let part = NSIntersectionRange(lineRange, match.range)
                    guard part.length > 0 else { continue }
                    let local = NSRange(location: part.location - offset, length: part.length)
                    var rect = line.box(for: local, imageSize: size) ?? line.box
                    // Substring boxes from Vision can come back wider than the line or empty.
                    if rect.width < 1 || rect.height < 1 { rect = line.box }
                    let h = line.box.height
                    rect = rect.intersection(line.box.insetBy(dx: -h, dy: -h * 0.2))
                    // Vision's boxes already include ascenders and descenders; a small margin
                    // covers anti-aliasing without eating neighbouring letters.
                    rect = rect.insetBy(dx: -max(2, h * 0.04), dy: -max(1, h * 0.03))
                    rect = rect.intersection(bounds).integral
                    if !rect.isNull, rect.width >= 1 { rects.append(rect) }
                }
                if !rects.isEmpty {
                    out.append(Finding(kind: match.kind, rects: rects, weak: match.weak, text: match.text))
                }
            }
        }
        return merge(out)
    }

    /// Groups lines into paragraphs: each next line sits right under the previous one, starts at
    /// about the same x and has about the same height (wrapped text in one bubble or field).
    static func blocks(of sorted: [OCRLine]) -> [[OCRLine]] {
        var blocks: [[OCRLine]] = []
        var used = Set<Int>()
        // A line with its own caption to the left is a form field, never a wrapped continuation.
        // Without this a column of values (name, phone, e-mail…) can read as one paragraph when
        // the rows are dense, and each value loses its caption.
        let captioned = Set(sorted.indices.filter { i in sorted.contains { other in isCaption(other, of: sorted[i]) } })
        for i in sorted.indices where !used.contains(i) {
            var block = [sorted[i]]
            used.insert(i)
            var last = sorted[i]
            var lastIndex = i
            while let j = sorted.indices.first(where: { j in
                guard !used.contains(j), !captioned.contains(j), !captioned.contains(lastIndex) else { return false }
                let next = sorted[j], h = last.box.height
                let gap = next.box.minY - last.box.maxY
                // Wrapped lines sit closer than form rows (line spacing is ~1.2 of the font).
                return gap > -h * 0.3 && gap < h * 0.5
                    && abs(next.box.minX - last.box.minX) < h * 1.2
                    && abs(next.box.height - h) < h * 0.35
            }) {
                lastIndex = j
                block.append(sorted[j])
                used.insert(j)
                last = sorted[j]
            }
            blocks.append(block)
        }
        return blocks
    }

    /// `other` sits to the left of `line` on the same row, close enough to be its caption.
    static func isCaption(_ other: OCRLine, of line: OCRLine) -> Bool {
        let b = line.box
        guard other.box.maxX <= b.minX + 2, b.minX - other.box.maxX < b.height * 12 else { return false }
        let overlap = min(other.box.maxY, b.maxY) - max(other.box.minY, b.minY)
        return overlap > min(other.box.height, b.height) * 0.5
    }

    struct Context {
        var above = ""
        var left = ""
        /// A short caption that names this value: the nearest text to the left on the same row
        /// («ФИО:» in a form), or a short line right above.
        var label = ""
    }

    /// The line above the paragraph and anything to the left of its first line on the same row.
    static func contextText(for block: [OCRLine], among lines: [OCRLine]) -> Context {
        let b = block[0].box
        let inBlock = Set(block.map { ObjectIdentifier($0.candidate) })
        var ctx = Context()
        let above = lines.last(where: { other in
            !inBlock.contains(ObjectIdentifier(other.candidate))
                && other.box.maxY <= b.minY + b.height * 0.3 && b.minY - other.box.maxY < b.height * 2.2
                && other.box.maxX > b.minX - b.height * 2 && other.box.minX < b.maxX
        })
        ctx.above = above?.text ?? ""
        let left = lines.filter { other in
            guard other.box.maxX <= b.minX + 2 else { return false }
            let overlap = min(other.box.maxY, b.maxY) - max(other.box.minY, b.minY)
            return overlap > min(other.box.height, b.height) * 0.5
        }.sorted { $0.box.maxX < $1.box.maxX }
        ctx.left = left.map(\.text).joined(separator: " ")
        if let nearest = left.last, b.minX - nearest.box.maxX < b.height * 12 {
            ctx.label = nearest.text
        } else if let above, above.text.count <= 40, abs(above.box.minX - b.minX) < b.height * 1.5 {
            ctx.label = above.text
        }
        return ctx
    }

    /// Joins findings of the same kind whose rectangles overlap, so one value reported twice
    /// becomes one switch in the card. Rectangles are kept apart, not unioned: a value wrapped
    /// over two lines must not cover the words between its parts.
    static func merge(_ findings: [Finding]) -> [Finding] {
        var out: [Finding] = []
        for f in findings {
            if let i = out.firstIndex(where: { o in
                o.kind == f.kind && o.weak == f.weak && o.rects.contains { r in f.rects.contains { $0.intersects(r) } }
            }) {
                var rects = out[i].rects
                for r in f.rects {
                    if let k = rects.firstIndex(where: { $0.intersects(r) }) { rects[k] = rects[k].union(r) }
                    else { rects.append(r) }
                }
                out[i] = Finding(kind: f.kind, rects: rects, weak: f.weak, text: out[i].text)
            } else {
                out.append(f)
            }
        }
        return out
    }

    /// Vision's normalised rectangles have the origin at the bottom left.
    static func pixelRect(_ r: CGRect, in size: CGSize) -> CGRect {
        pixelRect(r, in: CGRect(origin: .zero, size: size))
    }

    /// Same, for a rectangle normalised to a crop of the image.
    static func pixelRect(_ r: CGRect, in crop: CGRect) -> CGRect {
        CGRect(x: crop.minX + r.minX * crop.width, y: crop.minY + (1 - r.maxY) * crop.height,
               width: r.width * crop.width, height: r.height * crop.height)
    }

    private static func tinyTextImage() -> CGImage? {
        let w = 240, h = 48
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let attr = NSAttributedString(string: "Проверка 123", attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 22, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 8, y: 14)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
