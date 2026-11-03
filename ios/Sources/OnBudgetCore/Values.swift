import Foundation

public enum InputError: Error, LocalizedError, Equatable, Sendable {
    case invalidAmount, invalidDate, invalidMerchant, invalidCard, invalidEmail, weakPassword
    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter a dollar amount with up to two decimal places."
        case .invalidDate: "Enter a real date in YYYY-MM-DD format."
        case .invalidMerchant: "Enter a merchant name (up to 120 characters)."
        case .invalidCard: "Enter exactly four card digits."
        case .invalidEmail: "Enter a valid email address."
        case .weakPassword: "Use a password of at least eight characters."
        }
    }
}

/// Input/formatting only. No authoritative financial arithmetic lives in Swift.
public struct Money: Codable, Equatable, Hashable, Sendable {
    public let cents: Int64
    public init(cents: Int64) { self.cents = cents }
    public init(dollars text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^-?[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else {
            throw InputError.invalidAmount
        }
        let negative = value.hasPrefix("-")
        let unsigned = negative ? String(value.dropFirst()) : value
        let pieces = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int64(pieces[0]) else { throw InputError.invalidAmount }
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        let minor = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 100)
        let (total, additionOverflow) = scaled.addingReportingOverflow(minor)
        guard !overflow, !additionOverflow else { throw InputError.invalidAmount }
        cents = negative ? -total : total
    }
    public var formatted: String {
        let magnitude = cents.magnitude
        return "\(cents < 0 ? "−" : "")$\(magnitude / 100).\(String(format: "%02llu", magnitude % 100))"
    }
}

public struct PurchaseDate: Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw InputError.invalidDate
        }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard parts[0] >= 1900,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: date) == parts[0],
              calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2] else { throw InputError.invalidDate }
        rawValue = value
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func today(at date: Date = Date()) -> Self {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "yyyy-MM-dd"
        return try! Self(formatter.string(from: date))
    }
}

public enum Role: String, Codable, CaseIterable, Sendable { case admin, member }
public struct Session: Equatable, Sendable {
    public let role: Role
    public let displayName: String
    public init(role: Role, displayName: String) { self.role = role; self.displayName = displayName }
}
public struct Credentials: Sendable {
    public let email: String
    // Intentionally not Codable, printable, or persisted by the mock service.
    private let password: String
    public init(email: String, password: String) throws {
        guard email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { throw InputError.invalidEmail }
        guard password.count >= 8 else { throw InputError.weakPassword }
        self.email = email; self.password = password
    }
}
