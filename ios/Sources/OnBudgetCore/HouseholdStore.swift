import Foundation
#if canImport(SwiftUI)
import Observation
#endif

#if canImport(SwiftUI)
@Observable
#endif
@MainActor
public final class HouseholdStore {
    private let service: any SampleHouseholdService
    public private(set) var session: Session?
    public private(set) var snapshot: HouseholdSnapshot?
    public var scenario: SampleScenario = .normal
    public private(set) var loading = false
    public private(set) var submitting = false
    public private(set) var readError: String?
    public var toast: String?
    public private(set) var sampleActions: [String] = []
    private var toastTask: Task<Void, Never>?
    private var generation = 0
    private var pendingOperations: [(action: HouseholdAction, id: UUID)] = []
    public private(set) var writeState: WriteState = .idle
    public private(set) var closing = false
    public private(set) var opening = false
    #if canImport(SwiftUI)
    @ObservationIgnored
    #endif
    private let onSnapshot: @MainActor (WidgetSnapshot?) -> Void
    public init(service: any SampleHouseholdService = MockHouseholdService(), onSnapshot: @escaping @MainActor (WidgetSnapshot?) -> Void = { _ in }) {
        self.service = service; self.onSnapshot = onSnapshot
    }
    public func openSample(_ role: Role) async {
        guard !opening, !loading, !closing, session == nil else { return }
        opening = true
        let current = generation
        let opened = await service.openSample(role: role)
        guard generation == current else { return }
        opening = false
        session = opened
        await refresh()
    }
    public func refresh() async {
        guard session != nil, !loading else { return }
        loading = true
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            try Task.checkCancellation()
            await service.setScenario(scenario)
            let response = try await service.snapshot()
            try Task.checkCancellation()
            guard generation == current else { return }
            snapshot = response; readError = nil
            onSnapshot(WidgetSnapshot(available: Money(cents: response.dashboard.week.availableCents),
                fundAvailable: response.fund.available, computedAt: response.dashboard.computedAt, isSample: true))
        } catch {
            guard generation == current else { return }
            readError = error.localizedDescription
        }
    }
    @discardableResult public func submit(_ action: HouseholdAction) async -> Bool {
        guard session != nil, !submitting, !loading, readError == nil else { return false }
        submitting = true
        let current = generation
        defer { if generation == current { submitting = false } }
        let operation: UUID
        if let pending = pendingOperations.first(where: { $0.action == action }) { operation = pending.id }
        else { operation = UUID(); pendingOperations.append((action, operation)) }
        writeState = .submitting(operation)
        do {
            try Task.checkCancellation()
            let receipt = try await service.submit(action, idempotencyKey: operation)
            guard generation == current else { return false }
            pendingOperations.removeAll { $0.id == operation }
            writeState = .succeeded(operation)
            sampleActions.insert(action.label, at: 0)
            notify(receipt.message)
            await refresh()
            if generation == current, readError != nil { notify("Sample action saved, but refresh failed. Retry refresh before another action.") }
            return generation == current
        } catch {
            if generation == current {
                let failure = OperationFailure(error)
                writeState = .failed(operation, failure)
                if failure.retry == .doNotRetry { pendingOperations.removeAll { $0.id == operation } }
                notify(error is CancellationError ? "Request cancelled. Its outcome may be unknown; retry the same intent to reconcile." : error.localizedDescription)
            }
            return false
        }
    }
    public func signOut() async {
        guard !closing else { return }
        closing = true
        generation += 1
        pendingOperations = []; writeState = .idle
        session = nil; snapshot = nil; sampleActions = []; readError = nil; scenario = .normal
        submitting = false; loading = false; toastTask?.cancel(); toast = nil
        opening = false
        onSnapshot(nil)
        await service.signOut()
        closing = false
    }
    public func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
    public var canWrite: Bool { session != nil && !opening && !closing && readError == nil && !loading && !submitting }
    public var isAdmin: Bool { session?.role == .admin }
}
