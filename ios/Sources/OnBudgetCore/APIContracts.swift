import Foundation

/// Absence is different from an explicit server null. No domain default is implied.
public enum APIField<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
    case missing, null, value(Value)
}
public extension KeyedDecodingContainer {
    func field<T: Codable & Equatable & Sendable>(_ type: T.Type, forKey key: Key) throws -> APIField<T> {
        guard contains(key) else { return .missing }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}
public extension KeyedEncodingContainer {
    mutating func encodeField<T>(_ field: APIField<T>, forKey key: Key) throws {
        switch field {
        case .missing: break
        case .null: try encodeNil(forKey: key)
        case .value(let value): try encode(value, forKey: key)
        }
    }
}

/// JSON structure for unrecognized response attributes (never logged).
/// Numeric representation is Int64/Decimal, not arbitrary-precision JSON text.
public enum APIValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), decimal(Decimal), string(String)
    case array([APIValue]), object([String: APIValue])
    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let v = try? box.decode(Bool.self) { self = .bool(v) }
        else if let v = try? box.decode(Int64.self) { self = .integer(v) }
        else if let v = try? box.decode(Decimal.self) { self = .decimal(v) }
        else if let v = try? box.decode(String.self) { self = .string(v) }
        else if let v = try? box.decode([APIValue].self) { self = .array(v) }
        else { self = .object(try box.decode([String: APIValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let v): try box.encode(v)
        case .integer(let v): try box.encode(v)
        case .decimal(let v): try box.encode(v)
        case .string(let v): try box.encode(v)
        case .array(let v): try box.encode(v)
        case .object(let v): try box.encode(v)
        }
    }
}

/// Proposed client envelope, not an assertion that an existing RPC supports it.
public struct OperationRequest<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let payload: Payload
    public init(operationID: UUID, payload: Payload) { self.operationID = operationID; self.payload = payload }
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", payload }
}

/// Open object retains future fields, nulls, integer cents, and unknown error/status codes.
/// Accessors deliberately return APIField rather than zero, empty, or successful defaults.
public struct APIRecord: Codable, Equatable, Sendable {
    public let fields: [String: APIValue]
    public init(fields: [String: APIValue]) { self.fields = fields }
    public init(from decoder: any Decoder) throws { fields = try decoder.singleValueContainer().decode([String: APIValue].self) }
    public func encode(to encoder: any Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(fields) }
    public func field(_ name: String) -> APIField<APIValue> {
        guard let value = fields[name] else { return .missing }
        return value == .null ? .null : .value(value)
    }
}
public enum ContractError: Error, Equatable { case ambiguousEnvelope, absentResult, operationMismatch, server(APIRecord) }
public struct OperationResponse<Result: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let operationID: APIField<UUID>
    public let result: APIField<Result>
    public let error: APIField<APIRecord>
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", result, error }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try box.field(UUID.self, forKey: .operationID)
        result = try box.field(Result.self, forKey: .result)
        error = try box.field(APIRecord.self, forKey: .error)
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encodeField(operationID, forKey: .operationID)
        try box.encodeField(result, forKey: .result)
        try box.encodeField(error, forKey: .error)
    }
    /// Writes must correlate a server acknowledgement before accepting success.
    public func requireResult(for operation: UUID) throws -> Result {
        guard operationID == .value(operation) else { throw ContractError.operationMismatch }
        return try requireResult()
    }
    public func requireResult() throws -> Result {
        if case .value(let failure) = error {
            if case .value = result { throw ContractError.ambiguousEnvelope }
            throw ContractError.server(failure)
        }
        guard case .value(let value) = result else { throw ContractError.absentResult }
        return value
    }
}

public enum RetryDisposition: Equatable, Sendable { case manualSameOperation, reconcileSameOperation, doNotRetry }
public struct OperationFailure: Equatable, Sendable {
    public let retry: RetryDisposition
    public let outcomeUnknown: Bool
    public init(_ error: any Error) {
        if error is CancellationError || (error as? ServiceError) == .responseLost {
            retry = .reconcileSameOperation; outcomeUnknown = true
        } else if let service = error as? ServiceError {
            retry = [.offline, .simulatedFailure].contains(service) ? .manualSameOperation : .doNotRetry
            outcomeUnknown = false
        } else {
            // An arbitrary transport error cannot establish whether a write committed.
            retry = .reconcileSameOperation; outcomeUnknown = true
        }
    }
}
public enum WriteState: Equatable, Sendable {
    case idle, submitting(UUID), succeeded(UUID), failed(UUID, OperationFailure)
}

/// Source freshness is supplied by the server; device age never promotes a transaction.
public enum SourceFreshness: Equatable, Sendable, Codable {
    case fresh, stale, neverSynced, disconnected, unavailable, unknown(String)
    public init(from decoder: any Decoder) throws {
        let v = try decoder.singleValueContainer().decode(String.self)
        self = switch v {
        case "fresh": .fresh
        case "stale": .stale
        case "never_synced": .neverSynced
        case "disconnected": .disconnected
        case "unavailable": .unavailable
        default: .unknown(v)
        }
    }
    public var wireValue: String {
        switch self {
        case .fresh: "fresh"
        case .stale: "stale"
        case .neverSynced: "never_synced"
        case .disconnected: "disconnected"
        case .unavailable: "unavailable"
        case .unknown(let value): value
        }
    }
    public func encode(to encoder: any Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(wireValue) }
}
public struct SourceFreshnessResponse: Codable, Equatable, Sendable {
    public let state: APIField<SourceFreshness>
    /// Raw server timestamp retained until the API timestamp/timezone contract is agreed.
    public let updatedAt: APIField<String>
    enum CodingKeys: String, CodingKey { case state, updatedAt = "updated_at" }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        state = try box.field(SourceFreshness.self, forKey: .state)
        updatedAt = try box.field(String.self, forKey: .updatedAt)
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encodeField(state, forKey: .state); try box.encodeField(updatedAt, forKey: .updatedAt)
    }
}

/// Partial wire snapshot. Unknown fields survive round-trip; missing money stays missing.
public struct WeekSnapshotResponse: Codable, Equatable, Sendable {
    public let raw: APIRecord
    public let weekStart: APIField<String>
    public let baseAvailableCents: APIField<Int64>
    public let tempCents: APIField<Int64>
    public let carriedDebtCents: APIField<Int64>
    public let chargesCents: APIField<Int64>
    public let availableCents: APIField<Int64>
    public let weekLocked: APIField<Bool>
    public let pendingRefundExcludedCents: APIField<Int64>
    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case baseAvailableCents = "base_available_cents"
        case tempCents = "temp_cents"
        case carriedDebtCents = "carried_debt_cents"
        case chargesCents = "charges_cents"
        case availableCents = "available_cents"
        case weekLocked = "week_locked"
        case pendingRefundExcludedCents = "pending_refund_excluded_cents"
    }
    public init(from decoder: any Decoder) throws {
        raw = try APIRecord(from: decoder)
        let box = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = try box.field(String.self, forKey: .weekStart)
        baseAvailableCents = try box.field(Int64.self, forKey: .baseAvailableCents)
        tempCents = try box.field(Int64.self, forKey: .tempCents)
        carriedDebtCents = try box.field(Int64.self, forKey: .carriedDebtCents)
        chargesCents = try box.field(Int64.self, forKey: .chargesCents)
        availableCents = try box.field(Int64.self, forKey: .availableCents)
        weekLocked = try box.field(Bool.self, forKey: .weekLocked)
        pendingRefundExcludedCents = try box.field(Int64.self, forKey: .pendingRefundExcludedCents)
    }
    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}
