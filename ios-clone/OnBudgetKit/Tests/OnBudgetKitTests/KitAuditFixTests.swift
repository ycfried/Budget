import XCTest
@testable import OnBudgetKit

/// Kit-layer audit fixes (Nov 11, 2026): decode failures that broke
/// whole calls or showed wrong data. Each test pins the server's real
/// response shape (from supabase/functions/* and the live SQL), so a
/// model drift fails loudly here instead of silently in the app.
final class KitAuditFixTests: XCTestCase {

    // MARK: - P0-1 / P0-2: selects must return every decoded column

    func testAdminMembershipsSelectIncludesRole() async throws {
        let transport = StubTransport(handler: { _ in StubTransport.json([
            ["household_id": UUID().uuidString, "role": "admin"],
        ]) })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let rows = try await client.adminMemberships(userId: UUID())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].role, .admin)
        let items = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["select"], "household_id,role")
    }

    func testAccountNicknamesSelectIncludesHouseholdId() async throws {
        let householdId = UUID()
        let transport = StubTransport(handler: { _ in StubTransport.json([
            ["household_id": householdId.uuidString, "plaid_item_id": "item-1",
             "plaid_account_id": "acc-1", "card_suffix": "1005", "nickname": "Main"],
        ]) })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let rows = try await client.accountNicknames(householdId: householdId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].householdId, householdId)
        let items = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(query["select"]?.contains("household_id") == true)
    }

    // MARK: - P0-3: plaid-exchange success omits `duplicate`

    func testPlaidExchangeSuccessDecodesWithoutDuplicateKey() throws {
        let body = Data("""
        {"item_id": "item-1", "connected": true}
        """.utf8)
        let result = try JSONDecoder().decode(PlaidExchangeResult.self, from: body)
        XCTAssertTrue(result.connected)
        XCTAssertFalse(result.duplicate)
        XCTAssertNil(result.duplicateOf)
    }

    func testPlaidExchangeDuplicateDecodes() throws {
        let body = Data("""
        {"item_id": "item-1", "connected": false, "duplicate": true, "duplicate_of": "item-0"}
        """.utf8)
        let result = try JSONDecoder().decode(PlaidExchangeResult.self, from: body)
        XCTAssertTrue(result.duplicate)
        XCTAssertEqual(result.duplicateOf, "item-0")
    }

    // MARK: - P0-4: plaid-sync 502 body has no items / connected_items

    func testPlaidSyncPartialBodyDecodesWithoutItems() throws {
        let body = Data("""
        {"added": 3, "updated": 1, "reversed": 0, "skipped": 0,
         "failed_items": ["item-9"], "failed_institutions": ["Chase"],
         "minutes_since_previous_sync": 42, "stale": false}
        """.utf8)
        let result = try JSONDecoder().decode(PlaidSyncResult.self, from: body)
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.items, 0)
        XCTAssertEqual(result.connectedItems, 0)
    }

    func testPlaidSyncItemsDecodeWhenPresent() throws {
        // The explicit decoder must pick up present values — a
        // synthesized one silently kept the 0 default (same gotcha
        // as PlaidExchangeResult.duplicate).
        let body = Data("""
        {"added": 3, "updated": 1, "reversed": 0, "skipped": 0,
         "items": 3, "connected_items": 2, "stale": false}
        """.utf8)
        let result = try JSONDecoder().decode(PlaidSyncResult.self, from: body)
        XCTAssertEqual(result.items, 3)
        XCTAssertEqual(result.connectedItems, 2)
    }

    // MARK: - P0-5 / P0-6: week-close arrays are objects, not a map / strings

    func testWeekCloseResultDecodesServerShape() throws {
        // Real payload (supabase/functions/week-close/index.ts:1003-1004
        // in the current server source): `unlinked_excess_by_week`
        // is an array of objects and `restorations_skipped` is an
        // array of objects. (The no-op early return omits the
        // unlinked key, so the field stays optional.)
        let body = Data("""
        {"weeks_closed": 1, "releases": 0, "held_legacy": 0, "restorations": 1,
         "held_refunds_created": 0, "fund_available_cents": 1000, "shortfall_cents": 0,
         "pending_late_adjustment_cents": 0,
         "unlinked_excess_by_week": [{"week_start": "2026-11-01", "unlinked_excess_cents": 250}],
         "restorations_skipped": [{"purchase_transaction_id": "00000000-0000-0000-0000-000000000001", "reason": "no purchase"}, {"reason": "restoration tables not yet migrated (apply restoration-snapshots.sql)"}]}
        """.utf8)
        let result = try JSONDecoder().decode(WeekCloseResult.self, from: body)
        XCTAssertEqual(result.weeksClosed, 1)
        XCTAssertEqual(result.unlinkedExcessByWeek?.count, 1)
        XCTAssertEqual(result.unlinkedExcessByWeek?[0].weekStart, "2026-11-01")
        XCTAssertEqual(result.unlinkedExcessByWeek?[0].unlinkedExcessCents, 250)
        XCTAssertEqual(result.restorationsSkipped.count, 2)
        XCTAssertEqual(result.restorationsSkipped[0].reason, "no purchase")
        XCTAssertNil(result.restorationsSkipped[1].purchaseTransactionId)
        XCTAssertEqual(result.restorationsSkipped[1].reason, "restoration tables not yet migrated (apply restoration-snapshots.sql)")
    }

    func testWeekCloseResultDecodesEmptyArrays() throws {
        let body = Data("""
        {"weeks_closed": 0, "releases": 0, "held_legacy": 0, "restorations": 0,
         "held_refunds_created": 0, "fund_available_cents": 0, "shortfall_cents": 0,
         "pending_late_adjustment_cents": 0,
         "unlinked_excess_by_week": [], "restorations_skipped": []}
        """.utf8)
        let result = try JSONDecoder().decode(WeekCloseResult.self, from: body)
        XCTAssertEqual(result.unlinkedExcessByWeek?.count, 0)
        XCTAssertEqual(result.restorationsSkipped.count, 0)
    }

    func testWeekCloseResultDecodesWithoutUnlinkedKey() throws {
        // The no-op early return (week-close/index.ts:423) omits the
        // unlinked key entirely — the field must decode nil, not throw.
        let body = Data("""
        {"weeks_closed": 0, "releases": 0, "held_legacy": 0, "restorations": 0,
         "held_refunds_created": 0, "fund_available_cents": 0, "shortfall_cents": 0,
         "pending_late_adjustment_cents": 0,
         "restorations_skipped": []}
        """.utf8)
        let result = try JSONDecoder().decode(WeekCloseResult.self, from: body)
        XCTAssertNil(result.unlinkedExcessByWeek)
        XCTAssertEqual(result.restorationsSkipped.count, 0)
    }

    // MARK: - P1-2: charity committed rounds half-up, like the server

    func testCharityCommittedRoundsHalfUp() throws {
        // $1.05 at 10%: 105 × 1000 = 105000; +5000 = 110000; /10000 = 11.
        // Truncation gave 10 — 1¢ low on every such row.
        let body = Data("""
        {"id": "00000000-0000-0000-0000-000000000001",
         "household_id": "00000000-0000-0000-0000-000000000002",
         "source_label": "Check", "amount_cents": 105, "income_date": "2026-11-02",
         "rate_bp": 1000, "status": "active", "replaces_id": null,
         "note": "", "created_by": null, "created_at": null}
        """.utf8)
        let income = try JSONDecoder().decode(CharityIncome.self, from: body)
        XCTAssertEqual(income.committedCents, 11)
    }

    func testCharityCommittedBelowThresholdUnchanged() throws {
        // $1.00 at 10%: 100 × 1000 = 100000; +5000 = 105000; /10000 = 10.
        let body = Data("""
        {"id": "00000000-0000-0000-0000-000000000001",
         "household_id": "00000000-0000-0000-0000-000000000002",
         "source_label": "Check", "amount_cents": 100, "income_date": "2026-11-02",
         "rate_bp": 1000, "status": "active", "replaces_id": null,
         "note": "", "created_by": null, "created_at": null}
        """.utf8)
        let income = try JSONDecoder().decode(CharityIncome.self, from: body)
        XCTAssertEqual(income.committedCents, 10)
    }

    // MARK: - P1-5: one non-string metadata value must not nuke the name

    func testAuthUserKeepsStringsWhenMetadataHasNonString() throws {
        let body = Data("""
        {"id": "00000000-0000-0000-0000-000000000001", "email": "someone@example.com",
         "user_metadata": {"full_name": "Shuki Friedman", "email_verified": true, "age": 30}}
        """.utf8)
        let user = try JSONDecoder().decode(AuthUser.self, from: body)
        XCTAssertEqual(user.displayName, "Shuki Friedman")
        XCTAssertEqual(user.userMetadata["full_name"], "Shuki Friedman")
        XCTAssertNil(user.userMetadata["email_verified"])
    }
}
