import XCTest
@testable import OnBudgetKit

/// The one shared kind→colour amount rule (owner, Nov 12, 2026):
/// money-in kinds (income / refund / cashback) render green with a
/// "+" prefix; charity renders blue; regular kinds render ink; red
/// is never a transaction amount. The KIND, not the stored sign,
/// decides — a negative charge still renders ink with its minus.
final class InflowAmountTests: XCTestCase {
    private func txn(kind: TransactionKind, amount: Int) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: "2026-11-11", merchant: "CHECK DEPOSIT",
                    amountCents: amount, cardSuffix: "0000", source: .plaid, state: .verified,
                    kind: kind, fundAllocationCents: 0, excluded: false, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: "2026-11-11T00:00:00Z")
    }

    func testMoneyInKinds() {
        XCTAssertTrue(TransactionKind.income.isMoneyIn)
        XCTAssertTrue(TransactionKind.refund.isMoneyIn)
        XCTAssertTrue(TransactionKind.cashback.isMoneyIn)
        XCTAssertFalse(TransactionKind.charge.isMoneyIn)
        XCTAssertFalse(TransactionKind.payment.isMoneyIn)
        XCTAssertFalse(TransactionKind.transfer.isMoneyIn)
        XCTAssertFalse(TransactionKind.fundCharge.isMoneyIn)
        XCTAssertFalse(TransactionKind.charity.isMoneyIn)
        XCTAssertFalse(TransactionKind.other("mystery").isMoneyIn)
    }

    func testMoneyInKindNamesAreExactlyTheThree() {
        XCTAssertEqual(TransactionKind.moneyInKindNames, ["income", "refund", "cashback"])
    }

    func testTransactionIsInflowIsKindBasedNotSignBased() {
        // The owner's screenshot case: a check deposit stored as
        // negative Plaid cents, kind income — an inflow.
        XCTAssertTrue(txn(kind: .income, amount: -7500).isInflow)
        XCTAssertTrue(txn(kind: .refund, amount: -2500).isInflow)
        XCTAssertTrue(txn(kind: .cashback, amount: -100).isInflow)
        // A negative charge is money in by sign, but the KIND
        // decides: it stays a regular (ink) row.
        XCTAssertFalse(txn(kind: .charge, amount: -7500).isInflow)
        XCTAssertFalse(txn(kind: .transfer, amount: -7500).isInflow)
        XCTAssertFalse(txn(kind: .charity, amount: 200).isInflow)
    }

    func testAmountTextFlipsTheStoredMinusToPlusForMoneyIn() {
        XCTAssertEqual(MoneyFormat.amountText(cents: -7500, isMoneyIn: true), "+$75.00")
        XCTAssertEqual(MoneyFormat.amountText(cents: -2500, isMoneyIn: true), "+$25.00")
        XCTAssertEqual(MoneyFormat.amountText(cents: -100, isMoneyIn: true), "+$1.00")
        // A money-in kind stored positive (should not happen from
        // Plaid) still reads as money in.
        XCTAssertEqual(MoneyFormat.amountText(cents: 7500, isMoneyIn: true), "+$75.00")
    }

    func testAmountTextKeepsTheStoredSignForOtherKinds() {
        XCTAssertEqual(MoneyFormat.amountText(cents: 5000, isMoneyIn: false), "$50.00")
        XCTAssertEqual(MoneyFormat.amountText(cents: -5000, isMoneyIn: false), "-$50.00")
        XCTAssertEqual(MoneyFormat.amountText(cents: 200, isMoneyIn: false), "$2.00")
    }

    func testAmountTextZeroIsPlainForEveryKind() {
        XCTAssertEqual(MoneyFormat.amountText(cents: 0, isMoneyIn: true), "$0.00")
        XCTAssertEqual(MoneyFormat.amountText(cents: 0, isMoneyIn: false), "$0.00")
    }

    func testNetTotalText() {
        // A negative list total is net money in for the filter.
        XCTAssertEqual(MoneyFormat.netTotalText(cents: -5019), "+$50.19")
        XCTAssertEqual(MoneyFormat.netTotalText(cents: 12345), "$123.45")
        XCTAssertEqual(MoneyFormat.netTotalText(cents: 0), "$0.00")
    }
}
