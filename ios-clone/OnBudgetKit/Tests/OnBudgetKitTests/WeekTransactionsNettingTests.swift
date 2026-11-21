import XCTest
@testable import OnBudgetKit

/// Build 53 (audit C6): the week-mode refund netting, extracted
/// into OnBudgetKit so the week's total has unit tests. The live
/// case that motivated it: the Walmart $24.16 charge, refunded in
/// the same week, must net to $0 in the week's total and show as
/// refunded — and a refund that posts in a LATER week must still
/// net its charge.
final class WeekTransactionsNettingTests: XCTestCase {
    private func txn(
        kind: TransactionKind,
        amount: Int,
        date: String,
        state: TransactionState = .verified,
        excluded: Bool = false,
        originalPurchaseId: UUID? = nil
    ) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: date, merchant: "WALMART",
                    amountCents: amount, cardSuffix: "1005", source: .plaid, state: state,
                    kind: kind, fundAllocationCents: 0, excluded: excluded, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: originalPurchaseId,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: "\(date)T00:00:00Z")
    }

    func testRefundedChargeNetsToZero() {
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let refund = txn(kind: .refund, amount: -2416, date: "2026-11-17", originalPurchaseId: charge.id)
        let loaded = [charge, refund]
        let shown = [charge]
        XCTAssertEqual(WeekTransactionsNetting.refundedChargeIds(loaded: loaded, shown: shown), [charge.id])
        XCTAssertEqual(WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown), [charge.id: 2416])
        XCTAssertEqual(
            WeekTransactionsNetting.spendingTotal(shown: shown, linkedRefundAmounts: [charge.id: 2416]),
            0
        )
    }

    func testRefundFromALaterWeekStillMarksItsCharge() {
        // The charge is in the week Nov 15–21; the refund posts Nov
        // 23, in the NEXT week. The week fetch pulls it in on
        // purpose (refundsFromDate) — the charge still nets to $0.
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let refund = txn(kind: .refund, amount: -2416, date: "2026-11-23", originalPurchaseId: charge.id)
        let loaded = [charge, refund]
        let shown = [charge]
        XCTAssertEqual(WeekTransactionsNetting.refundedChargeIds(loaded: loaded, shown: shown), [charge.id])
        XCTAssertEqual(
            WeekTransactionsNetting.spendingTotal(
                shown: shown,
                linkedRefundAmounts: WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown)
            ),
            0
        )
    }

    func testReversedRefundDoesNotMarkOrNet() {
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let refund = txn(kind: .refund, amount: -2416, date: "2026-11-17", state: .reversed, originalPurchaseId: charge.id)
        let loaded = [charge, refund]
        let shown = [charge]
        XCTAssertTrue(WeekTransactionsNetting.refundedChargeIds(loaded: loaded, shown: shown).isEmpty)
        XCTAssertTrue(WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown).isEmpty)
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: shown), 2416)
    }

    func testTrashedRefundDoesNotMarkOrNet() {
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let refund = txn(kind: .refund, amount: -2416, date: "2026-11-17", excluded: true, originalPurchaseId: charge.id)
        let loaded = [charge, refund]
        let shown = [charge]
        XCTAssertTrue(WeekTransactionsNetting.refundedChargeIds(loaded: loaded, shown: shown).isEmpty)
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: shown), 2416)
    }

    func testUnlinkedRefundMarksNothing() {
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let refund = txn(kind: .refund, amount: -2416, date: "2026-11-17", originalPurchaseId: nil)
        let loaded = [charge, refund]
        let shown = [charge]
        XCTAssertTrue(WeekTransactionsNetting.refundedChargeIds(loaded: loaded, shown: shown).isEmpty)
        XCTAssertTrue(WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown).isEmpty)
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: shown), 2416)
    }

    func testTwoRefundsForOneChargeSum() {
        let charge = txn(kind: .charge, amount: 5000, date: "2026-11-16")
        let refund1 = txn(kind: .refund, amount: -1000, date: "2026-11-17", originalPurchaseId: charge.id)
        let refund2 = txn(kind: .refund, amount: -500, date: "2026-11-18", originalPurchaseId: charge.id)
        let loaded = [charge, refund1, refund2]
        let shown = [charge]
        XCTAssertEqual(WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown), [charge.id: 1500])
        XCTAssertEqual(
            WeekTransactionsNetting.spendingTotal(
                shown: shown,
                linkedRefundAmounts: WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown)
            ),
            3500
        )
    }

    func testShownRefundIsNotDoubleCounted() {
        // A refund that IS in the shown list (e.g. status .all) is
        // already subtracted by the refund arm — it must not also
        // appear in the hidden amounts, or it would subtract twice.
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let refund = txn(kind: .refund, amount: -2416, date: "2026-11-17", originalPurchaseId: charge.id)
        let loaded = [charge, refund]
        let shown = [charge, refund]
        XCTAssertTrue(WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shown).isEmpty)
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: shown), 0)
    }

    func testChargeWithoutRefundIsUntouched() {
        let charge = txn(kind: .charge, amount: 2416, date: "2026-11-16")
        let other = txn(kind: .charge, amount: 1000, date: "2026-11-17")
        XCTAssertTrue(WeekTransactionsNetting.refundedChargeIds(loaded: [charge, other], shown: [charge, other]).isEmpty)
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: [charge, other]), 3416)
    }
}
