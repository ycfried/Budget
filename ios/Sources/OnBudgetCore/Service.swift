import Foundation

public enum ServiceError: Error, LocalizedError, Equatable, Sendable {
    case signedOut, forbidden, offline, simulatedFailure, unavailable, invalidRequest, alreadySubmitted
    case invalidTransition, missingTarget, idempotencyConflict, responseLost
    public var errorDescription: String? {
        switch self {
        case .signedOut: "Open a sample household first."
        case .forbidden: "Only the household admin can perform this action."
        case .offline: "You're offline. Last-known sample data is read-only."
        case .simulatedFailure: "The sample service could not refresh. Try again."
        case .unavailable: "This integration is not connected. Staging approval is required."
        case .invalidRequest: "Check the amount and required fields."
        case .invalidTransition: "This state change is not allowed. Refresh the purchase and try again."
        case .missingTarget: "This sample record no longer exists."
        case .idempotencyConflict: "A retry identifier cannot be reused for a different action."
        case .responseLost: "The sample action was saved, but its response was lost. Retry the same action safely."
        case .alreadySubmitted: "This sample request has already been decided."
        }
    }
}
public enum SampleScenario: String, CaseIterable, Sendable {
    case normal = "Normal", overspent = "Overspent", offline = "Offline", failure = "Read error", responseLost = "Lost write response"
}
public enum TransactionChange: String, CaseIterable, Sendable {
    case exclude = "Exclude", restore = "Restore", delete = "Void manual purchase", reclassify = "Reclassify"
    case confirmReview = "Confirm reviewed purchase", approveQuarantine = "Approve quarantined purchase", void = "Void purchase"
}
public enum SavingsKind: String, CaseIterable, Sendable {
    case transferIn = "transfer_in", withdrawal, interest, adjustment
}
public enum HouseholdAction: Equatable, Sendable {
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
    func snapshot() async throws -> HouseholdSnapshot
    func submit(_ action: HouseholdAction, idempotencyKey: UUID) async throws -> ActionReceipt
    func signOut() async
}
/// Sample controls are deliberately absent from a future production repository.
public protocol SampleHouseholdService: HouseholdService {
    func openSample(role: Role) async -> Session
    func setScenario(_ scenario: SampleScenario) async
}
/// Stateful synthetic interaction service. No HTTP/SDK or accounting engine.
/// Only record state/history changes; every monetary summary remains a literal fixture.
public actor MockHouseholdService: SampleHouseholdService {
    private var session: Session?
    private var scenario: SampleScenario = .normal
    private var receipts: [UUID: (HouseholdAction, ActionReceipt)] = [:]
    private var events: [AuditEvent] = []
    private var purchases: [Purchase]
    private var requests: [FundRequest]
    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        purchases = Fixtures.snapshot().purchases
        requests = Fixtures.snapshot().requests
    }
    public func openSample(role: Role) -> Session {
        let value = Session(role: role, displayName: role == .admin ? "Sample admin" : "Sample member")
        session = value
        return value
    }
    public func setScenario(_ value: SampleScenario) { scenario = value }
    public func snapshot() throws -> HouseholdSnapshot {
        try Task.checkCancellation()
        guard session != nil else { throw ServiceError.signedOut }
        if scenario == .offline { throw ServiceError.offline }
        if scenario == .failure { throw ServiceError.simulatedFailure }
        let base = Fixtures.snapshot(overspent: scenario == .overspent)
        return HouseholdSnapshot(dashboard: base.dashboard, purchases: purchases, fund: base.fund,
            requests: requests, fundLedger: base.fundLedger, heldRefunds: base.heldRefunds,
            restorations: base.restorations, savings: base.savings, history: base.history,
            audit: events + base.audit, sources: base.sources)
    }
    public func submit(_ action: HouseholdAction, idempotencyKey: UUID) throws -> ActionReceipt {
        try Task.checkCancellation()
        guard let session else { throw ServiceError.signedOut }
        guard !action.adminOnly || session.role == .admin else { throw ServiceError.forbidden }
        guard scenario != .offline else { throw ServiceError.offline }
        guard scenario != .failure else { throw ServiceError.simulatedFailure }
        if let (original, receipt) = receipts[idempotencyKey] {
            guard original == action else { throw ServiceError.idempotencyConflict }
            return receipt
        }
        // All checks/mutations complete synchronously inside this actor, without suspension.
        try apply(action, operation: idempotencyKey, actor: session.displayName)
        let message: String
        switch action {
        case .manual, .csv, .request, .approve, .decline, .transaction, .flag:
            message = "Sample records updated. Financial fixtures stay fixed; no real account was changed."
        default:
            message = "Sample intent recorded only. Server authority is required; financial fixtures stay fixed."
        }
        let receipt = ActionReceipt(message: message)
        receipts[idempotencyKey] = (action, receipt)
        events.insert(AuditEvent(id: idempotencyKey.uuidString, actor: session.displayName,
            action: action.label, detail: receipt.message, date: now()), at: 0)
        if scenario == .responseLost { throw ServiceError.responseLost }
        return receipt
    }
    private func index(_ id: String) throws -> Int {
        guard let index = purchases.firstIndex(where: { $0.id == id }) else { throw ServiceError.missingTarget }
        return index
    }
    private func apply(_ action: HouseholdAction, operation: UUID, actor: String) throws {
        switch action {
        case .manual(let input):
            var purchase = Purchase(id: "sample-" + operation.uuidString, date: input.date, merchant: input.merchant,
                amount: input.amount, cardSuffix: input.cardSuffix, source: "manual", state: "provisional",
                kind: "charge", provenance: "Synthetic manual entry; not bank confirmed.", allocation: Money(cents: 0))
            record(&purchase, from: .provisional, action: "Created provisional purchase", note: "", actor: actor)
            purchases.insert(purchase, at: 0)
        case .csv(let rows):
            guard !rows.isEmpty, Set(rows.map(\.rowNumber)).count == rows.count,
                  rows.allSatisfy({ !$0.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.merchant.count <= 120 && $0.amount.cents != 0
                    && $0.cardSuffix.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil }) else { throw ServiceError.invalidRequest }
            // Stable row identity within ONE operation, not a merchant/amount dedupe algorithm.
            let batch = rows.map { row in
                var purchase = Purchase(id: "sample-csv-\(operation.uuidString)-\(row.rowNumber)", date: row.date,
                    merchant: row.merchant, amount: row.amount, cardSuffix: row.cardSuffix, source: "csv",
                    state: row.amount.cents < 0 ? "needs_review" : "provisional",
                    kind: row.amount.cents < 0 ? "unclassified_credit" : "charge",
                    provenance: "Synthetic CSV row \(row.rowNumber). Reconciliation requires the server.", allocation: Money(cents: 0))
                record(&purchase, from: purchase.state, action: "Imported sample row", note: row.amount.cents < 0 ? "Credit classification requires server evidence; not assumed to be a refund." : "", actor: actor)
                return purchase
            }
            purchases.insert(contentsOf: batch, at: 0)
        case .request(let transactionID, let amount, let note):
            guard amount.cents > 0 else { throw ServiceError.invalidRequest }
            var merchant = "Unlinked sample request"
            if let transactionID {
                let purchase = purchases[try index(transactionID)]
                guard !purchase.state.isTerminal, !purchase.excluded, purchase.state != .quarantined,
                      purchase.kind == .charge || purchase.kind == .fundCharge else { throw ServiceError.invalidRequest }
                merchant = purchase.merchant
            }
            var request = FundRequest(id: "sample-request-" + operation.uuidString, merchant: merchant,
                requester: actor, note: note, status: "pending", amount: amount, remainder: Money(cents: 0))
            request.transactionID = transactionID
            requests.insert(request, at: 0)
        case .approve(let id, let amount, _):
            guard let i = requests.firstIndex(where: { $0.id == id }) else { throw ServiceError.missingTarget }
            guard requests[i].status == "pending" else { throw ServiceError.alreadySubmitted }
            guard amount.cents > 0, amount.cents <= requests[i].amount.cents else { throw ServiceError.invalidRequest }
            requests[i].status = amount == requests[i].amount ? "approved" : "split"
            // Requested-minus-approved is workflow remainder, not a fund balance calculation.
            requests[i].remainder = Money(cents: requests[i].amount.cents - amount.cents)
            requests[i].approvedAmount = amount; requests[i].decidedBy = actor
        case .decline(let id):
            guard let i = requests.firstIndex(where: { $0.id == id }) else { throw ServiceError.missingTarget }
            guard requests[i].status == "pending" else { throw ServiceError.alreadySubmitted }
            requests[i].status = "declined"; requests[i].decidedBy = actor
        case .transaction(let id, let change, let value, let reason):
            let i = try index(id)
            var purchase = purchases[i]
            let previous = purchase.state
            var eventNote = reason
            switch change {
            case .exclude:
                guard !previous.isTerminal, previous != .quarantined else { throw ServiceError.invalidTransition }
                if case .unknown = previous { throw ServiceError.invalidTransition }
                if previous != .excluded { purchase.priorState = previous; purchase.state = .excluded }
            case .restore:
                guard previous == .excluded, let saved = purchase.priorState, saved != .excluded else { throw ServiceError.invalidTransition }
                purchase.state = saved; purchase.priorState = nil
            case .reclassify:
                guard [.provisional, .pending, .posted, .review, .excluded].contains(previous),
                      ["charge", "refund", "fund_charge"].contains(value) else { throw ServiceError.invalidRequest }
                eventNote = "Classification \(purchase.kind.wireValue) → \(value). \(reason)"
                purchase.kind = TransactionKind(wireValue: value)
            case .delete:
                guard purchase.source == "manual", [.provisional, .pending, .posted, .review, .excluded].contains(previous) else { throw ServiceError.invalidTransition }
                purchase.state = .voided // Keep history; do not invent an authoritative backend delete policy.
            case .confirmReview:
                guard previous == .review, [.charge, .fundCharge].contains(purchase.kind) else { throw ServiceError.invalidTransition }
                purchase.state = .posted; purchase.reviewOrigin = nil
            case .approveQuarantine:
                guard previous == .quarantined else { throw ServiceError.invalidTransition }
                purchase.state = .provisional
            case .void:
                guard previous == .review || previous == .quarantined else { throw ServiceError.invalidTransition }
                purchase.state = .voided
            }
            record(&purchase, from: previous, action: change.rawValue, note: eventNote, actor: actor)
            purchases[i] = purchase
        case .flag(let id, let note):
            let i = try index(id)
            guard [.provisional, .pending, .posted].contains(purchases[i].state) else { throw ServiceError.invalidTransition }
            let previous = purchases[i].state
            purchases[i].reviewOrigin = previous
            purchases[i].state = .review
            record(&purchases[i], from: previous, action: "Flag for review", note: note, actor: actor)
        case .allocate(let amount, _, _), .temporaryIncrease(let amount, _):
            guard amount.cents > 0 else { throw ServiceError.invalidRequest }
        case .allowance(let amount), .attest(let amount, _):
            guard amount.cents >= 0 else { throw ServiceError.invalidRequest }
        case .savings(let kind, let amount, _):
            guard kind == .adjustment || amount.cents > 0 else { throw ServiceError.invalidRequest }
        case .resolveHeld(let id):
            guard Fixtures.snapshot().heldRefunds.contains(where: { $0.id == id }) else { throw ServiceError.missingTarget }
        case .bankSync: break
        }
    }
    private func record(_ purchase: inout Purchase, from previous: TransactionState, action: String, note: String, actor: String) {
        purchase.history.append(TransactionEvent(id: UUID().uuidString, actor: actor, action: action,
            from: previous, to: purchase.state, note: note, date: now()))
    }
    /// Test-only provider response injection, not part of the future client intent protocol.
    /// No matching, refund linkage, restoration or balance calculations take place here.
    public func applySyntheticBankPending(id: String) throws {
        guard session?.role == .admin else { throw ServiceError.forbidden }
        guard scenario != .offline, scenario != .failure else { throw ServiceError.offline }
        let i = try index(id)
        let previous = purchases[i].state
        guard previous == .provisional || (previous == .review && purchases[i].reviewOrigin == .provisional) else { throw ServiceError.invalidTransition }
        purchases[i].state = .pending; purchases[i].reviewOrigin = nil
        record(&purchases[i], from: previous, action: "Synthetic bank match", note: "", actor: "Sample provider")
    }
    public func applySyntheticPosting(id: String, postedAmount: Money? = nil, removed: Bool = false) throws {
        guard session?.role == .admin else { throw ServiceError.forbidden }
        guard scenario != .offline, scenario != .failure else { throw ServiceError.offline }
        let i = try index(id)
        let previous = purchases[i].state
        if removed && previous == .reversed { return }
        if !removed && previous == .posted && (postedAmount == nil || postedAmount == purchases[i].amount) { return }
        let reviewedSource = previous == .review && (purchases[i].reviewOrigin == .pending || purchases[i].reviewOrigin == .provisional)
        guard [.provisional, .pending, .posted].contains(previous) || reviewedSource else { throw ServiceError.invalidTransition }
        purchases[i].state = removed ? .reversed : .posted; purchases[i].reviewOrigin = nil
        if !removed, let postedAmount { purchases[i].amount = postedAmount }
        record(&purchases[i], from: previous, action: removed ? "Synthetic removal" : "Synthetic posting",
            note: "Provider fixture only; financial summaries not recomputed.", actor: "Sample provider")
    }
    public func signOut() {
        session = nil; scenario = .normal; receipts = [:]; events = []
        purchases = Fixtures.snapshot().purchases; requests = Fixtures.snapshot().requests
    }
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
