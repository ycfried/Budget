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

}
