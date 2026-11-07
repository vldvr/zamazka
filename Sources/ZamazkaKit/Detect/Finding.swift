import CoreGraphics
import Foundation

/// What a finding is. The order of cases is the order chips appear in the card.
public enum FindingKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case phone, card, account, passport, snils, inn, oms
    case address, plate, person, birthdate
    case order, track
    case email, ip, secret, password
    case code, face
    case custom, manual

    public var id: String { rawValue }

    /// Singular name for chips and settings.
    public var title: String {
        switch self {
        case .phone: return "Телефон"
        case .card: return "Карта"
        case .account: return "Счёт"
        case .passport: return "Паспорт"
        case .snils: return "СНИЛС"
        case .inn: return "ИНН"
        case .oms: return "Полис ОМС"
        case .address: return "Адрес"
        case .plate: return "Госномер"
        case .person: return "Имя"
        case .birthdate: return "Дата рождения"
        case .order: return "Номер заказа"
        case .track: return "Трек-номер"
        case .email: return "Почта"
        case .ip: return "IP-адрес"
        case .secret: return "Ключ или токен"
        case .password: return "Пароль"
        case .code: return "QR или штрихкод"
        case .face: return "Лицо"
        case .custom: return "Свои слова"
        case .manual: return "Своя область"
        }
    }

    /// Lower-case form for running text: «нашлись телефон и карта».
    public var inline: String {
        switch self {
        case .snils, .inn, .ip: return title
        case .oms: return "полис ОМС"
        default: return title.lowercased()
        }
    }

    /// An example for the settings list, made up and obviously fake.
    public var example: String {
        switch self {
        case .phone: return "+7 916 000-00-00, 8 800 …"
        case .card: return "16 цифр, проверка по алгоритму Луна"
        case .account: return "20 цифр, 40817…"
        case .passport: return "45 00 000000, код подразделения"
        case .snils: return "000-000-000 00, с контрольной суммой"
        case .inn: return "10 или 12 цифр, с контрольной суммой"
        case .oms: return "16 цифр рядом со словом «полис»"
        case .address: return "г. Москва, ул. …, д. 1, кв. 1"
        case .plate: return "А000АА 77"
        case .person: return "после «ФИО», «Получатель»"
        case .birthdate: return "после «Дата рождения»"
        case .order: return "после «Заказ №», «Order #»"
        case .track: return "RA000000000RU и после «трек»"
        case .email: return "name@example.ru"
        case .ip: return "IPv4 и IPv6"
        case .secret: return "sk-…, ghp_…, AKIA…, JWT, ключи бота"
        case .password: return "после «пароль:», «password=»"
        case .code: return "QR-коды и штрихкоды целиком"
        case .face: return "лица на фото и аватарках"
        case .custom: return "фамилия, адрес, что угодно своё"
        case .manual: return ""
        }
    }

    /// Kinds a person can switch off in settings (manual areas are always on).
    public static var detectable: [FindingKind] { allCases.filter { $0 != .manual } }
}

/// One thing to hide: a kind and one or more rectangles in image pixels (origin top-left).
public struct Finding: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: FindingKind
    public var rects: [CGRect]
    /// Weak findings (a private IP, a string that only looks random) start switched off and
    /// do not open the card on their own.
    public let weak: Bool
    public var enabled: Bool
    /// The matched text, for tests and the debug CLI. Never shown in the interface.
    let text: String?

    public init(kind: FindingKind, rects: [CGRect], weak: Bool = false, text: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.rects = rects
        self.weak = weak
        self.enabled = !weak
        self.text = text
    }

    /// Union of all rectangles.
    public var bounds: CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }
}

extension Array where Element == Finding {
    /// Distinct kinds in display order.
    public var kinds: [FindingKind] {
        let present = Set(map(\.kind))
        return FindingKind.allCases.filter { present.contains($0) }
    }

    public var enabledCount: Int { filter(\.enabled).count }

    /// True when the card is worth showing: something strong was found.
    public var hasStrong: Bool { contains { !$0.weak } }
}
