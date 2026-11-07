// Checks for the detector and the redactor on synthetic data only: made-up numbers with valid
// checksums, rendered into images on the fly. No real documents.
//   swift run zamazka-checks            all checks
//   swift run zamazka-checks text       text scanner only (no Vision)
// Exits non-zero if anything fails.

import AppKit
import ImageIO
import Vision
@testable import ZamazkaKit

var passed = 0
var failed: [String] = []

func check(_ condition: @autoclosure () throws -> Bool, _ name: String, line: Int = #line) {
    do {
        if try condition() { passed += 1 } else { failed.append("\(name) (line \(line))") }
    } catch {
        failed.append("\(name) (line \(line)): \(error)")
    }
}

let scanner = TextScanner()

/// Kinds and texts found in a line.
func found(_ line: String, context: String = "", scanner s: TextScanner = scanner) -> [(FindingKind, String)] {
    s.scan(line, context: context).filter { !$0.weak }.map { ($0.kind, $0.text) }
}

/// The line has exactly this one finding.
func expect(_ line: String, _ kind: FindingKind, _ text: String, context: String = "", line l: Int = #line) {
    let f = found(line, context: context)
    check(f.count == 1 && f[0].0 == kind && f[0].1 == text, "\(kind) in «\(line)» → \(f)", line: l)
}

/// The line has nothing strong.
func clean(_ line: String, context: String = "", line l: Int = #line) {
    let f = found(line, context: context)
    check(f.isEmpty, "nothing in «\(line)» → \(f)", line: l)
}

// MARK: - Synthetic identifiers with valid check digits

func innPerson(_ first10: String) -> String {
    let d = first10.compactMap(\.wholeNumberValue)
    let w11 = [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
    let n11 = zip(w11, d).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
    let w12 = [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
    let n12 = zip(w12, d + [n11]).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
    return first10 + "\(n11)\(n12)"
}

func innCompany(_ first9: String) -> String {
    let d = first9.compactMap(\.wholeNumberValue)
    let w = [2, 4, 10, 3, 5, 9, 4, 6, 8]
    return first9 + "\(zip(w, d).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10)"
}

func grouped(_ s: String, _ size: Int = 4) -> String {
    stride(from: 0, to: s.count, by: size).map { i -> String in
        let a = s.index(s.startIndex, offsetBy: i)
        let b = s.index(a, offsetBy: min(size, s.count - i))
        return String(s[a..<b])
    }.joined(separator: " ")
}

let mir = Validators.luhnComplete("220220000000123")        // 16 digits, Мир range
let visa = Validators.luhnComplete("427600000000045")
let badCard = String(visa.dropLast()) + String((Int(String(visa.last!))! + 1) % 10)
let inn12 = innPerson("7700000000")
let inn10 = innCompany("770000000")
let snils = "112-233-445 95"
let track = "RA123456785RU"

// MARK: - Validators

check(Validators.luhn(mir) && Validators.luhn(visa), "luhn accepts generated numbers")
check(!Validators.luhn(badCard), "luhn rejects a changed digit")
check(Validators.inn(inn12) && Validators.inn(inn10), "inn accepts generated numbers")
check(!Validators.inn("770000000001"), "inn rejects a wrong check digit")
check(Validators.snils(snils), "snils accepts the documented example")
check(!Validators.snils("112-233-445 96"), "snils rejects a wrong checksum")
check(Validators.s10(track), "s10 accepts a valid tracking number")
check(!Validators.s10("RA123456784RU"), "s10 rejects a wrong check digit")
check(Validators.isPrivateIPv4("192.168.1.10") && !Validators.isPrivateIPv4("93.184.216.34"), "private ip ranges")

// MARK: - Text scanner: Russian formats

expect("Мой номер +7 (916) 123-45-67, звони после шести", .phone, "+7 (916) 123-45-67")
expect("звони 8 916 123 45 67", .phone, "8 916 123 45 67")
expect("Тел.: 89161234567", .phone, "89161234567")
expect("WhatsApp +375 29 123-45-67", .phone, "+375 29 123-45-67")
expect("Карта для перевода: \(grouped(mir)), Сбер", .card, grouped(mir))
expect("visa \(visa)", .card, visa)
expect("на карту \(grouped(mir)) 18:07", .card, grouped(mir))
clean("Карта \(grouped(badCard))")
expect("Паспорт 45 08 123456 выдан ОВД района", .passport, "45 08 123456")
expect("4508 123456", .passport, "4508 123456", context: "Паспорт гражданина РФ")
expect("серия 4508", .passport, "4508", context: "паспорт")
expect("Код подразделения: 770-001", .passport, "770-001")
expect("СНИЛС \(snils)", .snils, snils)
expect("\(snils)", .snils, snils)
expect("ИНН \(inn12)", .inn, inn12)
expect("\(inn12)", .inn, inn12)
expect("ИНН организации \(inn10)", .inn, inn10)
clean(inn10)                                           // 10 digits without a label: too common
expect("Полис ОМС 7700 0000 0000 0000", .oms, "7700 0000 0000 0000")
expect("р/с 40817810099910004312", .account, "40817810099910004312")
expect("40817 810 0 99910004312", .account, "40817 810 0 99910004312")
clean("к/с 30101810400000000225")
expect("Адрес: г. Москва, ул. Тверская, д. 7, кв. 12", .address, "г. Москва, ул. Тверская, д. 7, кв. 12")
expect("Адрес: r. Москва, ул. Тверская, д. 7", .address, "r. Москва, ул. Тверская, д. 7")
expect("Привезите на Невский проспект 28, подъезд 2", .address, "Невский проспект 28, подъезд 2")
expect("Казань, ул. Баумана 15, кв. 4", .address, "Казань, ул. Баумана 15, кв. 4")
expect("Госномер А123ВС 777", .plate, "А123ВС 777")
expect("номер машины a123bc77", .plate, "a123bc77")
expect("Заказ № 4510-2238-11 передан в доставку", .order, "4510-2238-11")
expect("Order #A1B2C3D4", .order, "A1B2C3D4")
expect("Трек-номер \(track)", .track, track)
expect("\(track) прибыло в сортировочный центр", .track, track)
expect("Трек 80081234567890", .track, "80081234567890")
expect("ФИО: Петров Иван Сергеевич", .person, "Петров Иван Сергеевич")
expect("Получатель Иванова А. В.", .person, "Иванова А. В")
expect("Дата рождения: 01.02.1990", .birthdate, "01.02.1990")

// MARK: - Text scanner: general formats

expect("Почта ivan.petrov@example.ru", .email, "ivan.petrov@example.ru")
expect("пишите на почта@пример.рф", .email, "почта@пример.рф")
expect("сервер 93.184.216.34:8080", .ip, "93.184.216.34:8080")
expect("2001:db8:85a3::8a2e:370:7334", .ip, "2001:db8:85a3::8a2e:370:7334")
check(scanner.scan("роутер 192.168.10.24").allSatisfy(\.weak), "private ip is weak")
expect("sk-ant-api03-AbCdEfGh1234567890AbCdEfGh1234567890xyz", .secret, "sk-ant-api03-AbCdEfGh1234567890AbCdEfGh1234567890xyz")
expect("token: ghp_0000aaaa1111bbbb2222cccc3333dddd4444", .secret, "ghp_0000aaaa1111bbbb2222cccc3333dddd4444")
expect("AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP", .secret, "AKIAABCDEFGHIJKLMNOP")
expect("бот 1234567890:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw0", .secret, "1234567890:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw0")
expect("Authorization: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJlLXBhcnQ", .secret, "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJlLXBhcnQ")
expect("пароль: Kx9-mPq2!", .password, "Kx9-mPq2!")
expect("password=hunter2hunter", .password, "hunter2hunter")
expect("postgres://app:s3cr3tPass@db.local:5432/app", .password, "s3cr3tPass")
expect("-----BEGIN OPENSSH PRIVATE KEY-----", .secret, "-----BEGIN OPENSSH PRIVATE KEY-----")
check(scanner.scan("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUxOQ").contains { $0.kind == .secret },
      "base64 block line is at least a weak secret")

// MARK: - Things that must stay visible

clean("Привет! Как дела? Встречаемся в 12:30 у метро")
clean("Сегодня 07.11.2026, завтра 08.11.2026")
clean("Итого 1 234 567 ₽, скидка 15%")
clean("Версия 1.2.3.4 вышла")
clean("Заказ доставлен, спасибо")
clean("3f786850e387550fdab836ed7e6dc881de23001b")
clean("SwiftUI NavigationSplitView ColumnVisibility")
clean("Номер телефона можно скрыть в настройках")
clean("ул. Ленина")
clean("Счёт 1:0 в пользу хозяев")

// Form fields with the caption to the left.
check(scanner.scan("Петров Иван Сергеевич", label: "ФИО:").map(\.kind) == [.person], "field: name next to «ФИО:»")
check(scanner.scan("01.02.1990", label: "Дата рождения:").map(\.kind) == [.birthdate], "field: date next to its caption")
check(scanner.scan("Новый пользователь", label: "Статус:").isEmpty, "field: unrelated caption")
check(scanner.scan("Добро пожаловать", label: "ФИО:").isEmpty, "field: lower-case words are not a name")

// Wrapped over two lines (scanned as one paragraph).
expect("кв. 12. Мой номер +7 (916) 123-45-67, звони после шести", .phone, "+7 (916) 123-45-67")

// MARK: - Settings

let noPhones = TextScanner(enabled: Set(FindingKind.allCases).subtracting([.phone]))
check(found("+7 916 123-45-67", scanner: noPhones).isEmpty, "a switched-off kind is not reported")
let mine = TextScanner(customWords: ["Ворошилов"])
check(found("Здравствуйте, Ворошилову привет", scanner: mine).map(\.0) == [.custom], "custom words, any case and ending")

// MARK: - Timing: `swift run zamazka-checks timing`

if CommandLine.arguments.dropFirst().first == "timing" {
    let image = SyntheticImage.screen()
    do {
        let t = Date()
        let tiny = SyntheticImage.plain(scale: 1)
        let r = Detector.makeTextRequest()
        try? VNImageRequestHandler(cgImage: tiny).perform([r])
        print("prewarm small", String(format: "%.2fs", Date().timeIntervalSince(t)))
    }
    if CommandLine.arguments.contains("tiles") {
        let w = image.width, h = image.height
        for (name, rect) in [("right half", CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)),
                             ("left half", CGRect(x: 0, y: 0, width: w / 2, height: h / 2))] {
            let crop = image.cropping(to: rect)!
            let t = Date()
            let r = Detector.makeTextRequest()
            try? VNImageRequestHandler(cgImage: crop).perform([r])
            let lines = (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            print(name, String(format: "%.2fs", Date().timeIntervalSince(t)), lines)
        }
    }
    for round in 1...2 {
        for langs in [["ru-RU", "en-US"], ["en-US"]] {
            let t = Date()
            let r = Detector.makeTextRequest(languages: langs)
            try? VNImageRequestHandler(cgImage: image).perform([r])
            let lines = (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            print(round, langs, String(format: "%.2fs", Date().timeIntervalSince(t)), lines.count, lines.contains { $0.hasPrefix("API_KEY") } ? "has API_KEY" : "no API_KEY")
        }
    }
    exit(0)
}

// MARK: - Debug dump: `swift run zamazka-checks dump chat|screen|dark|plain|qr`

if CommandLine.arguments.dropFirst().first == "dump" {
    let name = CommandLine.arguments.dropFirst(2).first ?? "chat"
    let image: CGImage = {
        switch name {
        case "screen": return SyntheticImage.screen()
        case "dark": return SyntheticImage.chat(dark: true)
        case "plain": return SyntheticImage.plain()
        case "qr": return SyntheticImage.qr()
        default: return SyntheticImage.chat()
        }
    }()
    let sem = DispatchSemaphore(value: 0)
    Task {
        let a = try await Detector.analyze(image, options: DetectorOptions(timeout: 60))
        for l in a.lines { print("LINE  \(l)") }
        for f in a.findings { print("FIND  \(f.kind.rawValue)\(f.weak ? " (weak)" : "")  \(f.text ?? "")  \(f.rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })") }
        print(String(format: "%.2fs", a.seconds))
        if let out = CommandLine.arguments.dropFirst(3).first,
           let cleaned = Redactor.render(image, rects: a.findings.filter(\.enabled).flatMap(\.rects), style: RedactStyle()) {
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cleaned, nil)
            CGImageDestinationFinalize(dest)
            let b = try await Detector.analyze(cleaned, options: DetectorOptions(timeout: 60))
            for l in b.lines { print("AFTER \(l)") }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// MARK: - Images: OCR, detection and redaction end to end

if CommandLine.arguments.dropFirst().first != "text" {
    let fixtures = SyntheticImage.self

    func analyze(_ image: CGImage) async throws -> Analysis {
        try await Detector.analyze(image, options: DetectorOptions(timeout: 60))
    }

    /// When a scene's checks fail, show what Vision read: OCR differs between macOS versions
    /// and this is the only way to see it on a CI machine.
    func diagnose(_ scene: String, _ a: Analysis, since before: Int) {
        guard failed.count > before else { return }
        print("--- \(scene): what Vision read")
        for l in a.lines { print("    | \(l)") }
        for f in a.findings { print("    = \(f.kind.rawValue)\(f.weak ? " (weak)" : ""): \(f.text ?? "")") }
    }

    let sem = DispatchSemaphore(value: 0)
    Task {
        defer { sem.signal() }
        do {
            // A chat-like screenshot at 2x with a mix of data.
            let chat = fixtures.chat(scale: 2)
            var mark = failed.count
            let a = try await analyze(chat)
            let kinds = Set(a.findings.filter { !$0.weak }.map(\.kind))
            for k in [FindingKind.phone, .card, .passport, .snils, .address, .email, .plate, .track] {
                check(kinds.contains(k), "chat image: \(k) found (got \(kinds.map(\.rawValue).sorted()))")
            }
            check(a.findings.allSatisfy { f in f.rects.allSatisfy { CGRect(origin: .zero, size: a.size).contains($0) } },
                  "chat image: rectangles inside the image")
            diagnose("chat", a, since: mark)

            // After hiding, a second pass must find nothing strong.
            let rects = a.findings.filter(\.enabled).flatMap(\.rects)
            if let cleaned = Redactor.render(chat, rects: rects, style: RedactStyle()) {
                let b = try await analyze(cleaned)
                let left = b.findings.filter { !$0.weak && $0.kind != .face && $0.kind != .code }
                check(left.isEmpty, "chat image: nothing readable after redaction (left: \(left.map { "\($0.kind.rawValue)=\($0.text ?? "")" }))")
                // The text that should stay is still there.
                check(b.lines.contains { $0.contains("звони после шести") }, "chat image: ordinary text survives redaction")
            } else {
                check(false, "chat image: redactor returned an image")
            }

            // A whole-screen capture: small text in a big image.
            let screen = fixtures.screen(scale: 2)
            mark = failed.count
            let s = try await analyze(screen)
            let sk = Set(s.findings.filter { !$0.weak }.map(\.kind))
            for k in [FindingKind.phone, .email, .inn, .person, .birthdate, .address, .secret, .password, .ip] {
                check(sk.contains(k), "full screen: \(k) found (got \(sk.map(\.rawValue).sorted()))")
            }
            // A password inside a URL must not hide the whole line.
            if let pw = s.findings.first(where: { $0.kind == .password }) {
                check(pw.bounds.width < 600, "full screen: password box is cut to the password (\(Int(pw.bounds.width)) px)")
            }
            diagnose("full screen", s, since: mark)

            // Dark theme.
            let dark = fixtures.chat(scale: 2, dark: true)
            let d = try await analyze(dark)
            check(Set(d.findings.map(\.kind)).isSuperset(of: [.phone, .card]), "dark chat: phone and card found")

            // QR code.
            let qr = fixtures.qr(scale: 2)
            let q = try await analyze(qr)
            check(q.findings.contains { $0.kind == .code }, "qr image: code found")

            // Nothing to hide: a plain message stays quiet.
            let plain = fixtures.plain(scale: 2)
            let p = try await analyze(plain)
            check(!p.findings.hasStrong, "plain image: nothing strong (got \(p.findings.map { "\($0.kind.rawValue)=\($0.text ?? "")" }))")
        } catch {
            check(false, "image checks threw: \(error)")
        }
    }
    sem.wait()

    // Redactor details.
    let tile = fixtures.solid(width: 40, height: 20, rgb: (240, 240, 240))
    let area = CGRect(x: 10, y: 5, width: 20, height: 10)
    let ink = Redactor.render(tile, rects: [area], style: RedactStyle(fill: .solid, color: .ink))!
    check(SyntheticImage.pixel(ink, 20, 10) == (Redactor.ink.r, Redactor.ink.g, Redactor.ink.b), "solid ink fills the centre")
    check(SyntheticImage.pixel(ink, 2, 2) == (240, 240, 240), "solid ink leaves the rest")
    let bg = Redactor.render(tile, rects: [area], style: RedactStyle(fill: .solid, color: .background))!
    check(SyntheticImage.pixel(bg, 20, 10) == (240, 240, 240), "background fill matches the surroundings")
    // The noise fill must not depend on what was under it: same surroundings, different insides.
    let a1 = SyntheticImage.withPatch(tile, area, rgb: (0, 0, 0))
    let a2 = SyntheticImage.withPatch(tile, area, rgb: (255, 0, 0))
    let n1 = Redactor.render(a1, rects: [area], style: RedactStyle(fill: .noise))!
    let n2 = Redactor.render(a2, rects: [area], style: RedactStyle(fill: .noise))!
    var reds = 0
    for y in 0..<10 {
        for x in 0..<20 {
            let px: (UInt8, UInt8, UInt8) = SyntheticImage.pixel(n2, 10 + x, 5 + y)
            if px.0 > 200 && px.1 < 60 { reds += 1 }
        }
    }
    check(reds == 0, "noise fill keeps nothing of the hidden red")
    check(SyntheticImage.pixel(n1, 20, 10) != (0, 0, 0), "noise fill covers the hidden black")
}

// MARK: - Putting the result back: files, clipboard, undo

if CommandLine.arguments.dropFirst().first != "text" {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zamazka-checks-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let chat = SyntheticImage.chat(scale: 2)
        let originalPNG = ImageFile.png(chat, dpi: 144)!
        let analysis = try? Detector.analyzeSync(chat, options: DetectorOptions())
        let pb = NSPasteboard(name: NSPasteboard.Name("com.vldvr.zamazka.checks.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let center = CaptureCenter(pasteboard: pb)

        // Vision keeps its compiled model in the app's Caches folder; only our own subfolder
        // may ever be deleted.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        check(CaptureCenter.cacheFolder.deletingLastPathComponent().path != caches.path
              && CaptureCenter.cacheFolder.lastPathComponent == "Drag", "cache: drag copies live in a subfolder, not next to Vision's model cache")

        // A screenshot file with the flag macOS puts on it.
        let file = dir.appendingPathComponent("Снимок экрана — 2026-11-07 в 12.00.00.png")
        try? originalPNG.write(to: file)
        let flag = try! PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        ImageFile.setAttributes(file, [ScreenshotPlaces.screenCaptureAttribute: flag])
        check(ScreenshotPlaces.isScreenshot(file), "file: recognised by its screen-capture flag")
        check(ScreenshotPlaces.nameLooksLikeScreenshot("Снимок экрана — 2026-11-07 в 12.00.00.png"), "file: macOS 27 Russian name")
        check(ScreenshotPlaces.nameLooksLikeScreenshot("CleanShot 2026-11-07 at 12.00.00@2x.png"), "file: CleanShot name")
        check(!ScreenshotPlaces.nameLooksLikeScreenshot("отчёт.png"), "file: other names are not screenshots")

        let loaded = ImageFile.decode(originalPNG)!
        let session = Session(origin: .system, loaded: loaded)
        session.add(.file(file), originalData: originalPNG, attributes: ImageFile.attributes(file, ImageFile.keptAttributes))
        session.findings = analysis?.findings ?? []
        session.state = .review
        center.apply(session)

        let written = (try? Data(contentsOf: file)) ?? Data()
        check(session.state == .applied && written != originalPNG, "file: replaced after «Скрыть»")
        check(ScreenshotPlaces.hasAttribute(ScreenshotPlaces.screenCaptureAttribute, file), "file: keeps the screen-capture flag")
        check(!ScreenshotPlaces.isScreenshot(file), "file: marked as cleaned, not checked again")
        if let reread = ImageFile.decode(written) {
            let again = try? Detector.analyzeSync(reread.image, options: DetectorOptions())
            let left = (again?.findings ?? []).filter { !$0.weak && $0.kind != .face }
            check(left.isEmpty, "file: nothing readable in the replaced file (left: \(left.map(\.kind.rawValue)))")
            check(reread.image.width == chat.width && reread.dpi == 144, "file: same size and resolution")
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(written as CFData, nil)!, 0, nil) as? [CFString: Any] ?? [:]
            // ImageIO always writes pixel size and colour space; nothing else may be there.
            let exifKeys = Set((props[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]).keys)
            let allowed: Set<String> = [kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
                                        kCGImagePropertyExifColorSpace as String]
            check(exifKeys.isSubset(of: allowed) && props[kCGImagePropertyGPSDictionary] == nil,
                  "file: no metadata beyond size and resolution (EXIF: \(exifKeys.sorted()))")
        } else {
            check(false, "file: replaced file decodes")
        }
        check(session.dragFile.map { fm.fileExists(atPath: $0.path) } == true, "file: a cleaned copy is ready for dragging")

        center.undo(session)
        check((try? Data(contentsOf: file)) == originalPNG, "file: «Вернуть» puts the original bytes back")
        check(ScreenshotPlaces.isScreenshot(file), "file: after «Вернуть» it is a plain screenshot again")
        check(session.state == .review && session.dragFile == nil, "file: back to review, drag copy removed")

        // Retention: with «Не хранить» there is nothing to undo.
        center.apply(session)
        session.schedulePurge(after: 0)
        check(!session.canUndo && session.original == nil && session.originalFile(file) == nil, "retention: original dropped from memory")

        // Clipboard: what counts as a screenshot.
        var seen: [Data] = []
        let watcher = ClipboardWatcher(pasteboard: pb) { _, data in seen.append(data) }
        func put(_ types: [NSPasteboard.PasteboardType: Data]) {
            pb.clearContents()
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            pb.writeObjects([item])
        }
        put([.png: originalPNG, .tiff: Data([1, 2, 3])])
        watcher.poll()
        check(seen.count == 1, "clipboard: a bare image is checked")
        put([.png: originalPNG, NSPasteboard.PasteboardType("public.html"): Data("<img>".utf8)])
        watcher.poll()
        check(seen.count == 1, "clipboard: an image copied from a web page is skipped")
        put([.png: originalPNG, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"): Data()])
        watcher.poll()
        check(seen.count == 1, "clipboard: items marked private are skipped")
        put([.string: Data("текст".utf8)])
        watcher.poll()
        check(seen.count == 1, "clipboard: text is ignored")
        // A copied file: only a screenshot file counts, not any file with an icon.
        watcher.allowFileItems = { true }
        let plainFile = dir.appendingPathComponent("отчёт.png")
        try? originalPNG.write(to: plainFile)
        pb.clearContents()
        pb.writeObjects([plainFile as NSURL])
        pb.setData(Data([1, 2, 3]), forType: .tiff)
        watcher.poll()
        check(seen.count == 1, "clipboard: a copied ordinary file is skipped")
        let shotCopy = dir.appendingPathComponent("CleanShot 2026-11-07 at 12.00.00@2x.png")
        try? originalPNG.write(to: shotCopy)
        ImageFile.setAttributes(shotCopy, [ScreenshotPlaces.screenCaptureAttribute: flag])
        pb.clearContents()
        pb.writeObjects([shotCopy as NSURL])
        watcher.poll()
        check(seen.count == 2 && seen.last == originalPNG, "clipboard: a copied screenshot file is checked")
        watcher.allowFileItems = { false }
        seen.removeLast()

        watcher.scope = .anyImage
        put([.png: originalPNG, NSPasteboard.PasteboardType("public.html"): Data("<img>".utf8)])
        watcher.poll()
        check(seen.count == 2, "clipboard: «любые картинки» includes web images")

        // Clipboard: hide, undo, and never overwrite something the person copied since.
        put([.png: originalPNG])
        let clipSession = Session(origin: .system, loaded: loaded)
        clipSession.add(.clipboard)
        clipSession.clipboardSnapshot = ClipboardSnapshot.read(pb)
        clipSession.findings = analysis?.findings ?? []
        clipSession.state = .review
        center.apply(clipSession)
        let types = Set((pb.types ?? []).map(\.rawValue))
        check(types.contains(ClipboardWatcher.cleanedType.rawValue) && pb.data(forType: .png) != originalPNG,
              "clipboard: cleaned copy with our marker after «Скрыть»")
        let ownWatcher = center.clipboard
        var echoed = false
        ownWatcher.allowFileItems = { echoed = true; return false }
        ownWatcher.poll()
        check(!echoed, "clipboard: our own write is not checked again")
        center.undo(clipSession)
        check(pb.data(forType: .png) == originalPNG, "clipboard: «Вернуть» restores the original")

        center.apply(clipSession)
        put([.string: Data("скопировал другое".utf8)])
        center.undo(clipSession)
        check(pb.string(forType: .string) == "скопировал другое", "clipboard: «Вернуть» does not overwrite a newer copy")

        put([.string: Data("новое".utf8)])
        let late = Session(origin: .system, loaded: loaded)
        late.add(.clipboard)
        late.clipboardSnapshot = ClipboardSnapshot(items: [[.png: originalPNG]], changeCount: pb.changeCount - 1)
        late.findings = analysis?.findings ?? []
        late.state = .review
        center.apply(late)
        check(pb.string(forType: .string) == "новое" && late.note != nil, "clipboard: «Скрыть» after a newer copy leaves it alone and says so")
    }
}

// MARK: - Report

print("\(passed) passed, \(failed.count) failed")
for f in failed { print("FAIL: \(f)") }
exit(failed.isEmpty ? 0 : 1)
