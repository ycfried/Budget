import Foundation
import XCTest
@testable import OnBudgetKit

/// Funds / Review / Trash read shapes (Nov 9, 2026, funds workstream).
///
/// Several `PostgrestClient` reads selected fewer columns than their
/// model's non-optional fields, so `JSONDecoder` threw `keyNotFound`
/// on every real row (verified with a scratch decode: a
/// `duplicate_candidates` row without `status`/`created_at` fails).
/// The column lists were widened to include every non-optional field;
/// each test below decodes its model from JSON containing exactly the
/// columns its fixed query selects, so a future narrowing fails here
/// instead of on a live screen.
final class FundsReadDecodingTests: XCTestCase {
    private let householdId = "22222222-2222-2222-2222-222222222222"

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testFundLedgerDecodesFromFixedColumns() throws {
        let row = try decode(FundLedgerEntry.self, """
            {"household_id":"\(householdId)","kind":"release","amount_cents":5000,"note":""}
            """)
        XCTAssertEqual(row.kind, "release")
        XCTAssertEqual(row.amountCents, 5000)
    }

    func testSurplusReleasesDecodeFromFixedColumns() throws {
        let rows = try decode([SurplusRelease].self, """
            [{"household_id":"\(householdId)","week_start":"2026-11-01","surplus_cents":1200,"release_date":"2026-11-09","status":"pending","released_cents":0}]
            """)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, "pending")
    }

    func testFundTopupsDecodeFromFixedColumns() throws {
        let rows = try decode([FundTopup].self, """
            [{"household_id":"\(householdId)","client_key":"k1","amount_cents":10000,"shortfall_covered_cents":4000,"fund_added_cents":6000,"shortfall_after_cents":0,"note":"","created_at":"2026-11-09T12:00:00Z"}]
            """)
        XCTAssertEqual(rows[0].fundAddedCents, 6000)
    }

    func testCharityIncomeDecodesFromFixedColumns() throws {
        let rows = try decode([CharityIncome].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId)","source_label":"Paycheck","amount_cents":100000,"income_date":"2026-11-06","rate_bp":1000,"status":"active","note":""}]
            """)
        XCTAssertEqual(rows[0].committedCents, 10000)
    }

    func testCharitySettingsDecodesFromFixedColumns() throws {
        let row = try decode(CharitySettings.self, """
            {"household_id":"\(householdId)","default_rate_bp":1000}
            """)
        XCTAssertEqual(row.defaultRateBp, 1000)
    }

    func testPendingDuplicateCandidatesDecodeFromFixedColumns() throws {
        let rows = try decode([DuplicateCandidate].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId)","canonical_transaction_id":"33333333-3333-3333-3333-333333333333","duplicate_transaction_id":"44444444-4444-4444-4444-444444444444","reason":"lookalike","merchant_a":"AMAZON","merchant_b":"AMAZON MARKETPLACE","status":"pending","created_at":"2026-11-09T12:00:00Z"}]
            """)
        XCTAssertEqual(rows[0].status, "pending")
    }

    func testResolvedDuplicateCandidatesDecodeFromFixedColumns() throws {
        let rows = try decode([DuplicateCandidate].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId)","canonical_transaction_id":"33333333-3333-3333-3333-333333333333","duplicate_transaction_id":"44444444-4444-4444-4444-444444444444","reason":"lookalike","merchant_a":"AMAZON","merchant_b":"AMAZON MARKETPLACE","status":"separate","created_at":"2026-11-08T12:00:00Z","resolved_at":"2026-11-09T12:00:00Z"}]
            """)
        XCTAssertEqual(rows[0].status, "separate")
    }

    func testMerchantAliasesDecodeFromFixedColumns() throws {
        let rows = try decode([MerchantAlias].self, """
            [{"household_id":"\(householdId)","name_a":"AMAZON","name_b":"AMAZON MARKETPLACE"}]
            """)
        XCTAssertEqual(rows[0].nameA, "AMAZON")
    }

    func testMerchantRulesDecodeFromFixedColumns() throws {
        let rows = try decode([MerchantRule].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId)","pattern_text":"BALTIMORE GAS AND ELECTRIC COMPANY","match_type":"exact","display_name":"BGE","fixed_kind":null,"created_at":"2026-11-15T12:00:00Z"},{"id":"22222222-2222-2222-2222-222222222222","household_id":"\(householdId)","pattern_text":"TOIREMORG","match_type":"prefix","display_name":"TOIREMORG","fixed_kind":"charity","created_at":"2026-11-15T12:00:00Z"}]
            """)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].displayName, "BGE")
        XCTAssertNil(rows[0].fixedKind)
        // Build 34: the server renamed 'prefix' to 'includes' — a
        // pre-migration 'prefix' row still decodes, as "includes".
        XCTAssertEqual(rows[1].matchType, "includes")
        XCTAssertEqual(rows[1].fixedKind, "charity")
    }

    func testRefundLinkDismissalsDecodeFromFixedColumns() throws {
        let rows = try decode([RefundLinkDismissal].self, """
            [{"household_id":"\(householdId)","refund_id":"11111111-1111-1111-1111-111111111111","purchase_id":"33333333-3333-3333-3333-333333333333"}]
            """)
        XCTAssertEqual(rows[0].refundId.uuidString, "11111111-1111-1111-1111-111111111111")
    }

    func testRestorationEntriesDecodeFromFixedColumns() throws {
        let rows = try decode([RestorationEntry].self, """
            [{"household_id":"\(householdId)","week_start":"2026-11-01","refund_transaction_id":"11111111-1111-1111-1111-111111111111","restored_surplus_cents":5000,"debt_reduction_cents":2000,"fund_credit_cents":0,"created_at":"2026-11-09T12:00:00Z"}]
            """)
        XCTAssertEqual(rows[0].restoredSurplusCents, 5000)
    }

    func testHeldRefundsDecodeFromFixedColumns() throws {
        let rows = try decode([HeldRefund].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId)","refund_transaction_id":"33333333-3333-3333-3333-333333333333","held_cents":2500,"status":"held","resolution_note":"","created_at":"2026-11-09T12:00:00Z"}]
            """)
        XCTAssertEqual(rows[0].status, "held")
        XCTAssertEqual(rows[0].heldCents, 2500)
    }

    func testDebtAdjustmentsDecodeFromFixedColumns() throws {
        // Build 41 — Add/Set debt: the fetch selects exactly
        // these columns (see `debtAdjustments(householdId:)`).
        // The "add" row has a positive delta; the "set" row a
        // negative one (target below the balance). `created_at`
        // is optional — a row without it still decodes.
        let rows = try decode([DebtAdjustment].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId)","amount_cents":5000,"balance_after_cents":5000,"kind":"add","week_start":"2026-11-15","note":"","created_at":"2026-11-16T12:00:00Z"},{"id":"22222222-2222-2222-2222-222222222222","household_id":"\(householdId)","amount_cents":-2000,"balance_after_cents":3000,"kind":"set","week_start":"2026-11-15","note":"Correction"}]
            """)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, "add")
        XCTAssertEqual(rows[0].amountCents, 5000)
        XCTAssertEqual(rows[0].balanceAfterCents, 5000)
        XCTAssertNotNil(rows[0].createdAt)
        XCTAssertEqual(rows[1].kind, "set")
        XCTAssertEqual(rows[1].amountCents, -2000)
        XCTAssertEqual(rows[1].balanceAfterCents, 3000)
        XCTAssertNil(rows[1].createdAt)
    }

}
