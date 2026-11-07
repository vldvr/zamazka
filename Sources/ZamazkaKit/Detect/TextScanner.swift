import Foundation

/// A piece of one text line that should be hidden. `range` is in UTF-16 units of the line.
public struct TextMatch: Equatable, Sendable {
    public let kind: FindingKind
    public let range: NSRange
    public let weak: Bool
    public let text: String
}

/// Finds personal data in recognised text, one line at a time. Pure and synchronous, so it is
/// covered by checks without any images.
///
/// `context` is the text around the line: the line above and anything to its left on the same
/// row. Labels like «Паспорт» or «ИНН» are often there rather than in the line itself.
public struct TextScanner: Sendable {
    public var enabled: Set<FindingKind>
    public var customWords: [String]

    public init(enabled: Set<FindingKind> = Set(FindingKind.allCases), customWords: [String] = []) {
        self.enabled = enabled
        self.customWords = customWords
    }

    /// `label` is a caption that names the whole line, like «ФИО:» to the left of a form field.
    public func scan(_ line: String, context: String = "", label: String = "") -> [TextMatch] {
        let ns = line as NSString
        guard ns.length > 0 else { return [] }
        var found: [Candidate] = []
        let ctx = context + " " + line

        func add(_ kind: FindingKind, _ range: NSRange, priority: Int, weak: Bool = false) {
            guard enabled.contains(kind), range.location != NSNotFound, range.length > 0 else { return }
            let trimmed = Self.trim(range, in: ns)
            guard trimmed.length > 0 else { return }
            found.append(Candidate(kind: kind, range: trimmed, priority: priority, weak: weak))
        }

        // Known key formats first: they are unambiguous.
        for rule in Rx.secrets {
            for m in rule.matches(line) { add(.secret, m.range, priority: 100) }
        }
        for m in Rx.privateKey.matches(line) { add(.secret, m.range, priority: 100) }
        for m in Rx.connectionPassword.matches(line) { add(.password, m.range(at: 1), priority: 99) }
        for m in Rx.labeledSecret.matches(line) {
            let label = ns.substring(with: m.range(at: 1)).lowercased()
            let isPassword = label.contains("парол") || label.contains("pass") || label.contains("pwd")
            add(isPassword ? .password : .secret, m.range(at: 2), priority: 98)
        }

        // User's own words.
        for word in customWords {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard w.count >= 2 else { continue }
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard r.location != NSNotFound else { break }
                add(.custom, r, priority: 97)
                let next = r.location + r.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }

        // Money.
        let omsContext = Rx.omsContext.firstMatch(ctx) != nil
        if omsContext {
            for m in Rx.digits16.matches(line) { add(.oms, m.range, priority: 96) }
        }
        for m in Rx.cardLike.matches(line) {
            if let r = Self.bestCard(in: ns, range: m.range) { add(.card, r, priority: 95) }
        }
        let accountContext = Rx.accountContext.firstMatch(ctx) != nil
        for m in Rx.digits20.matches(line) {
            let d = Validators.digits(ns.substring(with: m.range)).map(String.init).joined()
            if d.hasPrefix("301") { continue } // correspondent account, public
            if accountContext || d.hasPrefix("408") || d.hasPrefix("423") || d.hasPrefix("40702") {
                add(.account, m.range, priority: 92)
            }
        }

        // Documents.
        let snilsContext = Rx.snilsContext.firstMatch(ctx) != nil
        for m in Rx.snilsFormatted.matches(line) where Validators.snils(ns.substring(with: m.range)) {
            add(.snils, m.range, priority: 88)
        }
        if snilsContext {
            for m in Rx.digits11.matches(line) { add(.snils, m.range, priority: 88) }
        }
        let innContext = Rx.innContext.firstMatch(ctx) != nil
        for m in Rx.innDigits.matches(line) {
            let s = ns.substring(with: m.range)
            let d = Validators.digits(s)
            if innContext || (d.count == 12 && Validators.inn(s)) {
                add(.inn, m.range, priority: 86)
            }
        }
        let passportContext = Rx.passportContext.firstMatch(ctx) != nil
        for m in Rx.passportSpaced.matches(line) { add(.passport, m.range, priority: 84) }
        if passportContext {
            for m in Rx.passportLoose.matches(line) { add(.passport, m.range, priority: 84) }
            for m in Rx.passportForeign.matches(line) { add(.passport, m.range, priority: 83) }
            for m in Rx.passportSeries.matches(line) { add(.passport, m.range(at: 1), priority: 84) }
            for m in Rx.passportNumber.matches(line) { add(.passport, m.range(at: 1), priority: 84) }
        }
        for m in Rx.divisionCode.matches(line) { add(.passport, m.range(at: 1), priority: 84) }

        // Parcels.
        for m in Rx.s10.matches(line) where Validators.s10(ns.substring(with: m.range)) {
            add(.track, m.range, priority: 80)
        }

        // Car plates, on a copy with Latin look-alikes turned into Cyrillic.
        let plates = Self.plateNormalized(line)
        for m in Rx.plate.matches(plates) { add(.plate, m.range, priority: 78) }

        // Contacts.
        for m in Rx.email.matches(line) { add(.email, m.range, priority: 76) }
        for m in Rx.phoneRU.matches(line) {
            let d = Validators.digits(ns.substring(with: m.range))
            if d.count == 11, d[0] == 7 || d[0] == 8, [3, 4, 8, 9].contains(d[1]) {
                add(.phone, m.range, priority: 74)
            }
        }
        for m in Rx.phoneIntl.matches(line) {
            let d = Validators.digits(ns.substring(with: m.range))
            if (9...15).contains(d.count) { add(.phone, m.range, priority: 73) }
        }
        for m in Rx.phoneLabeled.matches(line) {
            let d = Validators.digits(ns.substring(with: m.range(at: 1)))
            if (6...15).contains(d.count) { add(.phone, m.range(at: 1), priority: 72) }
        }

        // Orders and labelled tracking numbers.
        for m in Rx.order.matches(line) {
            let value = ns.substring(with: m.range(at: 1))
            if Validators.digits(value).count >= 2 || Rx.pnr.firstMatch(value) != nil {
                add(.order, m.range(at: 1), priority: 70)
            }
        }
        for m in Rx.trackLabeled.matches(line) {
            if Validators.digits(ns.substring(with: m.range(at: 1))).count >= 6 {
                add(.track, m.range(at: 1), priority: 68)
            }
        }
        if Rx.trackContext.firstMatch(ctx) != nil {
            for m in Rx.digits14.matches(line) { add(.track, m.range, priority: 67) }
        }

        // Network.
        for m in Rx.ipv4.matches(line) {
            let s = ns.substring(with: m.range)
            let before = ns.substring(to: m.range.location).suffix(10).lowercased()
            if before.hasSuffix("v") || before.contains("верси") || before.contains("version") { continue }
            add(.ip, m.range, priority: 66, weak: Validators.isPrivateIPv4(s))
        }
        for m in Rx.ipv6.matches(line) {
            let s = ns.substring(with: m.range).lowercased()
            guard s.filter({ $0 == ":" }).count >= 2, s.contains(where: \.isLetter) || s.contains("::") else { continue }
            let local = s.hasPrefix("fe80") || s == "::1" || s.hasPrefix("::")
            add(.ip, m.range, priority: 65, weak: local)
        }

        // People.
        for m in Rx.birthdate.matches(line) { add(.birthdate, m.range(at: 1), priority: 64) }
        for m in Rx.person.matches(line) { add(.person, m.range(at: 1), priority: 62) }

        // Addresses.
        for r in Self.addresses(in: line) { add(.address, r, priority: 60) }

        // A form field whose caption sits next to it: the whole value is the finding.
        // A line ending in a colon is itself a caption, not a value.
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, !value.hasSuffix(":") {
            let whole = NSRange(location: 0, length: ns.length)
            for rule in Rx.labels where rule.matches(label) && rule.accepts(value) {
                add(rule.kind, whole, priority: 58)
                break
            }
        }

        // Long random-looking strings: probably a key, but only a guess.
        for m in Rx.longToken.matches(line) {
            let s = ns.substring(with: m.range)
            if Self.looksRandom(s) {
                let strong = context.contains("BEGIN") && s.count >= 40
                add(.secret, m.range, priority: 20, weak: !strong)
            }
        }

        return Self.resolve(found, in: ns)
    }

    // MARK: - Helpers

    struct Candidate {
        let kind: FindingKind
        let range: NSRange
        let priority: Int
        let weak: Bool
    }

    /// Keeps the strongest of overlapping candidates.
    static func resolve(_ candidates: [Candidate], in ns: NSString) -> [TextMatch] {
        let sorted = candidates.sorted {
            if $0.weak != $1.weak { return !$0.weak }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.range.length > $1.range.length
        }
        var kept: [Candidate] = []
        for c in sorted where !kept.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) {
            kept.append(c)
        }
        return kept
            .sorted { $0.range.location < $1.range.location }
            .map { TextMatch(kind: $0.kind, range: $0.range, weak: $0.weak, text: ns.substring(with: $0.range)) }
    }

    /// Drops spaces and trailing punctuation at the ends of a range.
    static func trim(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location, end = range.location + range.length
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:»«\"'()"))
        func isJunk(_ i: Int) -> Bool {
            guard let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            return junk.contains(scalar)
        }
        while start < end, isJunk(start) { start += 1 }
        while end > start, isJunk(end - 1) {
            // Keep a closing bracket if the range has the opening one: «(916)».
            if ns.character(at: end - 1) == 0x29, ns.substring(with: NSRange(location: start, length: end - start)).contains("(") { break }
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// The digit run may have neighbours glued on by OCR (a message time «18:07» after the
    /// number). Tries every run of whole digit groups and keeps a valid card, 16 digits first.
    static func bestCard(in ns: NSString, range: NSRange) -> NSRange? {
        var groups: [NSRange] = []
        var start: Int?
        for i in range.location..<(range.location + range.length) {
            let isDigit = (0x30...0x39).contains(ns.character(at: i))
            if isDigit, start == nil { start = i }
            if !isDigit, let s = start { groups.append(NSRange(location: s, length: i - s)); start = nil }
        }
        if let s = start { groups.append(NSRange(location: s, length: range.location + range.length - s)) }
        var best: NSRange?
        var bestScore = -1
        for i in groups.indices {
            for j in i..<groups.count {
                let r = NSRange(location: groups[i].location, length: groups[j].location + groups[j].length - groups[i].location)
                let s = ns.substring(with: r)
                guard looksLikeCard(s) else { continue }
                let n = Validators.digits(s).count
                let score = (n == 16 ? 100 : 0) + n
                if score > bestScore { bestScore = score; best = r }
            }
        }
        return best
    }

    static func looksLikeCard(_ s: String) -> Bool {
        let d = Validators.digits(s)
        guard (13...19).contains(d.count), (2...6).contains(d[0]), Set(d).count > 2 else { return false }
        let groups = s.split(whereSeparator: { !$0.isNumber }).map(\.count)
        if groups.count == 1 {
            guard d.count == 16 || d.count == 15 else { return false }
        } else {
            let fours = groups.dropLast().allSatisfy { $0 == 4 }
            let amex = groups == [4, 6, 5] || groups == [4, 6, 4]
            guard fours || amex else { return false }
        }
        return Validators.luhn(s)
    }

    static func looksRandom(_ s: String) -> Bool {
        guard s.count >= 28 else { return false }
        let hasLower = s.contains(where: \.isLowercase)
        let hasUpper = s.contains(where: \.isUppercase)
        let hasDigit = s.contains(where: \.isNumber)
        let classes = [hasLower, hasUpper, hasDigit].filter { $0 }.count
        guard classes >= 3 || (classes == 2 && hasDigit && s.count >= 40) else { return false }
        // Words glued together (CamelCaseIdentifiers) have long letter runs and low digit share.
        return Validators.entropy(s) >= 4.0
    }

    /// Latin look-alikes to Cyrillic capitals, lower case to upper, one UTF-16 unit for one.
    static func plateNormalized(_ s: String) -> String {
        let map: [Character: Character] = [
            "A": "А", "B": "В", "E": "Е", "K": "К", "M": "М", "H": "Н", "O": "О", "P": "Р",
            "C": "С", "T": "Т", "Y": "У", "X": "Х",
            "a": "А", "b": "В", "e": "Е", "k": "К", "m": "М", "h": "Н", "o": "О", "p": "Р", "c": "С",
            "t": "Т", "y": "У", "x": "Х",
            "а": "А", "в": "В", "е": "Е", "к": "К", "м": "М", "н": "Н", "о": "О", "р": "Р",
            "с": "С", "т": "Т", "у": "У", "х": "Х",
        ]
        return String(s.map { map[$0] ?? $0 })
    }

    /// Address ranges: labelled («Адрес: …»), found by the system data detector, or built
    /// around a street word («ул.», «проспект») with a house number.
    static func addresses(in line: String) -> [NSRange] {
        // Vision reads «г.» as Latin «r.»; fix it for detection only (same length).
        let fixed = Rx.latinR.stringByReplacing(line, with: "$1г.")
        let ns = fixed as NSString
        var out: [NSRange] = []
        func extend(_ r: NSRange) -> NSRange {
            var end = r.location + r.length
            while end < ns.length {
                let rest = NSRange(location: end, length: ns.length - end)
                guard let t = Rx.addressTail.firstMatch(in: fixed, range: rest), t.range.location == end else { break }
                end = t.range.location + t.range.length
            }
            return NSRange(location: r.location, length: end - r.location)
        }
        for m in Rx.addressLabeled.matches(fixed) {
            let value = ns.substring(with: m.range(at: 1))
            if value.contains(where: \.isNumber) || Rx.streetWord.firstMatch(value) != nil {
                out.append(m.range(at: 1))
            }
        }
        if let detector = Rx.addressDetector {
            for m in detector.matches(in: fixed, range: NSRange(location: 0, length: ns.length)) {
                out.append(extend(m.range))
            }
        }
        for m in Rx.street.matches(fixed) { out.append(extend(m.range)) }
        for m in Rx.streetAfter.matches(fixed) { out.append(extend(m.range)) }
        return out
    }
}

// MARK: - Patterns

private extension NSRegularExpression {
    func matches(_ s: String) -> [NSTextCheckingResult] {
        matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }
    func firstMatch(_ s: String) -> NSTextCheckingResult? {
        firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }
    func stringByReplacing(_ s: String, with template: String) -> String {
        stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

enum Rx {
    static func make(_ p: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a typo is a programming error caught by the checks.
        try! NSRegularExpression(pattern: p, options: options)
    }

    static let sep = #"[\s\u00A0\-]"#

    static let secrets: [NSRegularExpression] = [
        #"\bsk-(?:ant-|proj-|live-|svcacct-)?[A-Za-z0-9_\-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,
        #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\bya29\.[0-9A-Za-z_\-]{20,}"#,
        #"\by0_[A-Za-z0-9_\-]{30,}"#,
        #"\b(?:sk|rk)_(?:live|test)_[0-9a-zA-Z]{20,}"#,
        #"\bwhsec_[0-9a-zA-Z]{20,}"#,
        #"\bnpm_[A-Za-z0-9]{30,}"#,
        #"\bhf_[A-Za-z0-9]{30,}"#,
        #"\bpypi-[A-Za-z0-9_\-]{40,}"#,
        #"\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
    ].map { make($0) }

    static let privateKey = make(#"-----BEGIN[A-Z ]*PRIVATE KEY-----"#)
    static let connectionPassword = make(#"\b[a-z][a-z0-9+.\-]*://[^\s:/@]+:([^\s@/]+)@"#, [.caseInsensitive])
    static let labeledSecret = make(
        #"(api[_\-\s]?key|apikey|access[_\-\s]?key|secret[_\-\s]?key|client[_\-\s]?secret|auth[_\-\s]?token|access[_\-\s]?token|token|токен|secret|секрет|password|passwd|pwd|пароль|ключ(?:\s+api)?|bearer)\s*(?:[:=]|:=|=>)\s*["'`]?([^\s"'`,;]{4,})"#,
        [.caseInsensitive])

    static let omsContext = make(#"(?<!\p{L})(?:ОМС|полис\p{L}*|OMS)(?!\p{L})"#, [.caseInsensitive])
    static let digits16 = make(#"(?<!\d)(?:\d[\s\u00A0]?){15}\d(?!\d)"#)
    static let cardLike = make(#"(?<!\d)(?:\d[\s\u00A0\-]?){12,18}\d(?!\d)"#)
    static let accountContext = make(#"(?:р/с|р\.\s?с\.|расч[её]тн\p{L}*|л/с|сч[её]т\p{L}*|account|IBAN)"#, [.caseInsensitive])
    static let digits20 = make(#"(?<!\d)(?:\d[\s\u00A0]?){19}\d(?!\d)"#)

    static let snilsContext = make(#"СНИЛС|SNILS"#, [.caseInsensitive])
    static let snilsFormatted = make(#"(?<!\d)\d{3}[\-\s\u00A0]\d{3}[\-\s\u00A0]\d{3}[\-\s\u00A0]{1,2}\d{2}(?!\d)"#)
    static let digits11 = make(#"(?<!\d)\d{3}[\-\s\u00A0]?\d{3}[\-\s\u00A0]?\d{3}[\-\s\u00A0]{0,2}\d{2}(?!\d)"#)
    static let innContext = make(#"(?<!\p{L})(?:ИНН|INN)(?!\p{L})"#, [.caseInsensitive])
    static let innDigits = make(#"(?<!\d)(?:\d{12}|\d{10})(?!\d)"#)

    static let passportContext = make(#"паспорт|passport|серия|удостоверени|выдан|загран"#, [.caseInsensitive])
    static let passportSpaced = make(#"(?<!\d)\d{2}[ \u00A0]\d{2}[ \u00A0]\d{6}(?!\d)"#)
    static let passportLoose = make(#"(?<!\d)\d{2}[\s\u00A0]?\d{2}[\s\u00A0№N]{0,3}\d{6}(?!\d)"#)
    static let passportForeign = make(#"(?<!\d)\d{2}[\s\u00A0]?\d{7}(?!\d)"#)
    static let passportSeries = make(#"серия\s*[:\-]?\s*(\d{2}[\s\u00A0]?\d{2})(?!\d)"#, [.caseInsensitive])
    static let passportNumber = make(#"(?:номер|№|N[º°o]?)\s*[:\-]?\s*(\d{6,7})(?!\d)"#, [.caseInsensitive])
    static let divisionCode = make(#"код\s+подразделения\s*[:\-]?\s*(\d{3}[\-\s\u00A0]?\d{3})(?!\d)"#, [.caseInsensitive])

    static let s10 = make(#"(?<![A-Z0-9])[A-Z]{2}\d{9}[A-Z]{2}(?![A-Z0-9])"#)
    static let plate = make(#"(?<![А-Я0-9A-Z])[АВЕКМНОРСТУХ][\s\u00A0]?\d{3}[\s\u00A0]?[АВЕКМНОРСТУХ]{2}[\s\u00A0|]{0,2}\d{2,3}(?:[\s\u00A0]?RUS)?(?![А-Я0-9A-Z])"#)

    static let email = make(#"(?<![\p{L}0-9._%+\-])[\p{L}0-9._%+\-]+@[\p{L}0-9\-]+(?:\.[\p{L}0-9\-]+)*\.\p{L}{2,}"#)
    static let phoneRU = make(#"(?<![\d+])(?:\+[\s\u00A0]?7|8|7(?=[\s\u00A0]?\(?[\s\u00A0]?9))[\s\u00A0\-]*\(?[\s\u00A0]*\d{3}[\s\u00A0]*\)?[\s\u00A0\-]*\d{3}[\s\u00A0\-]*\d{2}[\s\u00A0\-]*\d{2}(?!\d)"#)
    static let phoneIntl = make(#"(?<![\d+])\+(?![\s\u00A0]?7)[\s\u00A0]?\d{1,3}[\s\u00A0\-]?\(?\d{1,4}\)?(?:[\s\u00A0\-]?\d{2,4}){2,4}(?!\d)"#)
    static let phoneLabeled = make(#"(?:тел\.?|телефон\p{L}*|phone|моб\.?|мобильн\p{L}*|whatsapp|вотсап|контакт\p{L}*)\s*[:\-]?\s*([+\d(][\d\s\-()\u00A0]{5,}\d)"#, [.caseInsensitive])

    static let order = make(#"(?:заказ\p{L}*|order|брон\p{L}*|код\s+брони|PNR|номер\s+билета|бил[её]т)\s*(?:№|N[º°o]?\.?|#|No\.?|номер)?\s*[:\-]?\s*([A-ZА-Я0-9][A-ZА-Я0-9\-]{3,})"#, [.caseInsensitive])
    static let pnr = make(#"^[A-Z0-9]{6}$"#)
    static let trackLabeled = make(#"(?:трек[\s\-]?номер\p{L}*|трек|tracking(?:\s+number)?|номер\s+отслеживания|ШПИ|отправлени\p{L}*|посылк\p{L}*)\s*(?:№|#|N[º°o]?)?\s*[:\-]?\s*([A-Z0-9][A-Z0-9\-]{7,30})"#, [.caseInsensitive])
    static let trackContext = make(#"трек|отслеж|почт|track|ШПИ|СДЭК|CDEK"#, [.caseInsensitive])
    static let digits14 = make(#"(?<!\d)\d{14}(?!\d)"#)

    static let ipv4 = make(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?::\d{1,5})?(?![\d.])"#)
    static let ipv6 = make(#"(?<![0-9A-Fa-f:])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?|::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}))(?![0-9A-Fa-f:])"#)

    static let birthdate = make(#"(?i:дата\s+рождения|д\.\s?р\.|родил(?:ся|ась)|date\s+of\s+birth|DOB|birth\s?date)\s*[:\-]?\s*(\d{1,2}[.\-/]\d{1,2}[.\-/]\d{2,4}|\d{1,2}\s+\p{L}+\s+\d{4})"#)
    static let person = make(#"(?i:ФИО|Ф\.\s?И\.\s?О\.|получатель|отправитель|владелец(?:\s+карты)?|держатель(?:\s+карты)?|плательщик|пассажир|покупатель|full\s+name|cardholder)\s*[:\-]?\s*(\p{Lu}[\p{Ll}\-]+(?:[\s\u00A0]+\p{Lu}[\p{Ll}\-]*\.?){1,2}|\p{Lu}{2,}(?:[\s\u00A0]+\p{Lu}{2,}){1,2})"#)

    static let latinR = make(#"(^|[\s,(])r\.(?=\s?\p{Lu})"#)
    static let addressLabeled = make(#"(?:адрес(?:\s+(?:доставки|регистрации|проживания|получателя|пункта\s+выдачи))?|address|куда|место\s+жительства|по\s+адресу|прописк\p{L}*)\s*[:\-–]\s*(\S.{4,})$"#, [.caseInsensitive])
    static let streetWord = make(#"(?<!\p{L})(?:ул\.|улица|пр-т|пр-кт|просп\.|проспект|пер\.|переулок|ш\.|шоссе|б-р|бульвар|наб\.|набережная|пл\.|площадь|мкр\.?|микрорайон|проезд|тупик|аллея|тракт|д\.|дом|кв\.)"#, [.caseInsensitive])
    // Street word first: «ул. Баумана 15», «г. Москва, ул. Тверская, д. 7», «Казань, ул. Баумана 15».
    static let street = make(#"(?<!\p{L})(?:\d{6},[\s\u00A0]*)?(?:(?:(?i:г\.|город|пос\.|пгт|с\.|дер\.)[\s\u00A0]*)?\p{Lu}[\p{L}\-]+,[\s\u00A0]*|(?i:г\.|город|пос\.|пгт|с\.|дер\.)[\s\u00A0]*\p{Lu}[\p{L}\-]+[\s\u00A0]+)?(?i:ул\.|улица|пр-т|пр-кт|просп\.|проспект|пер\.|переулок|ш\.|шоссе|б-р|бульвар|наб\.|набережная|пл\.|площадь|мкр\.|микрорайон|проезд|тупик|аллея|тракт)[\s\u00A0]*\p{L}[\p{L}0-9\-. \u00A0]{1,40}?,?[\s\u00A0]*(?:(?i:д\.|дом)[\s\u00A0]*)?\d+\p{L}?(?:/\d+)?(?!\d)"#)
    // Name first: «Невский проспект 28», «125009, Москва, Тверская улица, 7».
    static let streetAfter = make(#"(?<!\p{L})(?:\d{6},[\s\u00A0]*)?(?:(?:(?i:г\.|город)[\s\u00A0]*)?\p{Lu}[\p{L}\-]+,[\s\u00A0]*)?\p{Lu}[\p{L}\-]+(?:[\s\u00A0]+\p{L}[\p{L}\-]+)?[\s\u00A0]+(?i:улица|ул\.|проспект|пр-т|просп\.|переулок|пер\.|шоссе|ш\.|бульвар|б-р|набережная|наб\.|площадь|пл\.|проезд|тупик|аллея|тракт)\.?,?[\s\u00A0]*(?:(?i:д\.|дом)[\s\u00A0]*)?\d+\p{L}?(?:/\d+)?(?!\d)"#)
    static let addressTail = make(#",?[\s\u00A0]*(?:кв\.?|квартира|корп\.?|к\.|стр\.?|строение|подъезд|под\.|этаж|эт\.|офис|оф\.|д\.|дом)[\s\u00A0]*\d+[\p{L}]?"#, [.caseInsensitive])
    /// The system address detector knows Russian addresses on recent macOS only (not on 15).
    /// ZAMAZKA_NO_DATADETECTOR=1 turns it off to check the own rules alone.
    static let addressDetector: NSDataDetector? = ProcessInfo.processInfo.environment["ZAMAZKA_NO_DATADETECTOR"] == nil
        ? try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) : nil

    struct LabelRule {
        let kind: FindingKind
        let pattern: NSRegularExpression
        /// Whole captions to compare fuzzily, for OCR that misreads small text
        /// («Лата рожления» for «Дата рождения», «llочта» for «Почта»).
        let keywords: [String]
        let accepts: (String) -> Bool

        func matches(_ caption: String) -> Bool {
            if pattern.firstMatch(caption) != nil { return true }
            let cyr = Rx.captionKey(caption, cyrillic: true), lat = Rx.captionKey(caption, cyrillic: false)
            guard !cyr.isEmpty, cyr.count <= 32 else { return false }
            return keywords.contains { kw in
                let allowed = kw.count >= 8 ? 2 : (kw.count >= 5 ? 1 : 0)
                let key = kw.unicodeScalars.contains { (0x400...0x4FF).contains(Int($0.value)) } ? cyr : lat
                return allowed > 0 && Validators.editDistance(key, kw) <= allowed
            }
        }
    }

    /// A caption reduced to lower-case letters and single spaces. With `cyrillic`, Latin
    /// look-alikes become Cyrillic and «ll» becomes «п», the usual OCR confusions.
    static func captionKey(_ s: String, cyrillic: Bool) -> String {
        var t = s.lowercased()
        if cyrillic {
            t = t.replacingOccurrences(of: "ll", with: "п").replacingOccurrences(of: "ii", with: "п")
            let map: [Character: Character] = ["a": "а", "e": "е", "o": "о", "p": "р", "c": "с", "x": "х", "y": "у",
                                               "k": "к", "m": "м", "t": "т", "h": "н", "n": "п", "u": "и", "r": "г"]
            t = String(t.map { map[$0] ?? $0 })
        }
        let letters = t.map { $0.isLetter ? $0 : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// Captions that name a whole field. Anchored at the end: «ФИО:», «Адрес доставки».
    static let labels: [LabelRule] = {
        func rule(_ kind: FindingKind, _ words: String, _ keywords: [String] = [], _ accepts: @escaping (String) -> Bool) -> LabelRule {
            LabelRule(kind: kind, pattern: make("(?:^|[\\s(])(?:" + words + ")\\s*[:\\-–]?\\s*$", [.caseInsensitive]),
                      keywords: keywords, accepts: accepts)
        }
        let digits = { (s: String, n: ClosedRange<Int>) in n.contains(Validators.digits(s).count) }
        return [
            rule(.person, #"ФИО|Ф\.\s?И\.\s?О\.?|получатель|отправитель|владелец(?:\s+карты)?|держатель(?:\s+карты)?|плательщик|пассажир|покупатель|имя(?:\s+и\s+фамилия)?|фамилия(?:\s+имя(?:\s+отчество)?)?|full\s+name|name|cardholder"#,
                 ["получатель", "отправитель", "владелец карты", "держатель карты", "плательщик", "пассажир", "покупатель", "фамилия", "имя и фамилия", "фамилия имя отчество"]) { v in
                let words = v.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
                return (2...4).contains(words.count) && v.count <= 60 && !v.contains(where: \.isNumber) && !v.contains(":")
                    && words.allSatisfy { $0.first?.isUppercase == true }
            },
            rule(.birthdate, #"дата\s+рождения|д\.\s?р\.|date\s+of\s+birth|DOB|birth\s?date"#, ["дата рождения", "date of birth"]) { v in digits(v, 4...8) },
            rule(.address, #"адрес(?:\s+\p{L}+){0,3}|address|куда|место\s+жительства|прописка|регистрация"#,
                 ["адрес", "адрес доставки", "адрес регистрации", "адрес проживания", "адрес получателя", "место жительства", "прописка"]) { v in
                v.count >= 5 && (v.contains(where: \.isNumber) || v.contains(","))
            },
            rule(.phone, #"тел\.?|телефон|phone|мобильный|моб\.?|номер\s+телефона"#, ["телефон", "мобильный", "номер телефона"]) { v in digits(v, 6...15) },
            // OCR sometimes breaks an address with a space or reads «@» oddly; the caption still says what it is.
            rule(.email, #"почта|e-?mail|эл\.\s?почта|электронная\s+почта"#, ["почта", "эл почта", "электронная почта", "e mail", "email"]) { v in
                v.count <= 80 && (v.contains("@") || v.range(of: #"^\S+\.\p{L}{2,}$"#, options: .regularExpression) != nil)
            },
            rule(.passport, #"паспорт|серия\s+и\s+номер|passport(?:\s+no\.?)?"#, ["паспорт", "серия и номер", "passport"]) { v in digits(v, 6...12) },
            rule(.order, #"номер\s+заказа|заказ|order(?:\s+(?:number|no\.?|id))?"#, ["номер заказа"]) { v in digits(v, 2...30) && v.count <= 30 },
            rule(.track, #"трек[\s\-]?номер|трек|номер\s+отслеживания|tracking(?:\s+number)?|ШПИ"#, ["трек номер", "номер отслеживания"]) { v in digits(v, 6...30) },
            rule(.password, #"пароль|password|pass|pwd"#, ["пароль", "password"]) { v in (4...64).contains(v.count) },
            rule(.secret, #"api[\s_\-]?key|token|токен|секрет|secret|ключ(?:\s+api)?"#) { v in v.count >= 8 },
        ]
    }()

    static let longToken = make(#"(?<![A-Za-z0-9_\-+/=])[A-Za-z0-9_\-+/=]{28,}(?![A-Za-z0-9_\-+/=])"#)
}
