import XCTest
@testable import OnBudgetKit

/// Transfer row titles (build 50, Nov 20, 2026): the row title is
/// ALWAYS the merchant name — a transfer used to show the derived
/// transfer title ("Transfer to ••5939", or a bare "Transfer to"
/// with no destination), which hid the merchant. The owner
/// reclassified a -$1,986 Erie Insurance row as a Transfer and
/// the list read "Transfer to" instead of the merchant.
final class TransactionTitlesTests: XCTestCase {
    private func txn(merchant: String, amount: Int, kind: TransactionKind, cardSuffix: String = "1005") -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: "2026-11-20", merchant: merchant,
                    amountCents: amount, cardSuffix: cardSuffix, source: .plaid, state: .provisional,
                    kind: kind, fundAllocationCents: 0, excluded: false, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: "2026-11-20T00:00:00Z")
    }

    func testRowTitleKeepsMerchantForTransfers() {
        // The owner's exact case: -$1,986 Erie Insurance,
        // reclassified as a Transfer. The row must read the
        // merchant, never "Transfer to".
        let erie = txn(merchant: "Erie Insurance", amount: 198600, kind: .transfer)
        XCTAssertEqual(TransactionTitles.rowTitle(for: erie), "Erie Insurance")
        // A bank transfer with digits in the description also
        // keeps its merchant name on the row.
        let savings = txn(merchant: "Internal Transfer Credit: Savings -5939", amount: -200000, kind: .transfer)
        XCTAssertEqual(TransactionTitles.rowTitle(for: savings), "Internal Transfer Credit: Savings -5939")
        // Non-transfers are unchanged.
        XCTAssertEqual(TransactionTitles.rowTitle(for: txn(merchant: "WALMART", amount: 2416, kind: .charge)), "Walmart")
    }

    func testTransferDetailTextShowsDirectionAndAccount() {
        // With derivable digits, the detail shows direction +
        // other account.
        let savings = txn(merchant: "Internal Transfer Credit: Savings -5939", amount: -200000, kind: .transfer)
        XCTAssertEqual(TransactionTitles.transferDetailText(for: savings), "Transfer from ••5939")
        let out = txn(merchant: "Transfer to Savings -1636", amount: 50000, kind: .transfer, cardSuffix: "1005")
        XCTAssertEqual(TransactionTitles.transferDetailText(for: out), "Transfer to ••1636")
    }

    func testTransferDetailTextNeverDangles() {
        // No derivable digits → bare "Transfer", never a dangling
        // "Transfer to" / "Transfer from" with no destination.
        let erie = txn(merchant: "Erie Insurance", amount: 198600, kind: .transfer)
        XCTAssertEqual(TransactionTitles.transferDetailText(for: erie), "Transfer")
        XCTAssertEqual(TransactionTitles.transferTitle(for: erie), "Transfer to")
    }
}
