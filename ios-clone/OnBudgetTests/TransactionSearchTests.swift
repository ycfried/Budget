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
///
/// NOTE: `Transaction` has no public memberwise init (the app
/// decodes rows from Supabase JSON), so the fixture below decodes
/// a row from JSON instead of calling the init — the same shape
/// the app receives.
final class TransactionSearchTests: XCTestCase {
    private func txn(
        date: String = "2026-11-22",
        merchant: String,
        amount: Int = 10000
    ) throws -> Transaction {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "household_id": UUID().uuidString,
            "date": date,
            "merchant": merchant,
            "amount_cents": amount,
            "card_suffix": "1636",
            "source": "plaid",
            "state": "verified",
            "kind": "income",
            "fund_allocation_cents": 0,
            "excluded": false,
            "exclude_reason": "",
            "late": false,
            "external_id": NSNull(),
            "dedupe_hash": "h",
            "original_purchase_id": NSNull(),
            "pre_exclusion_state": NSNull(),
            "plaid_pending_transaction_id": NSNull(),
            "plaid_transaction_id": NSNull(),
            "created_at": "2026-11-22T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Transaction.self, from: data)
    }

    func testLowercaseQueryMatchesUppercaseMerchant() throws {
        // The owner's case: stored "YEHOSHUA FRIEDMAN", typed "yehoshua friedman".
        var filters = TransactionFilters()
        filters.search = "yehoshua friedman"
        let rows = [try txn(merchant: "YEHOSHUA FRIEDMAN")]
        XCTAssertEqual(filters.apply(to: rows).count, 1)
        XCTAssertEqual(filters.apply(to: rows).first?.merchant, "YEHOSHUA FRIEDMAN")
    }

    func testUppercaseQueryMatchesLowercaseMerchant() throws {
        // And vice versa: a lowercase-stored merchant matches an uppercase query.
        var filters = TransactionFilters()
        filters.search = "AVRAHAM FRIEDMAN"
        let rows = [try txn(merchant: "avraham friedman")]
        XCTAssertEqual(filters.apply(to: rows).count, 1)
        XCTAssertEqual(filters.apply(to: rows).first?.merchant, "avraham friedman")
    }

    func testMixedCaseQueryMatchesUppercaseMerchant() throws {
        // Title Case typed in the search field still finds the ALL CAPS row.
        var filters = TransactionFilters()
        filters.search = "Yehoshua Friedman"
        let rows = [try txn(merchant: "YEHOSHUA FRIEDMAN")]
        XCTAssertEqual(filters.apply(to: rows).count, 1)
    }

    func testLowercasePartialQueryMatchesBothCases() throws {
        // A lowercase substring finds every casing of the name.
        var filters = TransactionFilters()
        filters.search = "friedman"
        let rows = [
            try txn(date: "2026-11-22", merchant: "YEHOSHUA FRIEDMAN"),
            try txn(date: "2026-11-21", merchant: "avraham friedman"),
        ]
        XCTAssertEqual(filters.apply(to: rows).count, 2)
    }

    func testUnrelatedQueryStillMatchesNothing() throws {
        // Case-insensitivity must not turn the search into match-everything.
        var filters = TransactionFilters()
        filters.search = "zebra"
        let rows = [try txn(merchant: "YEHOSHUA FRIEDMAN")]
        XCTAssertEqual(filters.apply(to: rows).count, 0)
    }
}
