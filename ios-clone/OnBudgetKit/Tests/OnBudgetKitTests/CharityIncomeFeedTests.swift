// OnBudgetKitTests — CharityIncomeFeedTests.swift
//
// Build 55 (owner, Nov 22, 2026): two excluded income transactions
// (Yehoshua Friedman +$3,000.00, Avraham Friedman +$1,000.00) still
// appeared in the Tzedaka fund's Activity & Transactions list and
// still counted toward the Tzedaka figures — the committed total
// read $1,522.37 against the verified $1,122.37, a $400.00 gap that
// is exactly 10% of the $4,000 of excluded income. Exclusion is a
// separate action from reclassification: exclude_transaction sets
// excluded = true and state = 'excluded' but never changes kind, so
// the reclassify trigger (which fires only on a kind change) never
// reverses the accrual.
//
// The fix has two halves. The server half (trigger v3 in
// supabase/reclassify-income-accrual.sql) reverses the accrual when
// a transaction becomes excluded and re-accrues it when an income
// transaction is restored — that fixes the fund total at the source.
// The app half is pinned here: the charity feed hides an accrual
// whose linked transaction is excluded
// (CharityIncome.visibleIncomeRows), so an excluded income row
// cannot read as live income in the list either.
//
// What these tests CANNOT prove: that the server trigger actually
// reverses the row on exclude — that needs the test-household SQL
// verification in the v3 file's verification section, run against a
// live database. These tests pin only the app-side feed rule.

import XCTest
@testable import OnBudgetKit

final class CharityIncomeFeedTests: XCTestCase {

    private func incomeRow(
        sourceLabel: String,
        amountCents: Int,
        status: String = "active",
        transactionId: UUID? = nil
    ) -> CharityIncome {
        CharityIncome(
            id: UUID(), householdId: UUID(), sourceLabel: sourceLabel,
            amountCents: amountCents, incomeDate: "2026-11-22", rateBp: 1000,
            status: status, replacesId: nil, note: "Auto-accrued from synced income",
            createdBy: nil, createdAt: nil, transactionId: transactionId
        )
    }

    private func incomeTransaction(
        id: UUID,
        merchant: String,
        amountCents: Int,
        excluded: Bool
    ) -> Transaction {
        Transaction(
            id: id, householdId: UUID(), date: "2026-11-22", merchant: merchant,
            amountCents: amountCents, cardSuffix: "1636", source: .plaid, state: excluded ? .excluded : .verified,
            kind: .income, fundAllocationCents: 0, excluded: excluded, excludeReason: excluded ? "not income" : "",
            late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
            preExclusionState: nil, plaidPendingTransactionId: nil,
            plaidTransactionId: nil, createdAt: "2026-11-22T00:00:00Z"
        )
    }

    func testExcludedIncomeRowIsHiddenFromFeed() {
        // The owner's live case, reduced: the Yehoshua Friedman
        // +$3,000 Zelle is excluded, so its $300 accrual must not
        // appear in the feed.
        let txnId = UUID()
        let income = [incomeRow(sourceLabel: "Yehoshua Friedman", amountCents: 300000, transactionId: txnId)]
        let txns = [incomeTransaction(id: txnId, merchant: "Yehoshua Friedman", amountCents: -300000, excluded: true)]
        XCTAssertTrue(CharityIncome.visibleIncomeRows(income, allTransactions: txns).isEmpty)
    }

    func testLiveIncomeRowStaysVisible() {
        let txnId = UUID()
        let income = [incomeRow(sourceLabel: "Cheder", amountCents: 41557, transactionId: txnId)]
        let txns = [incomeTransaction(id: txnId, merchant: "Online Transfer / Payment: Credit", amountCents: -41557, excluded: false)]
        XCTAssertEqual(CharityIncome.visibleIncomeRows(income, allTransactions: txns).count, 1)
    }

    func testUnlinkedIncomeRowIsNeverHidden() {
        // Manual income and unlinked backfills (e.g. the $7,000
        // check deposit's unlinked row) have no transaction to be
        // excluded through, so the rule cannot hide them.
        let income = [incomeRow(sourceLabel: "Mobile Check Deposit", amountCents: 700000, transactionId: nil)]
        XCTAssertEqual(CharityIncome.visibleIncomeRows(income, allTransactions: []).count, 1)
    }

    func testReversedRowStaysVisibleWhenTransactionIsNotExcluded() {
        // A reclassification away from income reverses the accrual
        // but the row stays in the feed marked "(Reversed)" — that
        // is the audit trail for the correction, not an exclusion.
        let txnId = UUID()
        let income = [incomeRow(sourceLabel: "Pay", amountCents: 10000, status: "reversed", transactionId: txnId)]
        let txns = [incomeTransaction(id: txnId, merchant: "Pay", amountCents: -10000, excluded: false)]
        XCTAssertEqual(CharityIncome.visibleIncomeRows(income, allTransactions: txns).count, 1)
    }

    func testReversedRowIsHiddenWhenTransactionIsExcluded() {
        // Once the server reverses the accrual on exclude, the row
        // is status='reversed' AND its transaction is excluded —
        // the feed hides it outright rather than showing it as
        // "(Reversed)": excluded means not part of the budget.
        let txnId = UUID()
        let income = [incomeRow(sourceLabel: "Avraham Friedman", amountCents: 100000, status: "reversed", transactionId: txnId)]
        let txns = [incomeTransaction(id: txnId, merchant: "Avraham Friedman", amountCents: -100000, excluded: true)]
        XCTAssertTrue(CharityIncome.visibleIncomeRows(income, allTransactions: txns).isEmpty)
    }

    func testLiveHouseholdCaseOnlyLiveIncomeRemains() {
        // The full live case: both excluded Zelles ($3,000 +
        // $1,000) plus one live Cheder credit. Only the live
        // credit survives the feed — the $400 of charity the owner
        // saw in the total is gone from the list with it.
        let zelle3000 = UUID()
        let zelle1000 = UUID()
        let cheder = UUID()
        let income = [
            incomeRow(sourceLabel: "Yehoshua Friedman", amountCents: 300000, transactionId: zelle3000),
            incomeRow(sourceLabel: "Avraham Friedman", amountCents: 100000, transactionId: zelle1000),
            incomeRow(sourceLabel: "Cheder", amountCents: 41557, transactionId: cheder),
        ]
        let txns = [
            incomeTransaction(id: zelle3000, merchant: "Yehoshua Friedman", amountCents: -300000, excluded: true),
            incomeTransaction(id: zelle1000, merchant: "Avraham Friedman", amountCents: -100000, excluded: true),
            incomeTransaction(id: cheder, merchant: "Online Transfer / Payment: Credit", amountCents: -41557, excluded: false),
        ]
        let visible = CharityIncome.visibleIncomeRows(income, allTransactions: txns)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.sourceLabel, "Cheder")
    }
}
