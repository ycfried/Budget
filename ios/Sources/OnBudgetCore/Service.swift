import Foundation

public enum ServiceError: Error, LocalizedError, Equatable, Sendable {
    case signedOut, forbidden, offline, simulatedFailure, unavailable, invalidRequest, alreadySubmitted
    public var errorDescription: String? {
        switch self {
        case .signedOut: "Open a sample household first."
        case .forbidden: "Only the household admin can perform this action."
        case .offline: "You're offline. Last-known sample data is read-only."
        case .simulatedFailure: "The sample service could not refresh. Try again."
        case .unavailable: "This integration is not connected. Staging approval is required."
        case .invalidRequest: "Check the amount and required fields."
        case .alreadySubmitted: "This sample request has already been decided."
        }
    }
}
public enum SampleScenario: String, CaseIterable, Sendable {
    case normal = "Normal", overspent = "Overspent", offline = "Offline", failure = "Read error"
}
public enum TransactionChange: String, CaseIterable, Sendable {
    case exclude = "Exclude", restore = "Restore", delete = "Delete manual purchase", reclassify = "Reclassify"
}
public enum SavingsKind: String, CaseIterable, Sendable {
    case transferIn = "transfer_in", withdrawal, interest, adjustment
}
public enum HouseholdAction: Sendable {
    case manual(ManualPurchase)
    case csv([CSVRow])
    case request(transactionID: String?, amount: Money, note: String)
    case approve(requestID: String, amount: Money, overrideReason: String)
    case decline(requestID: String)
    case allocate(amount: Money, note: String, overrideReason: String)
    case transaction(id: String, change: TransactionChange, value: String, reason: String)
    case flag(id: String, note: String)
    case allowance(Money)
    case temporaryIncrease(Money, note: String)
    case savings(SavingsKind, Money, note: String)
    case attest(Money, note: String)
    case resolveHeld(id: String)
    case bankSync
    public var adminOnly: Bool {
        switch self {
        case .manual, .request, .flag: false
        default: true
        }
    }
    public var label: String {
        switch self {
        case .manual: "Manual purchase"
        case .csv: "CSV import"
        case .request: "Fund request"
        case .approve: "Fund approval"
        case .decline: "Fund decline"
        case .allocate: "Fund allocation"
        case .transaction(_, let change, _, _): change.rawValue
        case .flag: "Review flag"
        case .allowance: "Allowance change"
        case .temporaryIncrease: "Temporary increase"
        case .savings: "Savings movement attestation"
        case .attest: "Savings balance attestation"
        case .resolveHeld: "Held refund release"
        case .bankSync: "Bank sync"
        }
    }
}
public struct ActionReceipt: Equatable, Sendable {
    public let message: String
}
public protocol HouseholdService: Sendable {
    func openSample(role: Role) async -> Session
    func snapshot() async throws -> HouseholdSnapshot
    func submit(_ action: HouseholdAction, idempotencyKey: UUID) async throws -> ActionReceipt
    func setScenario(_ scenario: SampleScenario) async
    func signOut() async
}
/// No URLSession, URLs, environment credentials, or backend SDK. Cannot reach production.
/// Financial summaries remain literal fixtures, even after sample action receipts.
public actor MockHouseholdService: HouseholdService {
    private var session: Session?
    private var scenario: SampleScenario = .normal
    private var receipts: [UUID: ActionReceipt] = [:]
    private var decidedRequests: Set<String> = []
    private var events: [AuditEvent] = []
    public init() {}
    public func openSample(role: Role) -> Session {
        let value = Session(role: role, displayName: role == .admin ? "Sample admin" : "Sample member")
        session = value
        return value
    }
    public func setScenario(_ value: SampleScenario) { scenario = value }
    public func snapshot() throws -> HouseholdSnapshot {
        guard session != nil else { throw ServiceError.signedOut }
        if scenario == .offline { throw ServiceError.offline }
        if scenario == .failure { throw ServiceError.simulatedFailure }
        let base = Fixtures.snapshot(overspent: scenario == .overspent)
        return HouseholdSnapshot(dashboard: base.dashboard, purchases: base.purchases, fund: base.fund,
            requests: base.requests, fundLedger: base.fundLedger, heldRefunds: base.heldRefunds,
            restorations: base.restorations, savings: base.savings, history: base.history,
            audit: events + base.audit, sources: base.sources)
    }
    public func submit(_ action: HouseholdAction, idempotencyKey: UUID) throws -> ActionReceipt {
        guard let session else { throw ServiceError.signedOut }
        guard !action.adminOnly || session.role == .admin else { throw ServiceError.forbidden }
        guard scenario != .offline else { throw ServiceError.offline }
        guard scenario != .failure else { throw ServiceError.simulatedFailure }
        if let receipt = receipts[idempotencyKey] { return receipt }
        try validate(action)
        let receipt = ActionReceipt(message: "Sample action recorded. Financial fixtures stay fixed; no account was changed.")
        receipts[idempotencyKey] = receipt
        events.insert(AuditEvent(id: idempotencyKey.uuidString, actor: session.displayName,
            action: action.label, detail: receipt.message, date: Date()), at: 0)
        return receipt
    }
    private func validate(_ action: HouseholdAction) throws {
        switch action {
        case .request(_, let amount, _), .allocate(let amount, _, _), .temporaryIncrease(let amount, _):
            guard amount.cents > 0 else { throw ServiceError.invalidRequest }
        case .approve(let id, let amount, _):
            guard let request = Fixtures.snapshot().requests.first(where: { $0.id == id }),
                  request.status == "pending", amount.cents > 0, amount.cents <= request.amount.cents else { throw ServiceError.invalidRequest }
            guard decidedRequests.insert(id).inserted else { throw ServiceError.alreadySubmitted }
        case .decline(let id):
            guard Fixtures.snapshot().requests.contains(where: { $0.id == id && $0.status == "pending" }) else { throw ServiceError.invalidRequest }
            guard decidedRequests.insert(id).inserted else { throw ServiceError.alreadySubmitted }
        case .allowance(let amount), .attest(let amount, _):
            guard amount.cents >= 0 else { throw ServiceError.invalidRequest }
        case .savings(let kind, let amount, _):
            guard kind == .adjustment || amount.cents > 0 else { throw ServiceError.invalidRequest }
        case .csv(let rows):
            guard !rows.isEmpty, rows.allSatisfy({ !$0.merchant.isEmpty }) else { throw ServiceError.invalidRequest }
        case .transaction(let id, let change, let value, _):
            guard let row = Fixtures.snapshot().purchases.first(where: { $0.id == id }) else { throw ServiceError.invalidRequest }
            if change == .delete && row.source != "manual" { throw ServiceError.invalidRequest }
            if change == .restore && !row.excluded { throw ServiceError.invalidRequest }
            if change == .reclassify && !["charge", "refund", "fund_charge"].contains(value) { throw ServiceError.invalidRequest }
        case .resolveHeld(let id):
            guard Fixtures.snapshot().heldRefunds.contains(where: { $0.id == id }) else { throw ServiceError.invalidRequest }
        case .manual, .flag, .bankSync: break
        }
    }
    public func signOut() { session = nil; receipts = [:]; events = []; decidedRequests = [] }
}

public protocol BankLinking: Sendable {
    func beginLink() async throws
    func disconnect() async throws
}
public protocol EmailConnecting: Sendable {
    func beginConsent() async throws
    func poll() async throws
    func disconnect() async throws
}
public struct UnconnectedIntegrations: BankLinking, EmailConnecting {
    public init() {}
    public func beginLink() async throws { throw ServiceError.unavailable }
    public func beginConsent() async throws { throw ServiceError.unavailable }
    public func poll() async throws { throw ServiceError.unavailable }
    public func disconnect() async throws { throw ServiceError.unavailable }
}
