import XCTest
@testable import OnBudgetCore

@MainActor
final class HouseholdStoreTests: XCTestCase {
    func testOfflineRetainsLastKnownSnapshotAndPreventsWrites() async throws {
        let store = HouseholdStore()
        await store.openSample(.admin)
        let before = try XCTUnwrap(store.snapshot)
        store.scenario = .offline
        await store.refresh()
        XCTAssertEqual(store.snapshot, before)
        XCTAssertNotNil(store.readError)
        XCTAssertFalse(store.canWrite)
        let submitted = await store.submit(.bankSync)
        XCTAssertFalse(submitted)
        XCTAssertTrue(store.sampleActions.isEmpty)
    }
    func testFailedActionIsReportedAndCanBeRetriedWithoutDismissingInput() async {
        let store = HouseholdStore()
        await store.openSample(.member)
        let denied = await store.submit(.allowance(Money(cents: 1)))
        XCTAssertFalse(denied)
        XCTAssertNotNil(store.toast)
        XCTAssertFalse(store.submitting)
        let allowed = await store.submit(.request(transactionID: nil, amount: Money(cents: 100), note: "Sample"))
        XCTAssertTrue(allowed)
        XCTAssertEqual(store.sampleActions, ["Fund request"])
    }
    func testSignOutClearsSnapshotAndWidgetCallbackImmediately() async {
        var cached: WidgetSnapshot?
        let store = HouseholdStore(onSnapshot: { cached = $0 })
        await store.openSample(.admin)
        XCTAssertNotNil(cached)
        await store.signOut()
        XCTAssertNil(cached)
        XCTAssertNil(store.session)
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.canWrite)
    }
    func testReadFailureRecoveryRestoresWriteAvailability() async {
        let store = HouseholdStore()
        await store.openSample(.admin)
        store.scenario = .failure
        await store.refresh()
        XCTAssertNotNil(store.readError)
        store.scenario = .normal
        await store.refresh()
        XCTAssertNil(store.readError)
        XCTAssertTrue(store.canWrite)
    }
    func testLateRefreshCannotRepopulateAfterSignOut() async {
        let service = SuspendedService()
        let store = HouseholdStore(service: service)
        let opening = Task { await store.openSample(.admin) }
        await service.waitUntilReadStarted()
        await store.signOut()
        await service.finishRead()
        await opening.value
        XCTAssertNil(store.session)
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.loading)
    }
}

private actor SuspendedService: HouseholdService {
    private var read: CheckedContinuation<HouseholdSnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func openSample(role: Role) -> Session { Session(role: role, displayName: "Sample") }
    func snapshot() async throws -> HouseholdSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            read = continuation; started?.resume(); started = nil
        }
    }
    func waitUntilReadStarted() async {
        if read != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishRead() { read?.resume(returning: Fixtures.snapshot()); read = nil }
    func submit(_ action: HouseholdAction, idempotencyKey: UUID) -> ActionReceipt { ActionReceipt(message: "Sample only") }
    func setScenario(_ scenario: SampleScenario) {}
    func signOut() {}
}
