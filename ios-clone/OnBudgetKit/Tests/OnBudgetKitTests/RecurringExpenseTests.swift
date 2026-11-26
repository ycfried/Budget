import XCTest
@testable import OnBudgetKit

/// Build 67 (owner, Nov 23, 2026): the "Expense" kind — a recurring
/// living cost (HOA, utilities, …) disconnected from weekly
/// spending. The live case: the $160.00 TIDEWATER PROPERTY
/// MANAGEMENT charge (posted Nov 23) is an HOA charge, not a
/// purchase — once tagged, the weekly "spent so far" must drop
/// from $266.95 to ~$106.95 and the balance back to ~$293.05.
/// These tests pin the client-side half of that rule (the
/// server half is compute-week's kind-gated C): an expense row
/// contributes 0 to the spending total, and the expense model
/// converts frequencies to monthly / weekly costs.
final class RecurringExpenseTests: XCTestCase {
    private func txn(
        kind: TransactionKind,
        amount: Int,
        date: String,
        state: TransactionState = .verified,
        excluded: Bool = false
    ) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: date, merchant: "TIDEWATER PROPERTY MANAGEMENT",
                    amountCents: amount, cardSuffix: "1636", source: .plaid, state: state,
                    kind: kind, fundAllocationCents: 0, excluded: excluded, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: "\(date)T00:00:00Z")
    }

    func testExpenseKindDecodesAndEncodes() throws {
        let decoded = try JSONDecoder().decode(TransactionKind.self, from: Data("\"expense\"".utf8))
        XCTAssertEqual(decoded, .expense)
        XCTAssertEqual(decoded.rawValue, "expense")
        let encoded = try JSONEncoder().encode(TransactionKind.expense)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"expense\"")
    }

    func testExpenseContributesZeroToSpendingTotal() {
        // The owner's live figures: $160.00 Tidewater + $106.95 of
        // other purchases = $266.95 spent. Tagging Tidewater as an
        // expense must leave only the $106.95 in the total.
        let expense = txn(kind: .expense, amount: 16000, date: "2026-11-23")
        let purchase = txn(kind: .charge, amount: 10695, date: "2026-11-23")
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: [expense, purchase]), 10695)
        XCTAssertEqual(WeekTransactionsNetting.spendingTotal(shown: [expense]), 0)
    }

    func testExpenseIsNotMoneyIn() {
        XCTAssertFalse(TransactionKind.expense.isMoneyIn)
    }

    func testMonthlyCentsByFrequency() {
        let household = UUID()
        let tx = UUID()
        func expense(amount: Int, frequency: ExpenseFrequency) -> RecurringExpense {
            RecurringExpense(id: UUID(), householdId: household, transactionId: tx,
                             name: "HOA", amountCents: amount, frequency: frequency)
        }
        // $160.00 a month stays $160.00 a month.
        XCTAssertEqual(expense(amount: 16000, frequency: .monthly).monthlyCents, 16000)
        // $160.00 a week is $160.00 × 52/12 a month — $693.33
        // (owner, Nov 26, 2026: the 4.33 divisor read $692.80).
        XCTAssertEqual(expense(amount: 16000, frequency: .weekly).monthlyCents, 69333)
        // $480.00 a quarter is $160.00 a month.
        XCTAssertEqual(expense(amount: 48000, frequency: .quarterly).monthlyCents, 16000)
        // $1,920.00 a year is $160.00 a month.
        XCTAssertEqual(expense(amount: 192000, frequency: .yearly).monthlyCents, 16000)
    }

    func testWeeklyCentsSpreadsMonthlyOver52Weeks() {
        let household = UUID()
        let expense = RecurringExpense(id: UUID(), householdId: household, transactionId: UUID(),
                                       name: "HOA", amountCents: 16000, frequency: .monthly)
        // $160.00 a month is $36.92 a week (160 × 12/52 — owner,
        // Nov 26, 2026: the 4.33 divisor read $36.95).
        XCTAssertEqual(expense.weeklyCents, 3692)
    }
}
