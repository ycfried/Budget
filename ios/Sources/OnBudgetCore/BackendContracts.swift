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
    }
    public static func decodeWeek(_ data: Data) throws -> WeekResponse {
        struct Envelope: Decodable { let result: WeekResponse }
        if let wrapped = try? JSONDecoder().decode(Envelope.self, from: data) { return wrapped.result }
        return try JSONDecoder().decode(WeekResponse.self, from: data)
    }
}
