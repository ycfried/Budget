import Foundation

/// Exactly the existing compute-week response. Outgoing debt is NOT computed here.
public struct WeekResponse: Codable, Equatable, Sendable {
    public let weekStart: String
    public let baseAvailableCents: Int64
    public let tempCents: Int64
    public let carriedDebtCents: Int64
    public let chargesCents: Int64
    public let availableCents: Int64
    public let weekLocked: Bool
    public let pendingRefundExcludedCents: Int64
    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start", baseAvailableCents = "base_available_cents"
        case tempCents = "temp_cents", carriedDebtCents = "carried_debt_cents"
        case chargesCents = "charges_cents", availableCents = "available_cents"
        case weekLocked = "week_locked", pendingRefundExcludedCents = "pending_refund_excluded_cents"
    }
}
public struct Dashboard: Equatable, Sendable {
    public let week: WeekResponse
    public let allowance: Money
    /// Must be supplied by an approved server response/adapter, never derived on device.
    public let outgoingDebt: Money?
    public let daysLeft: Int
    public let computedAt: Date
}
public struct Purchase: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let date: PurchaseDate
    public let merchant: String
    public let amount: Money
    public let cardSuffix: String
    public let source: String
    /// Keep unknown backend values visible rather than decoding them as 'posted'.
    public let state: String
    public let kind: String
    public let excluded: Bool
    public let needsReview: Bool
    public let provenance: String
    public let allocation: Money
    public var stateLabel: String {
        if excluded { return "Excluded" }
        switch state {
        case "provisional": return "Pending"
        case "verified": return "Posted"
        case "reversed": return "Reversed"
        default: return "Unknown (\(state))"
        }
    }
}
public struct FundSummary: Equatable, Sendable {
    public let available, pending, released, spent, adjustments, shortfall: Money
}
public struct FundRequest: Identifiable, Equatable, Sendable {
    public let id, merchant, requester, note, status: String
    public let amount, remainder: Money
}
public struct LedgerRecord: Identifiable, Equatable, Sendable {
    public let id, title, detail: String
    public let amount: Money
}
public struct HeldRefund: Identifiable, Equatable, Sendable {
    public let id, merchant, status: String
    public let amount: Money
}
public struct SavingsSummary: Equatable, Sendable {
    public let fundAvailable, earnedNotTransferred, interestAndMovements: Money
    public let actualBalance: Money?
    public let records: [LedgerRecord]
}
public struct HistoryWeek: Identifiable, Equatable, Sendable {
    public var id: String { weekStart }
    public let weekStart: String
    public let allowance, increment, debtIn, debtOut, spent, surplus: Money
    public let releaseStatus, revisionNote: String
}
public struct AuditEvent: Identifiable, Equatable, Sendable {
    public let id, actor, action, detail: String
    public let date: Date
}
public struct SourceHealth: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name, status: String
    public let lastUpdated: Date?
    public let stale: Bool
}
public struct HouseholdSnapshot: Equatable, Sendable {
    public let dashboard: Dashboard
    public let purchases: [Purchase]
    public let fund: FundSummary
    public let requests: [FundRequest]
    public let fundLedger: [LedgerRecord]
    public let heldRefunds: [HeldRefund]
    public let restorations: [LedgerRecord]
    public let savings: SavingsSummary
    public let history: [HistoryWeek]
    public let audit: [AuditEvent]
    public let sources: [SourceHealth]
}

public enum PurchaseFilter: String, CaseIterable, Sendable {
    case all = "All", pending = "Pending", posted = "Posted", refunds = "Refunds", excluded = "Excluded", review = "Review"
    public func includes(_ purchase: Purchase) -> Bool {
        switch self {
        case .all: true
        case .pending: purchase.state == "provisional" && !purchase.excluded
        case .posted: purchase.state == "verified" && !purchase.excluded
        case .refunds: purchase.kind == "refund"
        case .excluded: purchase.excluded
        case .review: purchase.needsReview
        }
    }
}
public enum PurchaseSort: String, CaseIterable, Sendable { case newest = "Newest", oldest = "Oldest", amount = "Amount" }
public struct PurchaseQuery: Sendable {
    public var search = ""
    public var filter: PurchaseFilter = .all
    public var card = "All"
    public var month = "All"
    public var weekStart = "All"
    public var kind = "All"
    public var sort: PurchaseSort = .newest
    public init() {}
    public func apply(to purchases: [Purchase]) -> [Purchase] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let week = try? PurchaseDate(weekStart)
        return purchases.filter { purchase in
            filter.includes(purchase) && (card == "All" || purchase.cardSuffix == card)
            && (month == "All" || purchase.date.rawValue.hasPrefix(month))
            && (kind == "All" || purchase.kind == kind)
            && (weekStart == "All" || week.map { purchase.date.isInWeek(startingAt: $0) } == true)
            && (needle.isEmpty || "\(purchase.merchant) \(purchase.amount.formatted) \(purchase.date.rawValue)".localizedCaseInsensitiveContains(needle))
        }.sorted {
            switch sort {
            case .newest: $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
            case .oldest: $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
            case .amount: $0.amount.cents == $1.amount.cents ? $0.id < $1.id : $0.amount.cents > $1.amount.cents
            }
        }
    }
}
public struct ManualPurchase: Equatable, Sendable {
    public let merchant: String
    public let amount: Money
    public let date: PurchaseDate
    public let cardSuffix: String
    public init(merchant: String, amount: Money, date: PurchaseDate, cardSuffix: String) throws {
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw InputError.invalidMerchant }
        guard amount.cents > 0 else { throw InputError.invalidAmount }
        guard cardSuffix.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else { throw InputError.invalidCard }
        self.merchant = name; self.amount = amount; self.date = date; self.cardSuffix = cardSuffix
    }
}
