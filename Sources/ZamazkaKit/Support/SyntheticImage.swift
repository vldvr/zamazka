import AppKit
import CoreImage

/// Made-up screenshots for the checks, the demo in onboarding and the README pictures.
/// Every number in them is invented; check digits are valid so the detector has something real
/// to chew on.
public enum SyntheticImage {
    // MARK: - Invented data

    public static let card = Validators.luhnComplete("220220000000123")
    public static let cardGrouped = stride(from: 0, to: 16, by: 4).map { i in
        String(card.dropFirst(i).prefix(4))
    }.joined(separator: " ")
    public static let inn = Validators.innComplete("7700000000")

    struct Message {
        let outgoing: Bool
        let text: String
        let time: String
    }

    static let chatMessages: [Message] = [
        Message(outgoing: false, text: "Привет! Скинь данные для пропуска, завтра закажу", time: "18:02"),
        Message(outgoing: true, text: "Паспорт 45 08 123456, выдан ОВД района Хамовники", time: "18:04"),
        Message(outgoing: true, text: "СНИЛС 112-233-445 95", time: "18:04"),
        Message(outgoing: false, text: "А документы куда привезти?", time: "18:05"),
        Message(outgoing: true, text: "г. Москва, ул. Тверская, д. 7, кв. 12. Мой номер +7 (916) 123-45-67, звони после шести", time: "18:06"),
        Message(outgoing: false, text: "Ок. Машина та же, А123ВС 777?", time: "18:07"),
        Message(outgoing: true, text: "Да. И скинь за билет на карту \(cardGrouped)", time: "18:07"),
        Message(outgoing: true, text: "Трек посылки RA123456785RU, чек пришлют на ivan.petrov@example.ru", time: "18:08"),
    ]

    static let plainMessages: [Message] = [
        Message(outgoing: false, text: "Привет! Как дела?", time: "12:30"),
        Message(outgoing: true, text: "Нормально, еду домой. Встречаемся в 19:00 у входа?", time: "12:31"),
        Message(outgoing: false, text: "Да, только возьми зонт, обещают дождь", time: "12:33"),
        Message(outgoing: true, text: "Хорошо, до встречи", time: "12:34"),
    ]

    // MARK: - Scenes

    struct Palette {
        let background, header, incoming, outgoing, text, muted, line, avatar: NSColor
        static let light = Palette(
            background: NSColor(hex: 0xECEFF3), header: NSColor(hex: 0xFFFFFF),
            incoming: NSColor(hex: 0xFFFFFF), outgoing: NSColor(hex: 0xDCE7F5),
            text: NSColor(hex: 0x15181C), muted: NSColor(hex: 0x6B737D), line: NSColor(hex: 0xDADFE5),
            avatar: NSColor(hex: 0x7C8B9C))
        static let dark = Palette(
            background: NSColor(hex: 0x16181C), header: NSColor(hex: 0x202328),
            incoming: NSColor(hex: 0x262A30), outgoing: NSColor(hex: 0x2C3A4C),
            text: NSColor(hex: 0xE9ECEF), muted: NSColor(hex: 0x8D96A0), line: NSColor(hex: 0x2E3238),
            avatar: NSColor(hex: 0x5C6B7C))
    }

    /// A messenger window. Not any particular app.
    public static func chat(scale: CGFloat = 2, dark: Bool = false, width: CGFloat = 760) -> CGImage {
        chatScene(chatMessages, scale: scale, dark: dark, name: "Аня Королёва", initials: "АК", width: width)
    }

    public static func plain(scale: CGFloat = 2) -> CGImage {
        chatScene(plainMessages, scale: scale, dark: false, name: "Миша", initials: "М")
    }

    static func chatScene(_ messages: [Message], scale: CGFloat, dark: Bool, name: String, initials: String, width: CGFloat = 760) -> CGImage {
        let p = dark ? Palette.dark : Palette.light
        let font = NSFont.systemFont(ofSize: 15)
        let timeFont = NSFont.systemFont(ofSize: 11)
        let maxBubble: CGFloat = min(440, width * 0.74)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2

        // Measure first to know the height.
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: p.text, .paragraphStyle: para]
        let sizes = messages.map { m -> CGSize in
            let s = NSAttributedString(string: m.text, attributes: attrs)
            let r = s.boundingRect(with: CGSize(width: maxBubble - 28 - 34, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
            return CGSize(width: ceil(r.width), height: ceil(r.height))
        }
        let header: CGFloat = 64
        var height = header + 18
        for (i, s) in sizes.enumerated() {
            height += s.height + 18 + (i > 0 && messages[i].outgoing != messages[i - 1].outgoing ? 12 : 4)
        }
        height += 22

        return render(width: width, height: height, scale: scale) { bounds in
            p.background.setFill()
            bounds.fill()
            p.header.setFill()
            CGRect(x: 0, y: 0, width: width, height: header).fill()
            p.line.setFill()
            CGRect(x: 0, y: header - 1, width: width, height: 1).fill()

            let avatar = CGRect(x: 20, y: 12, width: 40, height: 40)
            p.avatar.setFill()
            NSBezierPath(ovalIn: avatar).fill()
            let ini = NSAttributedString(string: initials, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
            let isz = ini.size()
            ini.draw(at: CGPoint(x: avatar.midX - isz.width / 2, y: avatar.midY - isz.height / 2))
            NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: p.text])
                .draw(at: CGPoint(x: 72, y: 13))
            NSAttributedString(string: "была недавно", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: p.muted])
                .draw(at: CGPoint(x: 72, y: 34))

            var y = header + 18
            for (i, m) in messages.enumerated() {
                if i > 0 { y += messages[i].outgoing != messages[i - 1].outgoing ? 12 : 4 }
                let s = sizes[i]
                let bubble = CGSize(width: s.width + 28 + 34, height: s.height + 18)
                let x = m.outgoing ? width - 20 - bubble.width : 20
                let rect = CGRect(x: x, y: y, width: bubble.width, height: bubble.height)
                (m.outgoing ? p.outgoing : p.incoming).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()
                NSAttributedString(string: m.text, attributes: attrs)
                    .draw(with: CGRect(x: rect.minX + 14, y: rect.minY + 9, width: s.width + 1, height: s.height + 2),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
                let t = NSAttributedString(string: m.time, attributes: [.font: timeFont, .foregroundColor: p.muted])
                t.draw(at: CGPoint(x: rect.maxX - 12 - t.size().width, y: rect.maxY - 8 - t.size().height))
                y += bubble.height
            }
        }
    }

    /// A whole screen at 1440×900 points with a profile form and a config file: small text in a
    /// large image, the hard case for OCR.
    public static func screen(scale: CGFloat = 2) -> CGImage {
        let width: CGFloat = 1440, height: CGFloat = 900
        return render(width: width, height: height, scale: scale) { bounds in
            NSColor(hex: 0xD9DEE4).setFill(); bounds.fill()
            NSColor(hex: 0xF6F7F9).setFill(); CGRect(x: 0, y: 0, width: width, height: 26).fill()
            text("Файл   Правка   Вид   Окно", at: CGPoint(x: 16, y: 5), size: 13, color: NSColor(hex: 0x2A2E33))

            // Left window: a profile form.
            let w1 = CGRect(x: 60, y: 70, width: 640, height: 560)
            window(w1, title: "Личный кабинет")
            let rows: [(String, String)] = [
                ("ФИО:", "Петров Иван Сергеевич"),
                ("Телефон:", "+7 495 123-45-67"),
                ("Почта:", "i.petrov@example.ru"),
                ("ИНН:", inn),
                ("Дата рождения:", "01.02.1990"),
                ("Адрес доставки:", "125009, Москва, Тверская улица, 7"),
            ]
            for (i, row) in rows.enumerated() {
                let y = w1.minY + 64 + CGFloat(i) * 34
                text(row.0, at: CGPoint(x: w1.minX + 28, y: y), size: 13, color: NSColor(hex: 0x6B737D))
                text(row.1, at: CGPoint(x: w1.minX + 170, y: y), size: 13, color: NSColor(hex: 0x15181C))
            }
            text("Изменения сохранятся после подтверждения по SMS.", at: CGPoint(x: w1.minX + 28, y: w1.minY + 290), size: 12, color: NSColor(hex: 0x6B737D))

            // Right window: a config file.
            let w2 = CGRect(x: 760, y: 120, width: 620, height: 420)
            window(w2, title: ".env", dark: true)
            let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let lines = [
                "# production",
                "API_KEY=sk-proj-9fK2mQ7xL0pR4tV8wZ1aB3cD5eF6gH7jK8",
                "DATABASE_URL=postgres://app:s3cr3tPass@db.internal:5432/app",
                "SERVER_IP=93.184.216.34",
                "DEBUG=false",
            ]
            for (i, l) in lines.enumerated() {
                NSAttributedString(string: l, attributes: [.font: mono, .foregroundColor: NSColor(hex: i == 0 ? 0x7F8A96 : 0xE2E6EA)])
                    .draw(at: CGPoint(x: w2.minX + 20, y: w2.minY + 52 + CGFloat(i) * 22))
            }
        }
    }

    public static func qr(scale: CGFloat = 2) -> CGImage {
        let width: CGFloat = 420, height: CGFloat = 480
        return render(width: width, height: height, scale: scale) { bounds in
            NSColor(hex: 0xF4F5F7).setFill(); bounds.fill()
            text("Электронный билет", at: CGPoint(x: 40, y: 32), size: 20, color: NSColor(hex: 0x15181C), weight: .semibold)
            text("Покажите код на входе", at: CGPoint(x: 40, y: 62), size: 14, color: NSColor(hex: 0x6B737D))
            if let code = qrCode("https://example.com/t/7F3K9Q2M", side: 300) {
                NSGraphicsContext.current?.cgContext.saveGState()
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: code, size: CGSize(width: 300, height: 300)).draw(in: CGRect(x: 60, y: 120, width: 300, height: 300))
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        }
    }

    // MARK: - Small helpers for checks

    public static func solid(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> CGImage {
        let ctx = bitmap(width, height)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Copy of `image` with a flat patch (top-left coordinates).
    public static func withPatch(_ image: CGImage, _ r: CGRect, rgb: (UInt8, UInt8, UInt8)) -> CGImage {
        let ctx = bitmap(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height))
        return ctx.makeImage()!
    }

    /// Pixel at top-left coordinates, as sRGB bytes.
    public static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let ctx = bitmap(1, 1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
        return (p[0], p[1], p[2])
    }

    // MARK: - Drawing

    static func bitmap(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Draws with AppKit in a top-left coordinate space and returns a bitmap at `scale`.
    static func render(width: CGFloat, height: CGFloat, scale: CGFloat, _ draw: (CGRect) -> Void) -> CGImage {
        let ctx = bitmap(Int(width * scale), Int(height * scale))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
    }

    static func window(_ r: CGRect, title: String, dark: Bool = false) {
        NSGraphicsContext.current?.cgContext.saveGState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.set()
        NSColor(hex: dark ? 0x1E2126 : 0xFFFFFF).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            NSColor(hex: UInt32(c)).setFill()
            NSBezierPath(ovalIn: CGRect(x: r.minX + 16 + CGFloat(i) * 20, y: r.minY + 14, width: 12, height: 12)).fill()
        }
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                .foregroundColor: NSColor(hex: dark ? 0xC9CED4 : 0x3A3F45)])
        t.draw(at: CGPoint(x: r.midX - t.size().width / 2, y: r.minY + 11))
    }

    static func qrCode(_ payload: String, side: CGFloat) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let k = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: k, y: k))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
