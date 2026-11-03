import Foundation
#if canImport(SwiftUI)
import Observation
#endif

#if canImport(SwiftUI)
@Observable
#endif
@MainActor
public final class HouseholdStore {
    private let service: any HouseholdService
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
    private var pendingOperation: (action: HouseholdAction, id: UUID)?
    public private(set) var closing = false
    public private(set) var opening = false
    #if canImport(SwiftUI)
    @ObservationIgnored
    #endif
    private let onSnapshot: @MainActor (WidgetSnapshot?) -> Void
    public init(service: any HouseholdService = MockHouseholdService(), onSnapshot: @escaping @MainActor (WidgetSnapshot?) -> Void = { _ in }) {
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
            await service.setScenario(scenario)
            let response = try await service.snapshot()
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
        do {
            let operation: UUID
            if let pending = pendingOperation, pending.action == action { operation = pending.id }
            else { operation = UUID(); pendingOperation = (action, operation) }
            let receipt = try await service.submit(action, idempotencyKey: operation)
            guard generation == current else { return false }
            pendingOperation = nil
            sampleActions.insert(action.label, at: 0)
            notify(receipt.message)
            await refresh()
            if generation == current, readError != nil { notify("Sample action saved, but refresh failed. Retry refresh before another action.") }
            return generation == current
        } catch {
            if generation == current { notify(error.localizedDescription) }
            return false
        }
    }
    public func signOut() async {
        guard !closing else { return }
        closing = true
        generation += 1
        pendingOperation = nil
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
