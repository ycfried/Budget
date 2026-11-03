import XCTest
@testable import OnBudgetCore

final class ServiceTests: XCTestCase {
    func testSignedOutCannotReadOrWrite() async {
        let service = MockHouseholdService()
        do { _ = try await service.snapshot(); XCTFail("Expected signed-out error") }
        catch { XCTAssertEqual(error as? ServiceError, .signedOut) }
        do { _ = try await service.submit(.bankSync, idempotencyKey: UUID()); XCTFail("Expected signed-out error") }
        catch { XCTAssertEqual(error as? ServiceError, .signedOut) }
    }
    func testMemberCannotCallAdminActionsDirectly() async {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .member)
        let actions: [HouseholdAction] = [.allowance(Money(cents: 0)), .bankSync,
            .approve(requestID: "request-sample", amount: Money(cents: 100), overrideReason: ""),
            .decline(requestID: "request-sample"), .allocate(amount: Money(cents: 100), note: "", overrideReason: ""),
            .attest(Money(cents: 100), note: ""), .savings(.interest, Money(cents: 100), note: ""),
            .resolveHeld(id: "held-sample"), .temporaryIncrease(Money(cents: 100), note: ""),
            .transaction(id: "sample-1", change: .exclude, value: "", reason: ""), .csv([])]
        for action in actions {
            do { _ = try await service.submit(action, idempotencyKey: UUID()); XCTFail(action.label) }
            catch { XCTAssertEqual(error as? ServiceError, .forbidden) }
        }
    }
    func testMemberRequestRecordsReceiptWithoutCalculatingBalances() async throws {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .member)
        let before = try await service.snapshot()
        let receipt = try await service.submit(.request(transactionID: "sample-1", amount: Money(cents: 100), note: "Sample"), idempotencyKey: UUID())
        let after = try await service.snapshot()
        XCTAssertTrue(receipt.message.contains("fixtures stay fixed"))
        XCTAssertEqual(before.dashboard, after.dashboard)
        XCTAssertEqual(before.fund, after.fund)
        XCTAssertEqual(after.audit.count, before.audit.count + 1)
    }
    func testIdempotencyAndDuplicateDecision() async throws {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .admin)
        let key = UUID()
        let action = HouseholdAction.approve(requestID: "request-sample", amount: Money(cents: 100), overrideReason: "")
        let first = try await service.submit(action, idempotencyKey: key)
        let second = try await service.submit(action, idempotencyKey: key)
        XCTAssertEqual(first, second)
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.audit.count, 2)
        do { _ = try await service.submit(action, idempotencyKey: UUID()); XCTFail("Duplicate decision allowed") }
        catch { XCTAssertEqual(error as? ServiceError, .alreadySubmitted) }
    }
    func testSplitRequestCannotBeReapproved() async {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .admin)
        do { _ = try await service.submit(.approve(requestID: "split-sample", amount: Money(cents: 100), overrideReason: ""), idempotencyKey: UUID()); XCTFail("Split remainder must remain closed") }
        catch { XCTAssertEqual(error as? ServiceError, .alreadySubmitted) }
    }
    func testOverapprovalAndInvalidAmountRejected() async {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .admin)
        for cents: Int64 in [0, -1, 8_001] {
            do { _ = try await service.submit(.approve(requestID: "request-sample", amount: Money(cents: cents), overrideReason: ""), idempotencyKey: UUID()); XCTFail("Invalid amount") }
            catch { XCTAssertEqual(error as? ServiceError, .invalidRequest) }
        }
    }
    func testOfflineDeniesWritesAndFailureDoesNotInventEmptySuccess() async {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .admin)
        await service.setScenario(.offline)
        do { _ = try await service.submit(.bankSync, idempotencyKey: UUID()); XCTFail("Offline write") }
        catch { XCTAssertEqual(error as? ServiceError, .offline) }
        await service.setScenario(.failure)
        do { _ = try await service.snapshot(); XCTFail("Read failure must throw") }
        catch { XCTAssertEqual(error as? ServiceError, .simulatedFailure) }
    }
    func testNegativeDisplayScenarioAndSignOutReset() async throws {
        let service = MockHouseholdService()
        _ = await service.openSample(role: .admin)
        await service.setScenario(.overspent)
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.dashboard.week.availableCents, -2_500)
        await service.signOut()
        do { _ = try await service.snapshot(); XCTFail("Data leaked after signout") }
        catch { XCTAssertEqual(error as? ServiceError, .signedOut) }
    }
    func testIntegrationsFailClosed() async {
        let integration = UnconnectedIntegrations()
        do { try await integration.beginLink(); XCTFail("Unexpected bank connection") }
        catch { XCTAssertEqual(error as? ServiceError, .unavailable) }
        do { try await integration.beginConsent(); XCTFail("Unexpected email connection") }
        catch { XCTAssertEqual(error as? ServiceError, .unavailable) }
    }
}
