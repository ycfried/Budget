import XCTest
@testable import OnBudgetCore

final class StatefulWorkflowTests: XCTestCase {
    private func admin() async -> MockHouseholdService {
        let service = MockHouseholdService(now: { Fixtures.instant })
        _ = await service.openSample(role: .admin)
        return service
    }
    private func row(_ service: MockHouseholdService, _ id: String) async throws -> Purchase {
        let snapshot = try await service.snapshot()
        return try XCTUnwrap(snapshot.purchases.first { $0.id == id })
    }
    func testEveryStateRoundTripsAndUnknownFailsVisible() throws {
        let states: [TransactionState] = [.provisional, .pending, .posted, .review, .excluded, .reversed, .voided, .quarantined, .unknown("future_state")]
        for state in states {
            XCTAssertEqual(try JSONDecoder().decode(TransactionState.self, from: JSONEncoder().encode(state)), state)
        }
        XCTAssertNotEqual(TransactionState.provisional.label, TransactionState.pending.label)
        XCTAssertEqual(TransactionState(wireValue: "verified"), .posted)
        XCTAssertEqual(TransactionKind(wireValue: "future_kind"), .unknown("future_kind"))
    }
    func testManualCreationAppearsWithHistoryAndNoFinancialRecompute() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        let input = try ManualPurchase(merchant: "Synthetic shop", amount: Money(cents: 1_234), date: PurchaseDate("2026-11-03"), cardSuffix: "1111")
        _ = try await service.submit(.manual(input), idempotencyKey: UUID())
        let after = try await service.snapshot()
        XCTAssertEqual(after.purchases.count, before.purchases.count + 1)
        XCTAssertEqual(after.purchases.first?.merchant, input.merchant)
        XCTAssertEqual(after.purchases.first?.state, .provisional)
        XCTAssertEqual(after.purchases.first?.history.count, 1)
        assertFinancialFixturesUnchanged(before, after)
    }
    func testExcludeRestoreRetainsPendingRefundWithoutPromotingIt() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        for _ in 0..<2 { _ = try await service.submit(.transaction(id: "sample-4", change: .exclude, value: "", reason: ""), idempotencyKey: UUID()) }
        let excluded = try await row(service, "sample-4")
        XCTAssertEqual(excluded.state, .excluded)
        XCTAssertEqual(excluded.priorState, .pending)
        _ = try await service.submit(.transaction(id: "sample-4", change: .restore, value: "", reason: ""), idempotencyKey: UUID())
        let restored = try await row(service, "sample-4")
        XCTAssertEqual(restored.state, .pending)
        XCTAssertNil(restored.priorState)
        XCTAssertEqual(restored.history.count, 3)
        XCTAssertEqual(restored.history.last?.actor, "Sample admin")
        let after = try await service.snapshot()
        assertFinancialFixturesUnchanged(before, after)
    }
    func testQuarantineApproveThenReviewConfirmAndTerminalVoid() async throws {
        let service = await admin()
        _ = try await service.submit(.transaction(id: "sample-9", change: .approveQuarantine, value: "", reason: "sample approval"), idempotencyKey: UUID())
        let approved = try await row(service, "sample-9")
        XCTAssertEqual(approved.state, .provisional)
        _ = try await service.submit(.flag(id: "sample-9", note: "Check evidence"), idempotencyKey: UUID())
        _ = try await service.submit(.transaction(id: "sample-9", change: .confirmReview, value: "", reason: "sample only"), idempotencyKey: UUID())
        let confirmed = try await row(service, "sample-9")
        XCTAssertEqual(confirmed.state, .posted)
        _ = try await service.submit(.flag(id: "sample-9", note: "Duplicate sample"), idempotencyKey: UUID())
        _ = try await service.submit(.transaction(id: "sample-9", change: .void, value: "", reason: ""), idempotencyKey: UUID())
        let voided = try await row(service, "sample-9")
        XCTAssertEqual(voided.state, .voided)
        XCTAssertEqual(voided.history.count, 5)
        do {
            _ = try await service.submit(.transaction(id: "sample-9", change: .restore, value: "", reason: ""), idempotencyKey: UUID())
            XCTFail("Voided must not restore through exclusion path")
        } catch { XCTAssertEqual(error as? ServiceError, .invalidTransition) }
    }
    func testPendingRefundCannotBeHumanConfirmedOrRestoredByDate() async throws {
        let service = await admin()
        _ = try await service.submit(.flag(id: "sample-4", note: ""), idempotencyKey: UUID())
        do {
            _ = try await service.submit(.transaction(id: "sample-4", change: .confirmReview, value: "", reason: ""), idempotencyKey: UUID())
            XCTFail("A pending refund requires provider confirmation")
        } catch { XCTAssertEqual(error as? ServiceError, .invalidTransition) }
        let refund = try await row(service, "sample-4")
        XCTAssertEqual(refund.state, .review)
        XCTAssertNil(refund.originalPurchaseID)
    }
    func testSyntheticPendingPostedCorrectionRetainsOriginalAmount() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        try await service.applySyntheticBankPending(id: "sample-2")
        try await service.applySyntheticPosting(id: "sample-2", postedAmount: Money(cents: 2_100))
        let posted = try await row(service, "sample-2")
        XCTAssertEqual(posted.state, .posted)
        XCTAssertEqual(posted.amount.cents, 2_100)
        XCTAssertEqual(posted.originalAmount.cents, 1_875)
        XCTAssertEqual(posted.history.map(\.to), [.pending, .posted])
        let after = try await service.snapshot()
        assertFinancialFixturesUnchanged(before, after)
    }
    func testPostedAndRemovedRefundDoNotRunRestoration() async throws {
        for removed in [false, true] {
            let service = await admin()
            let before = try await service.snapshot()
            try await service.applySyntheticPosting(id: "sample-4", removed: removed)
            let refund = try await row(service, "sample-4")
            XCTAssertEqual(refund.state, removed ? .reversed : .posted)
            XCTAssertEqual(refund.kind, .refund)
            let after = try await service.snapshot()
            assertFinancialFixturesUnchanged(before, after)
        }
    }
    func testCSVReplayIsIdempotentButIdenticalRealRowsStaySeparate() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        let preview = CSVImport.preview("Date,Description,Amount,Card Ending\n2026-11-03,Same sample,12.00,1111\n2026-11-03,Same sample,12.00,1111\n2026-11-03,Return,-3.00,1111")
        XCTAssertTrue(preview.errors.isEmpty)
        let key = UUID()
        for _ in 0..<2 { _ = try await service.submit(.csv(preview.rows), idempotencyKey: key) }
        let after = try await service.snapshot()
        XCTAssertEqual(after.purchases.count, before.purchases.count + 3)
        let inserted = Array(after.purchases.prefix(3))
        XCTAssertEqual(Set(inserted.map(\.id)).count, 3)
        XCTAssertTrue(inserted.allSatisfy { $0.history.count == 1 })
        XCTAssertTrue(inserted.prefix(2).allSatisfy { $0.state == .provisional })
        XCTAssertEqual(inserted.last?.kind, .unknown("unclassified_credit"))
        XCTAssertEqual(inserted.last?.state, .review)
        assertFinancialFixturesUnchanged(before, after)
    }
    func testInvalidCSVBatchChangesNothing() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        let rows = [CSVRow(rowNumber: 2, date: try PurchaseDate("2026-11-03"), merchant: "Valid", amount: Money(cents: 100), cardSuffix: "1111"),
                    CSVRow(rowNumber: 3, date: try PurchaseDate("2026-11-03"), merchant: "", amount: Money(cents: 100), cardSuffix: "1111")]
        do { _ = try await service.submit(.csv(rows), idempotencyKey: UUID()); XCTFail("Bad batch") }
        catch { XCTAssertEqual(error as? ServiceError, .invalidRequest) }
        let after = try await service.snapshot()
        XCTAssertEqual(before, after)
    }
    func testRequestCreationPartialApprovalAndClosedRemainder() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        _ = await service.openSample(role: .member)
        _ = try await service.submit(.request(transactionID: "sample-1", amount: Money(cents: 1_000), note: "sample"), idempotencyKey: UUID())
        let created = try await service.snapshot().requests[0]
        XCTAssertEqual(created.transactionID, "sample-1")
        XCTAssertEqual(created.requester, "Sample member")
        _ = await service.openSample(role: .admin)
        _ = try await service.submit(.approve(requestID: created.id, amount: Money(cents: 600), overrideReason: ""), idempotencyKey: UUID())
        let after = try await service.snapshot()
        let decided = try XCTUnwrap(after.requests.first { $0.id == created.id })
        XCTAssertEqual(decided.status, "split")
        XCTAssertEqual(decided.remainder.cents, 400)
        XCTAssertEqual(decided.approvedAmount?.cents, 600)
        XCTAssertEqual(decided.decidedBy, "Sample admin")
        do { _ = try await service.submit(.approve(requestID: created.id, amount: Money(cents: 400), overrideReason: ""), idempotencyKey: UUID()); XCTFail("Closed split remainder") }
        catch { XCTAssertEqual(error as? ServiceError, .alreadySubmitted) }
        assertFinancialFixturesUnchanged(before, after)
    }
    func testConcurrentDecisionsHaveOnlyOneWinner() async throws {
        let service = await admin()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { _ = try await service.submit(.decline(requestID: "request-sample"), idempotencyKey: UUID()); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let after = try await service.snapshot()
        XCTAssertEqual(after.requests.first?.status, "declined")
        XCTAssertEqual(after.audit.count, Fixtures.snapshot().audit.count + 1)
    }
    func testReusedOperationForDifferentPayloadIsRejected() async throws {
        let service = await admin()
        let key = UUID()
        _ = try await service.submit(.bankSync, idempotencyKey: key)
        do { _ = try await service.submit(.attest(Money(cents: 100), note: ""), idempotencyKey: key); XCTFail("Conflicting payload") }
        catch { XCTAssertEqual(error as? ServiceError, .idempotencyConflict) }
    }
    func testTerminalAndMissingTargetsFailWithoutMutation() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        for id in ["sample-8", "sample-10"] {
            do { _ = try await service.submit(.transaction(id: id, change: .exclude, value: "", reason: ""), idempotencyKey: UUID()); XCTFail("Terminal exclusion") }
            catch { XCTAssertEqual(error as? ServiceError, .invalidTransition) }
        }
        do { _ = try await service.submit(.flag(id: "missing", note: ""), idempotencyKey: UUID()); XCTFail("Missing target") }
        catch { XCTAssertEqual(error as? ServiceError, .missingTarget) }
        let after = try await service.snapshot()
        XCTAssertEqual(after, before)
    }
    func testSignOutResetsAllDomainAndRetryState() async throws {
        let service = await admin()
        _ = try await service.submit(.flag(id: "sample-1", note: ""), idempotencyKey: UUID())
        await service.signOut()
        _ = await service.openSample(role: .admin)
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot, Fixtures.snapshot())
    }
    func testReviewedPendingRefundCanOnlyBePostedBySyntheticProvider() async throws {
        let service = await admin()
        _ = try await service.submit(.flag(id: "sample-4", note: ""), idempotencyKey: UUID())
        let reviewed = try await row(service, "sample-4")
        XCTAssertEqual(reviewed.reviewOrigin, .pending)
        try await service.applySyntheticPosting(id: "sample-4")
        let posted = try await row(service, "sample-4")
        XCTAssertEqual(posted.state, .posted)
        XCTAssertNil(posted.reviewOrigin)
    }
    func testSyntheticRemovedPostedPurchaseRemainsInHistoryAndReplayIsNoOp() async throws {
        let service = await admin()
        try await service.applySyntheticPosting(id: "sample-1", removed: true)
        try await service.applySyntheticPosting(id: "sample-1", removed: true)
        let removed = try await row(service, "sample-1")
        XCTAssertEqual(removed.state, .reversed)
        XCTAssertEqual(removed.history.count, 1)
    }
    func testReclassificationChangesKindAndManualVoidPreservesRecord() async throws {
        let service = await admin()
        _ = try await service.submit(.transaction(id: "sample-3", change: .reclassify, value: "fund_charge", reason: "sample only"), idempotencyKey: UUID())
        let classified = try await row(service, "sample-3")
        XCTAssertEqual(classified.kind, .fundCharge)
        _ = try await service.submit(.transaction(id: "sample-3", change: .delete, value: "", reason: "sample duplicate"), idempotencyKey: UUID())
        let voided = try await row(service, "sample-3")
        XCTAssertEqual(voided.state, .voided)
        XCTAssertEqual(voided.history.count, 2)
    }
    func testNewTransactionActionsCannotBeInvokedByMember() async {
        let service = await admin()
        _ = await service.openSample(role: .member)
        for change in TransactionChange.allCases {
            do { _ = try await service.submit(.transaction(id: "sample-3", change: change, value: "charge", reason: ""), idempotencyKey: UUID()); XCTFail("Member mutation") }
            catch { XCTAssertEqual(error as? ServiceError, .forbidden) }
        }
    }
    func testUnclassifiedCSVCreditCannotBeConfirmedAsAnOrdinaryPurchase() async throws {
        let service = await admin()
        let rows = CSVImport.preview("Date,Description,Amount,Card Ending\n2026-11-03,Unknown credit,-3.00,1111").rows
        _ = try await service.submit(.csv(rows), idempotencyKey: UUID())
        let snapshot = try await service.snapshot()
        let credit = try XCTUnwrap(snapshot.purchases.first)
        XCTAssertEqual(credit.kind, .unknown("unclassified_credit"))
        do { _ = try await service.submit(.transaction(id: credit.id, change: .confirmReview, value: "", reason: ""), idempotencyKey: UUID()); XCTFail("Ambiguous credit cannot be confirmed") }
        catch { XCTAssertEqual(error as? ServiceError, .invalidTransition) }
    }
    func testFullApprovalClosesRequestAndDoesNotChangeFund() async throws {
        let service = await admin()
        let before = try await service.snapshot()
        _ = try await service.submit(.approve(requestID: "request-sample", amount: Money(cents: 8_000), overrideReason: ""), idempotencyKey: UUID())
        let after = try await service.snapshot()
        XCTAssertEqual(after.requests.first?.status, "approved")
        XCTAssertEqual(after.requests.first?.remainder.cents, 0)
        assertFinancialFixturesUnchanged(before, after)
    }
    private func assertFinancialFixturesUnchanged(_ before: HouseholdSnapshot, _ after: HouseholdSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before.dashboard, after.dashboard, file: file, line: line)
        XCTAssertEqual(before.fund, after.fund, file: file, line: line)
        XCTAssertEqual(before.fundLedger, after.fundLedger, file: file, line: line)
        XCTAssertEqual(before.savings, after.savings, file: file, line: line)
        XCTAssertEqual(before.history, after.history, file: file, line: line)
        XCTAssertEqual(before.restorations, after.restorations, file: file, line: line)
        XCTAssertEqual(before.heldRefunds, after.heldRefunds, file: file, line: line)
    }
}
