import SwiftUI
import OnBudgetCore
import WidgetKit

@MainActor @Observable
final class AppModel {
    private let service: any HouseholdService
    var session: Session?
    var snapshot: HouseholdSnapshot?
    var scenario: SampleScenario = .normal
    var loading = false
    var submitting = false
    var readError: String?
    var toast: String?
    var sampleActions: [String] = []
    private var toastTask: Task<Void, Never>?
    private var generation = 0
    init(service: any HouseholdService = MockHouseholdService()) { self.service = service }
    func openSample(_ role: Role) async {
        guard !loading else { return }
        session = await service.openSample(role: role)
        await refresh()
    }
    func refresh() async {
        guard session != nil, !loading else { return }
        loading = true
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            await service.setScenario(scenario)
            let response = try await service.snapshot()
            guard generation == current else { return }
            snapshot = response; readError = nil
            WidgetCache.save(WidgetSnapshot(available: Money(cents: response.dashboard.week.availableCents),
                fundAvailable: response.fund.available, computedAt: response.dashboard.computedAt, isSample: true))
        } catch {
            guard generation == current else { return }
            readError = error.localizedDescription
        }
    }
    func submit(_ action: HouseholdAction) async {
        guard !submitting, readError == nil else { return }
        submitting = true
        let current = generation
        defer { if generation == current { submitting = false } }
        do {
            let receipt = try await service.submit(action, idempotencyKey: UUID())
            guard generation == current else { return }
            sampleActions.insert(action.label, at: 0)
            notify(receipt.message)
            await refresh()
        } catch { if generation == current { notify(error.localizedDescription) } }
    }
    func signOut() async {
        generation += 1
        await service.signOut()
        session = nil; snapshot = nil; sampleActions = []; readError = nil; scenario = .normal
        submitting = false; loading = false; toastTask?.cancel(); toast = nil
        WidgetCache.clear()
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
    var canWrite: Bool { readError == nil && !loading && !submitting }
    var isAdmin: Bool { session?.role == .admin }
}

/// Shared entitlement is optional until the owner approves Apple capabilities.
/// Without a configured App Group, widgets intentionally show no household data.
enum WidgetCache {
    static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "OnBudgetAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
    }
    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: "displaySnapshot")
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func clear() {
        defaults?.removeObject(forKey: "displaySnapshot")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
