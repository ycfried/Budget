import XCTest
@testable import OnBudget
import OnBudgetKit

/// Case-insensitive search (owner, Nov 22, 2026 — build 56:
/// "Searches shouldn't be caps lock sensitive"). The database
/// stores merchant names in ALL CAPS (e.g. "YEHOSHUA FRIEDMAN"),
/// so a case-sensitive lookup misses them. `TransactionFilters`
/// already lowercases both sides (`apply(to:)` in
/// TransactionFormatting.swift: the query is lowercased and the
/// merchant match is `tx.merchant.lowercased().contains(query)`);
/// these tests pin that behaviour so a future change cannot
/// reintroduce caps sensitivity. The bank/email dedupe merge is a
/// separate path (it normalizes with UPPER + strip
/// non-alphanumeric) and is NOT covered here — no fuzzy matching.
final class TransactionSearchTests: XCTestCase {
    private func txn(
        date: String = "2026-11-22",
        merchant: String,
        amount: Int = 10000,
        createdAt: String = "2026-11-22T00:00:00Z"
    ) -> Transaction {
        Transaction(id: UUID(), householdId: UUID(), date: date, merchant: merchant,
                    amountCents: amount, cardSuffix: "1636", source: .plaid, state: .verified,
                    kind: .income, fundAllocationCents: 0, excluded: false, excludeReason: "",
                    late: false, externalId: nil, dedupeHash: "h", originalPurchaseId: nil,
                    preExclusionState: nil, plaidPendingTransactionId: nil,
                    plaidTransactionId: nil, createdAt: createdAt)
    }

    func testLowercaseQueryMatchesUppercaseMerchant() {
        // The owner's case: stored "YEHOSHUA FRIEDMAN", typed "yehoshua friedman".
        var filters = TransactionFilters()
        filters.search = "yehoshua friedman"
        let rows = [txn(merchant: "YEHOSHUA FRIEDMAN")]
        XCTAssertEqual(filters.apply(to: rows).count, 1)
        XCTAssertEqual(filters.apply(to: rows).first?.merchant, "YEHOSHUA FRIEDMAN")
    }

    func testUppercaseQueryMatchesLowercaseMerchant() {
        // And vice versa: a lowercase-stored merchant matches an uppercase query.
        var filters = TransactionFilters()
        filters.search = "AVRAHAM FRIEDMAN"
        let rows = [txn(merchant: "avraham friedman")]
        XCTAssertEqual(filters.apply(to: rows).count, 1)
        XCTAssertEqual(filters.apply(to: rows).first?.merchant, "avraham friedman")
    }

    func testMixedCaseQueryMatchesUppercaseMerchant() {
        // Title Case typed in the search field still finds the ALL CAPS row.
        var filters = TransactionFilters()
        filters.search = "Yehoshua Friedman"
        let rows = [txn(merchant: "YEHOSHUA FRIEDMAN")]
        XCTAssertEqual(filters.apply(to: rows).count, 1)
    }

    func testLowercasePartialQueryMatchesBothCases() {
        // A lowercase substring finds every casing of the name.
        var filters = TransactionFilters()
        filters.search = "friedman"
        let rows = [
            txn(date: "2026-11-22", merchant: "YEHOSHUA FRIEDMAN"),
            txn(date: "2026-11-21", merchant: "avraham friedman"),
        ]
        XCTAssertEqual(filters.apply(to: rows).count, 2)
    }

    func testUnrelatedQueryStillMatchesNothing() {
        // Case-insensitivity must not turn the search into match-everything.
        var filters = TransactionFilters()
        filters.search = "zebra"
        let rows = [txn(merchant: "YEHOSHUA FRIEDMAN")]
        XCTAssertEqual(filters.apply(to: rows).count, 0)
    }
}
