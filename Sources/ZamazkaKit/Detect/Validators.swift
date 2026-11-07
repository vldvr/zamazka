import Foundation

/// Check digits for Russian and international identifiers. All functions take a string of digits
/// (anything else is ignored) and return false for the wrong length.
public enum Validators {
    public static func digits(_ s: some StringProtocol) -> [Int] {
        s.compactMap { $0.wholeNumberValue }.filter { (0...9).contains($0) }
    }

    /// Bank cards (Luhn, mod 10).
    public static func luhn(_ s: some StringProtocol) -> Bool {
        let d = digits(s)
        guard d.count >= 12 else { return false }
        var sum = 0
        for (i, digit) in d.reversed().enumerated() {
            if i % 2 == 1 {
                let x = digit * 2
                sum += x > 9 ? x - 9 : x
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Appends the Luhn digit to a partial number. Used to make synthetic test data.
    public static func luhnComplete(_ partial: String) -> String {
        for c in 0...9 where luhn(partial + String(c)) { return partial + String(c) }
        return partial + "0"
    }

    /// СНИЛС: 9 digits plus a 2-digit checksum. Numbers up to 001-001-998 have no checksum.
    public static func snils(_ s: some StringProtocol) -> Bool {
        let d = digits(s)
        guard d.count == 11 else { return false }
        let number = d[0..<9].reduce(0) { $0 * 10 + $1 }
        if number <= 1_001_998 { return false }
        let control = d[9] * 10 + d[10]
        return snilsControl(Array(d[0..<9])) == control
    }

    static func snilsControl(_ d: [Int]) -> Int {
        let sum = d.enumerated().reduce(0) { $0 + $1.element * (9 - $1.offset) }
        if sum < 100 { return sum }
        if sum == 100 || sum == 101 { return 0 }
        let r = sum % 101
        return r == 100 ? 0 : r
    }

    /// ИНН: 10 digits (company) or 12 digits (person).
    public static func inn(_ s: some StringProtocol) -> Bool {
        let d = digits(s)
        func check(_ weights: [Int], _ upTo: Int) -> Int {
            let sum = zip(weights, d[0..<upTo]).reduce(0) { $0 + $1.0 * $1.1 }
            return sum % 11 % 10
        }
        switch d.count {
        case 10:
            return check([2, 4, 10, 3, 5, 9, 4, 6, 8], 9) == d[9]
        case 12:
            return check([7, 2, 4, 10, 3, 5, 9, 4, 6, 8], 10) == d[10]
                && check([3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8], 11) == d[11]
        default:
            return false
        }
    }

    /// Appends both check digits to the first 10 digits of a personal ИНН. For synthetic data.
    public static func innComplete(_ first10: String) -> String {
        let d = digits(first10)
        guard d.count == 10 else { return first10 }
        let w11 = [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
        let n11 = zip(w11, d).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
        let w12 = [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
        let n12 = zip(w12, d + [n11]).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
        return first10 + "\(n11)\(n12)"
    }

    /// UPU S10 tracking numbers (RA123456785RU): 8 serial digits and a check digit.
    public static func s10(_ code: some StringProtocol) -> Bool {
        let chars = Array(code.uppercased())
        guard chars.count == 13,
              chars[0...1].allSatisfy({ $0.isASCII && $0.isLetter }),
              chars[11...12].allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let d = chars[2...10].compactMap(\.wholeNumberValue)
        guard d.count == 9 else { return false }
        let weights = [8, 6, 4, 2, 3, 5, 9, 7]
        let sum = zip(weights, d[0..<8]).reduce(0) { $0 + $1.0 * $1.1 }
        var c = 11 - sum % 11
        if c == 10 { c = 0 }
        if c == 11 { c = 5 }
        return c == d[8]
    }

    /// Private, loopback and link-local IPv4 ranges. Less sensitive than public addresses.
    public static func isPrivateIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ":").first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (255, _): return true
        case (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Bits of entropy per character. Random keys score above ~3.5, words and hashes of words lower.
    public static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, k in
            let p = Double(k) / n
            return acc - p * log2(p)
        }
    }
}
