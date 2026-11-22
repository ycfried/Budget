import XCTest
@testable import OnBudgetKit

/// Build 58 (owner, Nov 22, 2026): pending transactions count
/// toward the totals, and same-source duplicates never show twice.
/// The server rules (compute-week chargeContribution, the charity
/// trigger v4, canonical.ts findExistingSameHash) are mirrored by
/// the client helpers in TransactionDedupe.swift; these tests pin
/// the client side of each rule.
final class PendingTotalsTests: XCTestCase {
    private func txn(
        kind: TransactionKind,
        amount: Int,
        date: String,
        state: TransactionState = .verified,
        source: TransactionSource = .plaid,
        excluded: Bool = false,
        dedupeHash: String = "h",
        createdAt: String? = nil
    ) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: date, merchant: "AMAZON",
                    amountCents: amount, cardSuffix: "1005", source: source, state: state,
                    kind: kind, fundAllocationCents: 0, excluded: excluded, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: dedupeHash, originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: createdAt ?? "\(date)T00:00:00Z")
    }

    // MARK: - Pending counts toward spending

    func testProvisionalChargeCountsTowardSpending() {
        // The owner rule: a pending charge counts immediately — the
        // total must be accurate to the minute.
        XCTAssertTrue(txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .provisional).countsTowardSpending)
        XCTAssertTrue(txn(kind: .fundCharge, amount: 4496, date: "2026-11-22", state: .provisional).countsTowardSpending)
    }

    func testVerifiedChargeCountsTowardSpending() {
        XCTAssertTrue(txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .verified).countsTowardSpending)
    }

    func testProvisionalRefundDoesNotCountTowardSpending() {
        // A pending refund restores nothing until it posts.
        XCTAssertFalse(txn(kind: .refund, amount: -4496, date: "2026-11-22", state: .provisional).countsTowardSpending)
    }

    func testExcludedOrReversedChargeDoesNotCount() {
        XCTAssertFalse(txn(kind: .charge, amount: 4496, date: "2026-11-22", excluded: true).countsTowardSpending)
        XCTAssertFalse(txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .reversed).countsTowardSpending)
        XCTAssertFalse(txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .excluded).countsTowardSpending)
    }

    func testNonChargeKindsDoNotCountTowardSpending() {
        for kind in [TransactionKind.transfer, .income, .payment, .cashback, .charity, .refund] {
            XCTAssertFalse(txn(kind: kind, amount: 4496, date: "2026-11-22").countsTowardSpending, "\(kind) must not count")
        }
    }

    // MARK: - Pending income accrues charity

    func testProvisionalIncomeAccruesCharity() {
        // The gap the owner noticed: charity did not count pending
        // income. It does now (trigger v4 + ingest hook).
        XCTAssertTrue(txn(kind: .income, amount: -10000, date: "2026-11-22", state: .provisional).accruesCharity)
    }

    func testVerifiedIncomeAccruesCharity() {
        XCTAssertTrue(txn(kind: .income, amount: -10000, date: "2026-11-22", state: .verified).accruesCharity)
    }

    func testExcludedIncomeDoesNotAccrueCharity() {
        // The auto-reverse: exclusion (or reclassification away)
        // removes the accrual.
        XCTAssertFalse(txn(kind: .income, amount: -10000, date: "2026-11-22", excluded: true).accruesCharity)
        XCTAssertFalse(txn(kind: .income, amount: -10000, date: "2026-11-22", state: .excluded).accruesCharity)
        XCTAssertFalse(txn(kind: .income, amount: -10000, date: "2026-11-22", state: .reversed).accruesCharity)
    }

    func testPreNovemberIncomeDoesNotAccrueCharity() {
        XCTAssertFalse(txn(kind: .income, amount: -10000, date: "2026-10-31", state: .verified).accruesCharity)
    }

    func testNonIncomeKindsDoNotAccrueCharity() {
        for kind in [TransactionKind.charge, .refund, .transfer, .payment, .cashback, .charity] {
            XCTAssertFalse(txn(kind: kind, amount: -10000, date: "2026-11-22", state: .verified).accruesCharity, "\(kind) must not accrue")
        }
    }

    func testZeroIncomeDoesNotAccrueCharity() {
        XCTAssertFalse(txn(kind: .income, amount: 0, date: "2026-11-22", state: .verified).accruesCharity)
    }

    // MARK: - Same-hash duplicates collapse to one row

    func testSameHashCollapsesToOneRow() {
        // The live $44.96 pair: two amex_alert rows, one hash.
        let first = txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .provisional, source: .amexAlert, dedupeHash: "hash-4496", createdAt: "2026-11-22T10:00:00Z")
        let second = txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .provisional, source: .amexAlert, dedupeHash: "hash-4496", createdAt: "2026-11-22T10:05:00Z")
        let kept = TransactionDedupe.byHash([first, second])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].id, first.id)
    }

    func testSameHashPrefersVerifiedOverProvisional() {
        // A bank row (verified) beats the provisional email row.
        let email = txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .provisional, source: .amexAlert, dedupeHash: "hash-4496", createdAt: "2026-11-22T10:00:00Z")
        let bank = txn(kind: .charge, amount: 4496, date: "2026-11-22", state: .verified, source: .plaid, dedupeHash: "hash-4496", createdAt: "2026-11-23T09:00:00Z")
        let kept = TransactionDedupe.byHash([email, bank])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].id, bank.id)
    }

    func testDifferentHashesAreAllKept() {
        let rows = [
            txn(kind: .charge, amount: 4496, date: "2026-11-22", dedupeHash: "hash-a"),
            txn(kind: .charge, amount: 1059, date: "2026-11-21", dedupeHash: "hash-b"),
            txn(kind: .charge, amount: 5723, date: "2026-11-21", dedupeHash: "hash-c"),
        ]
        XCTAssertEqual(TransactionDedupe.byHash(rows).count, 3)
    }

    func testEmptyHashRowsAreNeverCollapsed() {
        // No hash, no grouping: rows without a key always show.
        let rows = [
            txn(kind: .charge, amount: 4496, date: "2026-11-22", dedupeHash: ""),
            txn(kind: .charge, amount: 4496, date: "2026-11-22", dedupeHash: ""),
        ]
        XCTAssertEqual(TransactionDedupe.byHash(rows).count, 2)
    }

    func testDedupePreservesListOrder() {
        let a = txn(kind: .charge, amount: 100, date: "2026-11-22", dedupeHash: "hash-a")
        let b1 = txn(kind: .charge, amount: 200, date: "2026-11-21", state: .provisional, source: .amexAlert, dedupeHash: "hash-b", createdAt: "2026-11-21T10:00:00Z")
        let b2 = txn(kind: .charge, amount: 200, date: "2026-11-21", state: .verified, source: .plaid, dedupeHash: "hash-b", createdAt: "2026-11-22T09:00:00Z")
        let c = txn(kind: .charge, amount: 300, date: "2026-11-20", dedupeHash: "hash-c")
        let kept = TransactionDedupe.byHash([a, b1, b2, c])
        XCTAssertEqual(kept.map(\.id), [a.id, b2.id, c.id])
    }
}
