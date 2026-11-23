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
        fundAllocationCents: Int = 0,
        originalPurchaseId: UUID? = nil
    ) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: date, merchant: "WALMART",
                    amountCents: amount, cardSuffix: "1005", source: .plaid, state: state,
                    kind: kind, fundAllocationCents: fundAllocationCents, excluded: excluded, excludeReason: "",
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

    /// Build 64 (owner rule, Nov 23, 2026 — the list total must
    /// equal the server week total): one shared fixture covering
    /// all three owner-rule branches at once — a fund charge with
    /// a linked refund, a provisional (pending) refund, and a
    /// refund larger than its purchase (capped). A split purchase
    /// is impossible now (Cover with Savings is always the whole
    /// charge), so there is no fund-first partial portion to pin.
    ///
    /// Fixture: spending charge A $50.00; fund charge B $100.00
    /// (fully covered, allocation $100.00); spending charge C
    /// $30.00. Refund R1 −$20.00 linked to A, PROVISIONAL —
    /// counts right away under the owner rule (the server engine
    /// still excludes provisional refunds from C, so Home will
    /// match this only once the server is updated to the same
    /// rule). Refund R2 −$100.00 linked to B, verified — goes
    /// back to the fund, nets 0 against spending. Hidden refund
    /// R3 −$40.00 linked to C, verified — capped at C's $30.00.
    ///
    /// Expected week total: A 5000 − R1 2000 + B 0 − R2 0 + C
    /// 3000 − R3 capped 3000 = 3000. The same 3000 comes out
    /// whether the refunds are shown rows (status .all) or hidden
    /// linked amounts (week mode, spending-only list) — Home and
    /// Transactions compute the same total.
    func testOwnerRuleFundChargeProvisionalAndCappedRefunds() {
        let chargeA = txn(kind: .charge, amount: 5000, date: "2026-11-16")
        let fundChargeB = txn(kind: .fundCharge, amount: 10000, date: "2026-11-16", fundAllocationCents: 10000)
        let chargeC = txn(kind: .charge, amount: 3000, date: "2026-11-17")
        // R1: provisional refund on the spending charge — counts now.
        let refundR1 = txn(kind: .refund, amount: -2000, date: "2026-11-17", state: .provisional, originalPurchaseId: chargeA.id)
        // R2: verified refund on the fund charge — back to the fund.
        let refundR2 = txn(kind: .refund, amount: -10000, date: "2026-11-18", originalPurchaseId: fundChargeB.id)
        // R3: verified refund larger than its charge — capped at $30.
        let refundR3 = txn(kind: .refund, amount: -4000, date: "2026-11-18", originalPurchaseId: chargeC.id)
        let loaded = [chargeA, fundChargeB, chargeC, refundR1, refundR2, refundR3]

        // Status .all: every row shown, refunds net via the refund arm.
        let shownAll = [chargeA, fundChargeB, chargeC, refundR1, refundR2, refundR3]
        XCTAssertEqual(
            WeekTransactionsNetting.spendingTotal(shown: shownAll),
            3000
        )
        // Week mode: spending-only list; the refunds are hidden
        // linked amounts instead of rows — same total.
        let shownWeek = [chargeA, chargeC]
        let hidden = WeekTransactionsNetting.hiddenLinkedRefundAmounts(loaded: loaded, shown: shownWeek)
        XCTAssertEqual(hidden, [chargeA.id: 2000, chargeC.id: 4000])
        XCTAssertEqual(
            WeekTransactionsNetting.spendingTotal(shown: shownWeek, linkedRefundAmounts: hidden),
            3000
        )
        // The fund charge's refund marks it refunded, but its
        // amount never reaches the spending total.
        XCTAssertTrue(
            WeekTransactionsNetting.refundedChargeIds(loaded: loaded, shown: [fundChargeB]).contains(fundChargeB.id)
        )
        XCTAssertEqual(
            WeekTransactionsNetting.spendingTotal(shown: [fundChargeB], linkedRefundAmounts: [fundChargeB.id: 10000]),
            0
        )
    }
}
