import Foundation

/// Documentation-backed request values only; no transport or endpoint configuration.
/// Approval of a staging environment is required before implementing a network adapter.
public enum BackendContracts {
    public struct ComputeWeekRequest: Encodable, Equatable, Sendable {
        public let householdID: String
        public let weekStart: String?
        public init(householdID: String, weekStart: String? = nil) { self.householdID = householdID; self.weekStart = weekStart }
        enum CodingKeys: String, CodingKey { case householdID = "household_id", weekStart = "week_start" }
    }
    public struct ApproveRequest: Encodable, Equatable, Sendable {
        public let requestID: String
        public let amountCents: Int64
        public let overrideReason: String?
        public init(requestID: String, amountCents: Int64, overrideReason: String? = nil) {
            self.requestID = requestID; self.amountCents = amountCents; self.overrideReason = overrideReason
        }
        enum CodingKeys: String, CodingKey { case requestID = "request_id", amountCents = "amount_cents", overrideReason = "override_reason" }
        public func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(requestID, forKey: .requestID)
            try box.encode(amountCents, forKey: .amountCents)
            if let overrideReason { try box.encode(overrideReason, forKey: .overrideReason) }
            else { try box.encodeNil(forKey: .overrideReason) } // Required RPC argument, even when null.
        }
    }
    public static func decodeWeek(_ data: Data) throws -> WeekResponse {
        struct Envelope: Decodable { let result: WeekResponse }
        if let wrapped = try? JSONDecoder().decode(Envelope.self, from: data) { return wrapped.result }
        return try JSONDecoder().decode(WeekResponse.self, from: data)
    }
}

/// Transport-free legacy table contract. Not a network adapter or permission to connect.
public struct TransactionRow: Codable, Equatable, Sendable {
    public let id: String
    public let date: PurchaseDate
    public let merchant: String
    public let amountCents: Int64
    public let cardSuffix: String
    public let source: String
    public let state: String
    public let kind: String
    public let excluded: Bool
    public let preExclusionState: String?
    public let originalPurchaseID: String?
    public let fundAllocationCents: Int64
    enum CodingKeys: String, CodingKey {
        case id, date, merchant, source, state, kind, excluded
        case amountCents = "amount_cents", cardSuffix = "card_suffix"
        case preExclusionState = "pre_exclusion_state", originalPurchaseID = "original_purchase_id"
        case fundAllocationCents = "fund_allocation_cents"
    }
    public func purchase() -> Purchase {
        // Legacy bank pending shares 'provisional' with email/manual provisional.
        // No date-based promotion, refund linking, or accounting takes place here.
        func mapped(_ value: String) -> TransactionState {
            value == "provisional" && source == "plaid" ? .pending : TransactionState(wireValue: value)
        }
        return Purchase(id: id, date: date, merchant: merchant, amount: Money(cents: amountCents),
            cardSuffix: cardSuffix, source: source, state: mapped(state).wireValue, kind: kind,
            excluded: excluded, provenance: "Server row; detailed source events not included.",
            allocation: Money(cents: fundAllocationCents), priorState: preExclusionState.map(mapped),
            originalPurchaseID: originalPurchaseID)
    }
}
