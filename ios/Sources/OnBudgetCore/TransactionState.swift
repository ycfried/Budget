import Foundation

/// Presentation/workflow states, never an accounting eligibility calculation.
public enum TransactionState: Hashable, Sendable, Codable {
    case provisional, pending, posted, review, excluded, reversed, voided, quarantined
    case unknown(String)
    public init(wireValue: String) {
        switch wireValue {
        case "provisional": self = .provisional
        case "pending": self = .pending
        case "verified", "posted": self = .posted
        case "needs_review", "review": self = .review
        case "excluded": self = .excluded
        case "reversed": self = .reversed
        case "voided": self = .voided
        case "quarantined": self = .quarantined
        default: self = .unknown(wireValue)
        }
    }
    public var wireValue: String {
        switch self {
        case .provisional: "provisional"
        case .pending: "pending"
        case .posted: "posted"
        case .review: "needs_review"
        case .excluded: "excluded"
        case .reversed: "reversed"
        case .voided: "voided"
        case .quarantined: "quarantined"
        case .unknown(let value): value
        }
    }
    public var label: String {
        switch self {
        case .provisional: "Provisional"
        case .pending: "Pending"
        case .posted: "Posted"
        case .review: "Needs review"
        case .excluded: "Excluded"
        case .reversed: "Reversed"
        case .voided: "Voided"
        case .quarantined: "Quarantined"
        case .unknown(let value): "Unknown (\(value))"
        }
    }
    public var isTerminal: Bool { self == .reversed || self == .voided }
    public init(from decoder: any Decoder) throws { self.init(wireValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(wireValue) }
}
public struct TransactionEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let actor: String
    public let action: String
    public let from: TransactionState
    public let to: TransactionState
    public let note: String
    public let date: Date
}
public enum TransactionKind: Hashable, Sendable, Codable {
    case charge, refund, fundCharge, payment, cashback, unknown(String)
    public init(wireValue: String) {
        switch wireValue {
        case "charge": self = .charge
        case "refund": self = .refund
        case "fund_charge": self = .fundCharge
        case "payment": self = .payment
        case "cashback": self = .cashback
        default: self = .unknown(wireValue)
        }
    }
    public var wireValue: String {
        switch self {
        case .charge: "charge"
        case .refund: "refund"
        case .fundCharge: "fund_charge"
        case .payment: "payment"
        case .cashback: "cashback"
        case .unknown(let value): value
        }
    }
    public init(from decoder: any Decoder) throws { self.init(wireValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(wireValue) }
}
