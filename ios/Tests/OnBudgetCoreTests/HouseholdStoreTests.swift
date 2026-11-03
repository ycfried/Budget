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
    func testLostResponseRetryReusesIntentAndDoesNotDuplicatePurchase() async throws {
        let service = MockHouseholdService()
        let store = HouseholdStore(service: service)
        await store.openSample(.admin)
        let before = try XCTUnwrap(store.snapshot)
        store.scenario = .responseLost
        await store.refresh()
        let input = try ManualPurchase(merchant: "Retry sample", amount: Money(cents: 100), date: PurchaseDate("2026-11-03"), cardSuffix: "1111")
        let first = await store.submit(.manual(input))
        XCTAssertFalse(first)
        XCTAssertNotNil(store.toast)
        XCTAssertFalse(store.submitting)
        let retry = await store.submit(.manual(input))
        XCTAssertTrue(retry)
        XCTAssertEqual(store.snapshot?.purchases.count, before.purchases.count + 1)
        XCTAssertEqual(store.snapshot?.audit.count, before.audit.count + 1)
        XCTAssertEqual(store.sampleActions.count, 1)
    }
    func testFailedResponseIdentityDoesNotLeakIntoNewSession() async throws {
        let service = MockHouseholdService()
        let store = HouseholdStore(service: service)
        await store.openSample(.admin)
        store.scenario = .responseLost
        await store.refresh()
        let first = await store.submit(.flag(id: "sample-1", note: "sample"))
        XCTAssertFalse(first)
        await store.signOut()
        await store.openSample(.member)
        XCTAssertEqual(store.snapshot?.purchases.first?.state, .posted)
        XCTAssertTrue(store.sampleActions.isEmpty)
        XCTAssertNil(store.toast)
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
