// OnBudgetKitTests — APIDecodingTests.swift
//
// Response decoding against fixtures copied from the real shapes in
// live.js (v66) and the Edge Function sources. No network.

import Foundation
import XCTest
@testable import OnBudgetKit

private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

final class APIDecodingTests: XCTestCase {
    func testTransactionDecodesFullRow() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "date": "2026-11-02",
          "merchant": "AMAZON MARKEPLACE NA PA",
          "amount_cents": 1059,
          "card_suffix": "1005",
          "source": "plaid",
          "state": "verified",
          "kind": "charge",
          "fund_allocation_cents": 0,
          "excluded": false,
          "exclude_reason": "",
          "late": false,
          "external_id": "plaid-txn-1",
          "dedupe_hash": "deadbeef",
          "original_purchase_id": null,
          "pre_exclusion_state": null,
          "created_at": "2026-11-02T12:00:00Z"
        }
        """
        let txn: Transaction = try decode(json)
        XCTAssertEqual(txn.merchant, "AMAZON MARKEPLACE NA PA")
        XCTAssertEqual(txn.amountCents, 1059)
        XCTAssertEqual(txn.cardSuffix, "1005")
        XCTAssertEqual(txn.source, .plaid)
        XCTAssertEqual(txn.state, .verified)
        XCTAssertEqual(txn.kind, .charge)
        XCTAssertFalse(txn.isInTrash)
        XCTAssertFalse(txn.isPendingRefund)
    }

    func testTransactionTrashAndPendingRefundFlags() throws {
        let trashed: Transaction = try decode("""
        {"id": "11111111-1111-1111-1111-111111111111",
         "household_id": "22222222-2222-2222-2222-222222222222",
         "date": "2026-11-03", "merchant": "X", "amount_cents": -200,
         "card_suffix": "1005", "source": "plaid", "state": "excluded",
         "kind": "refund", "fund_allocation_cents": 0, "excluded": true,
         "exclude_reason": "duplicate", "late": false,
         "dedupe_hash": "h", "created_at": "2026-11-03T00:00:00Z"}
        """)
        XCTAssertTrue(trashed.isInTrash)

        let pendingRefund: Transaction = try decode("""
        {"id": "11111111-1111-1111-1111-111111111111",
         "household_id": "22222222-2222-2222-2222-222222222222",
         "date": "2026-11-03", "merchant": "X", "amount_cents": -200,
         "card_suffix": "1005", "source": "amex_alert", "state": "provisional",
         "kind": "refund", "fund_allocation_cents": 0, "excluded": false,
         "exclude_reason": "", "late": false,
         "dedupe_hash": "h", "created_at": "2026-11-03T00:00:00Z"}
        """)
        XCTAssertTrue(pendingRefund.isPendingRefund)
    }

    func testUnknownKindDecodesWithoutFailing() throws {
        let txn: Transaction = try decode("""
        {"id": "11111111-1111-1111-1111-111111111111",
         "household_id": "22222222-2222-2222-2222-222222222222",
         "date": "2026-11-03", "merchant": "X", "amount_cents": 100,
         "card_suffix": "0000", "source": "manual", "state": "provisional",
         "kind": "mystery_kind", "fund_allocation_cents": 0, "excluded": false,
         "exclude_reason": "", "late": false,
         "dedupe_hash": "h", "created_at": "2026-11-03T00:00:00Z"}
        """)
        XCTAssertEqual(txn.kind, .other("mystery_kind"))
        XCTAssertEqual(txn.kind.rawValue, "mystery_kind")
    }

    func testWeekResultDecodesFlat() throws {
        let week: WeekResult = try decode("""
        {"week_start": "2026-11-08", "base_available_cents": 37500,
         "temp_cents": 0, "carried_debt_cents": 0, "charges_cents": 1059,
         "available_cents": 36441, "week_locked": false,
         "pending_refund_excluded_cents": 0, "unlinked_excess_cents": 0}
        """)
        XCTAssertEqual(week.weekStart, "2026-11-08")
        XCTAssertEqual(week.availableCents, 36441)
        XCTAssertFalse(week.weekLocked)
    }

    func testWeekResultToleratesWrappedResult() throws {
        // live.js reads `week.result ?? week` — both shapes decode.
        let week: WeekResult = try decode("""
        {"result": {"week_start": "2026-11-08", "base_available_cents": 37500,
         "temp_cents": 5000, "carried_debt_cents": 1000, "charges_cents": 2000,
         "available_cents": 40500, "week_locked": false,
         "pending_refund_excluded_cents": 0, "unlinked_excess_cents": 0}}
        """)
        XCTAssertEqual(week.tempCents, 5000)
        XCTAssertEqual(week.carriedDebtCents, 1000)
    }

    func testWeekCloseResultDecodes() throws {
        let close: WeekCloseResult = try decode("""
        {"weeks_closed": 1, "releases": 1, "held_legacy": 0,
         "restorations": 0, "held_refunds_created": 0,
         "fund_available_cents": 12000, "shortfall_cents": 0,
         "pending_late_adjustment_cents": 0,
         "unlinked_excess_by_week": {}, "restorations_skipped": []}
        """)
        XCTAssertEqual(close.weeksClosed, 1)
        XCTAssertEqual(close.fundAvailableCents, 12000)
    }

    func testPlaidSyncResultDecodes() throws {
        let sync: PlaidSyncResult = try decode("""
        {"added": 3, "updated": 1, "reversed": 0, "skipped": 2,
         "skipped_by_reason": {"duplicate": 2},
         "minutes_since_previous_sync": 61, "stale": false,
         "duplicate_removed": [], "items": 1, "connected_items": 1,
         "skipped_disconnected": 0, "truncated": false}
        """)
        XCTAssertEqual(sync.added, 3)
        XCTAssertEqual(sync.skippedByReason?["duplicate"], 2)
        XCTAssertEqual(sync.stale, false)
    }

    func testGmailPollResultWithPerConnectionError() throws {
        let poll: GmailPollResult = try decode("""
        {"connections": 1, "checked": 5, "stored": 1, "duplicates": 4,
         "quarantined": 0, "unparseable": 0,
         "errors": [{"connection_id": "33333333-3333-3333-3333-333333333333",
                     "error": "reauthorization required"}],
         "minutes_since_previous_poll": 5, "stale": false}
        """)
        XCTAssertEqual(poll.stored, 1)
        XCTAssertTrue(poll.needsReauthorization)
        XCTAssertEqual(poll.firstError?.error, "reauthorization required")
    }

    func testPlaidItemAndEmailConnectionDecode() throws {
        let item: PlaidItemPublic = try decode("""
        {"id": "44444444-4444-4444-4444-444444444444",
         "household_id": "22222222-2222-2222-2222-222222222222",
         "plaid_item_id": "item-1", "institution_name": "American Express",
         "institution_id": "ins_1", "status": "active",
         "last_sync_at": "2026-11-09T12:00:00Z",
         "created_at": "2026-11-01T00:00:00Z"}
        """)
        XCTAssertTrue(item.isActive)
        XCTAssertEqual(item.institutionName, "American Express")

        let conn: EmailConnectionPublic = try decode("""
        {"id": "55555555-5555-5555-5555-555555555555",
         "household_id": "22222222-2222-2222-2222-222222222222",
         "provider": "gmail", "email_address": "owner@example.com",
         "status": "active", "last_poll_at": "2026-11-09T12:00:00Z",
         "last_error": null, "created_at": "2026-11-02T00:00:00Z",
         "connected_at": "2026-11-02T00:00:00Z"}
        """)
        XCTAssertEqual(conn.provider, "gmail")
        XCTAssertEqual(conn.connectedAt, "2026-11-02T00:00:00Z")
    }

    func testMemberListRowDisplayNameFallbacks() throws {
        let row: MemberListRow = try decode("""
        {"user_id": "66666666-6666-6666-6666-666666666666",
         "display_name": null, "role": "member",
         "created_at": "2026-11-01T00:00:00Z", "email_prefix": "spouse"}
        """)
        XCTAssertEqual(row.displayName(), "spouse")
        let named: MemberListRow = try decode("""
        {"user_id": "66666666-6666-6666-6666-666666666666",
         "display_name": "Shuki Friedman", "role": "admin",
         "created_at": "2026-11-01T00:00:00Z", "email_prefix": "ycfried1"}
        """)
        XCTAssertEqual(named.displayName(), "Shuki Friedman")
    }

    func testRPCJsonbReturnsDecode() throws {
        let topup: AddFundMoneyResult = try decode("""
        {"amount_cents": 10000, "shortfall_covered_cents": 4000,
         "fund_added_cents": 6000, "shortfall_after_cents": 0,
         "replayed": false}
        """)
        XCTAssertEqual(topup.shortfallCoveredCents, 4000)
        XCTAssertEqual(topup.fundAddedCents, 6000)

        let income: CharityIncomeResult = try decode("""
        {"income_id": "77777777-7777-7777-7777-777777777777",
         "rate_bp": 1000, "committed_cents": 5000}
        """)
        XCTAssertEqual(income.committedCents, 5000)

        let gift: CharityGiftResult = try decode("""
        {"transaction_id": "88888888-8888-8888-8888-888888888888",
         "replayed": true}
        """)
        XCTAssertTrue(gift.replayed)
    }

    func testAuthSessionDecodesGoTrueShape() throws {
        let session: AuthSession = try decode("""
        {"access_token": "acc", "refresh_token": "ref",
         "token_type": "bearer", "expires_in": 3600,
         "user": {"id": "99999999-9999-9999-9999-999999999999",
                  "email": "owner@example.com",
                  "user_metadata": {"full_name": "Shuki Friedman"}}}
        """)
        XCTAssertEqual(session.user.email, "owner@example.com")
        XCTAssertEqual(session.user.displayName, "Shuki Friedman")
        XCTAssertFalse(session.isExpired)
    }
}
