import XCTest
@testable import OnBudget
import OnBudgetKit

/// Export filter picker (build 61, Nov 22, 2026 — owner: "Once
/// choosing filtered you should have to select how to filter"):
/// the shared `TransactionFilters` gains a kind pick, and the
/// Export sheet's draft is that same filter — kind, date range,
/// amount, and account narrow the export set, combine (AND), and
/// no filters means every transaction. These tests pin the filter
/// math (the app side); the kit's generator is already pinned to
/// export exactly the rows it is given, and the preview renders
/// that same file — so a filtered count here is a filtered file
/// and a filtered preview.
///
/// NOTE: `Transaction` has no public memberwise init (the app
/// decodes rows from Supabase JSON), so the fixture below decodes
/// a row from JSON instead of calling the init — the same shape
/// the app receives.
final class TransactionExportFilterTests: XCTestCase {
    private func txn(
        date: String = "2026-11-22",
        merchant: String = "AMAZON",
        amount: Int = 10000,
        suffix: String = "1005",
        state: String = "verified",
        kind: String = "charge"
    ) throws -> Transaction {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "household_id": UUID().uuidString,
            "date": date,
            "merchant": merchant,
            "amount_cents": amount,
            "card_suffix": suffix,
            "source": "plaid",
            "state": state,
            "kind": kind,
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

    /// One row per concrete kind, so each kind pick can be shown
    /// to keep exactly its own row.
    private func oneOfEachKind() throws -> [Transaction] {
        [
            try txn(merchant: "AMAZON", amount: 10000, kind: "charge"),
            try txn(merchant: "CHECK DEPOSIT", amount: -300000, kind: "income"),
            try txn(merchant: "TOIREMORG", amount: 100, kind: "charity"),
            try txn(merchant: "NORDSTROM", amount: -2500, kind: "refund"),
            try txn(merchant: "TRANSFER TO", amount: 10000, kind: "transfer"),
            try txn(merchant: "AMEX PAYMENT", amount: 50000, kind: "payment"),
            try txn(merchant: "AMEX CASHBACK", amount: -500, kind: "cashback"),
            try txn(merchant: "EXTRA FUND", amount: 2000, kind: "fund_charge"),
        ]
    }

    // MARK: - No filters = all transactions

    func testNoFiltersReturnsEveryRow() throws {
        let rows = try oneOfEachKind()
        let result = TransactionFilters().apply(to: rows)
        XCTAssertEqual(result.count, rows.count)
        XCTAssertEqual(Set(result.map(\.merchant)), Set(rows.map(\.merchant)))
    }

    // MARK: - Kind

    func testKindFilterKeepsOnlyThatKind() throws {
        let rows = try oneOfEachKind()
        let kinds: [(TransactionKind, String)] = [
            (.charge, "AMAZON"), (.income, "CHECK DEPOSIT"), (.charity, "TOIREMORG"),
            (.refund, "NORDSTROM"), (.transfer, "TRANSFER TO"), (.payment, "AMEX PAYMENT"),
            (.cashback, "AMEX CASHBACK"), (.fundCharge, "EXTRA FUND"),
        ]
        for (kind, merchant) in kinds {
            var filters = TransactionFilters()
            filters.kind = kind
            let result = filters.apply(to: rows)
            XCTAssertEqual(result.count, 1, "kind \(kind) should keep exactly one row")
            XCTAssertEqual(result.first?.merchant, merchant)
        }
    }

    func testOtherKindMatchesOnlyUnderAnyKind() throws {
        // An unlisted kind (`.other`) is never offered by the
        // picker — it matches only when no kind is picked.
        let rows = [
            try txn(merchant: "MYSTERY", kind: "something_new"),
            try txn(merchant: "AMAZON", kind: "charge"),
        ]
        XCTAssertEqual(TransactionFilters().apply(to: rows).count, 2)
        var filters = TransactionFilters()
        filters.kind = .charge
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "AMAZON")
    }

    func testKindPickClearsAKindishStatus() throws {
        // A kind of Income with a Spending status would AND to
        // nothing — setKind clears the kind-ish status, so the
        // pick the user just made is the one that applies.
        var filters = TransactionFilters()
        filters.status = .spending
        filters.setKind(.income)
        XCTAssertEqual(filters.kind, .income)
        XCTAssertEqual(filters.status, .all)
        let rows = try oneOfEachKind()
        XCTAssertEqual(filters.apply(to: rows).count, 1)
        XCTAssertEqual(filters.apply(to: rows).first?.merchant, "CHECK DEPOSIT")
    }

    func testKindPickLeavesAStateStatusAlone() throws {
        // Pending / Posted are states, not kinds — they compose
        // with a kind pick instead of being cleared.
        var filters = TransactionFilters()
        filters.status = .pending
        filters.setKind(.charge)
        XCTAssertEqual(filters.status, .pending)
        let rows = [
            try txn(merchant: "AMAZON", state: "provisional", kind: "charge"),
            try txn(merchant: "WALMART", state: "verified", kind: "charge"),
        ]
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "AMAZON")
    }

    func testPickingAllKindsLeavesStatusAlone() throws {
        var filters = TransactionFilters()
        filters.status = .charity
        filters.setKind(nil)
        XCTAssertNil(filters.kind)
        XCTAssertEqual(filters.status, .charity)
    }

    func testKindChipAndClear() throws {
        var filters = TransactionFilters()
        XCTAssertFalse(filters.isSearchOrFilterActive)
        filters.kind = .income
        XCTAssertTrue(filters.isSearchOrFilterActive)
        let chips = filters.activeChips(customNames: [:])
        XCTAssertTrue(chips.contains { $0.key == "kind" && $0.label == "Income" })
        filters.clearChip("kind")
        XCTAssertNil(filters.kind)
        XCTAssertFalse(filters.activeChips(customNames: [:]).contains { $0.key == "kind" })
    }

    // MARK: - Date range

    func testDateRangeKeepsOnlyInRange() throws {
        let rows = [
            try txn(date: "2026-11-01", merchant: "FIRST"),
            try txn(date: "2026-11-10", merchant: "MIDDLE"),
            try txn(date: "2026-11-20", merchant: "LAST"),
        ]
        var filters = TransactionFilters()
        filters.setWhenSelection(.custom(from: "2026-11-05", to: "2026-11-15"))
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "MIDDLE")
    }

    func testOneSidedDateRange() throws {
        let rows = [
            try txn(date: "2026-11-01", merchant: "FIRST"),
            try txn(date: "2026-11-10", merchant: "MIDDLE"),
            try txn(date: "2026-11-20", merchant: "LAST"),
        ]
        var fromOnly = TransactionFilters()
        fromOnly.setFromDate("2026-11-10")
        XCTAssertEqual(fromOnly.apply(to: rows).map(\.merchant).sorted(), ["LAST", "MIDDLE"])
        var toOnly = TransactionFilters()
        toOnly.setToDate("2026-11-10")
        XCTAssertEqual(toOnly.apply(to: rows).map(\.merchant).sorted(), ["FIRST", "MIDDLE"])
    }

    func testThisWeekAndThisMonthAreDateRanges() throws {
        // The When quick picks are date choices too — This Week
        // holds the week in `weekOnly` (the bounds are computed
        // in `apply`), This Month in `month`; neither is a
        // separate filter path, and the single When choice reads
        // back as the pick.
        var week = TransactionFilters()
        week.setWhenSelection(.thisWeek)
        XCTAssertTrue(week.weekOnly)
        XCTAssertTrue(week.fromDate.isEmpty)
        XCTAssertEqual(week.whenSelection, .thisWeek)
        var month = TransactionFilters()
        month.setWhenSelection(.thisMonth)
        XCTAssertEqual(month.month, TransactionFormatting.currentMonthString())
        XCTAssertEqual(month.whenSelection, .thisMonth)
    }

    // MARK: - Amount range

    func testAmountMinKeepsOnlyAtOrAbove() throws {
        let rows = [
            try txn(merchant: "SMALL", amount: 500),
            try txn(merchant: "MEDIUM", amount: 10000),
            try txn(merchant: "LARGE", amount: 50000),
        ]
        var filters = TransactionFilters()
        filters.minCents = 10000
        XCTAssertEqual(filters.apply(to: rows).map(\.merchant).sorted(), ["LARGE", "MEDIUM"])
    }

    func testAmountMaxKeepsOnlyAtOrBelow() throws {
        let rows = [
            try txn(merchant: "SMALL", amount: 500),
            try txn(merchant: "MEDIUM", amount: 10000),
            try txn(merchant: "LARGE", amount: 50000),
        ]
        var filters = TransactionFilters()
        filters.maxCents = 10000
        XCTAssertEqual(filters.apply(to: rows).map(\.merchant).sorted(), ["MEDIUM", "SMALL"])
    }

    func testAmountBetweenKeepsOnlyInside() throws {
        let rows = [
            try txn(merchant: "SMALL", amount: 500),
            try txn(merchant: "MEDIUM", amount: 10000),
            try txn(merchant: "LARGE", amount: 50000),
        ]
        var filters = TransactionFilters()
        filters.minCents = 1000
        filters.maxCents = 20000
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "MEDIUM")
    }

    func testAmountBoundsCompareToTheSignedAmount() throws {
        // The bounds compare to the SIGNED amount, same as the
        // list's filter: a $100 minimum keeps a $150 charge but
        // drops a $3,000 income (stored negative). The export
        // reuses this rule exactly — it never invents a second
        // amount semantics.
        let rows = [
            try txn(merchant: "CHARGE", amount: 15000, kind: "charge"),
            try txn(merchant: "INCOME", amount: -300000, kind: "income"),
        ]
        var filters = TransactionFilters()
        filters.minCents = 10000
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "CHARGE")
    }

    func testMinAboveMaxIsAnEmptyValidationState() throws {
        // min > max returns no rows (the sheet shows the
        // validation error instead of an empty file).
        var filters = TransactionFilters()
        filters.minCents = 20000
        filters.maxCents = 10000
        XCTAssertTrue(filters.amountRangeInvalid)
        XCTAssertEqual(filters.apply(to: [try txn()]).count, 0)
    }

    // MARK: - Account (card)

    func testCardFilterKeepsOnlyThatAccount() throws {
        let rows = [
            try txn(merchant: "AMEX CARD", suffix: "1005"),
            try txn(merchant: "CHECKING", suffix: "1636"),
            try txn(merchant: "SAVINGS", suffix: "5939"),
        ]
        var filters = TransactionFilters()
        filters.card = "1636"
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "CHECKING")
    }

    func testCardsInHistoryListsEverySuffix() throws {
        let rows = [
            try txn(merchant: "A", suffix: "5939"),
            try txn(merchant: "B", suffix: "1005"),
            try txn(merchant: "C", suffix: "1005"),
        ]
        XCTAssertEqual(TransactionFilters.cards(in: rows), ["1005", "5939"])
    }

    // MARK: - Combinations intersect

    func testKindPlusCardIntersects() throws {
        let rows = [
            try txn(merchant: "AMAZON 1005", suffix: "1005", kind: "charge"),
            try txn(merchant: "AMAZON 1636", suffix: "1636", kind: "charge"),
            try txn(merchant: "INCOME 1005", suffix: "1005", kind: "income"),
        ]
        var filters = TransactionFilters()
        filters.kind = .charge
        filters.card = "1636"
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "AMAZON 1636")
    }

    func testKindPlusDatePlusAmountPlusCardIntersects() throws {
        // All four picks together: the intersection, not the union.
        let rows = [
            try txn(date: "2026-11-10", merchant: "TARGET", amount: 15000, suffix: "1005", kind: "charge"),
            try txn(date: "2026-11-10", merchant: "TARGET OLD CARD", amount: 15000, suffix: "1636", kind: "charge"),
            try txn(date: "2026-11-01", merchant: "TARGET OLD DATE", amount: 15000, suffix: "1005", kind: "charge"),
            try txn(date: "2026-11-10", merchant: "TARGET CHEAP", amount: 500, suffix: "1005", kind: "charge"),
            try txn(date: "2026-11-10", merchant: "TARGET INCOME", amount: -15000, suffix: "1005", kind: "income"),
        ]
        var filters = TransactionFilters()
        filters.kind = .charge
        filters.card = "1005"
        filters.setWhenSelection(.custom(from: "2026-11-05", to: "2026-11-15"))
        filters.minCents = 10000
        filters.maxCents = 20000
        let result = filters.apply(to: rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.merchant, "TARGET")
    }

    func testExcludedRowsNeverMatchAnyFilter() throws {
        // A filter can never resurrect a trashed row.
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "household_id": UUID().uuidString,
            "date": "2026-11-10",
            "merchant": "TRASHED",
            "amount_cents": 15000,
            "card_suffix": "1005",
            "source": "plaid",
            "state": "verified",
            "kind": "charge",
            "fund_allocation_cents": 0,
            "excluded": true,
            "exclude_reason": "duplicate",
            "late": false,
            "external_id": NSNull(),
            "dedupe_hash": "h",
            "original_purchase_id": NSNull(),
            "pre_exclusion_state": NSNull(),
            "plaid_pending_transaction_id": NSNull(),
            "plaid_transaction_id": NSNull(),
            "created_at": "2026-11-10T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let trashed = try JSONDecoder().decode(Transaction.self, from: data)
        var filters = TransactionFilters()
        filters.kind = .charge
        filters.card = "1005"
        XCTAssertEqual(filters.apply(to: [trashed]).count, 0)
    }
}
