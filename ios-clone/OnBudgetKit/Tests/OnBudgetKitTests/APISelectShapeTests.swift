// OnBudgetKitTests — APISelectShapeTests.swift
//
// The PostgREST reads in PostgrestClient select narrow column lists.
// Each list must include every non-optional field of its model, or
// plain JSONDecoder decoding fails (a missing key is a decoding
// error, not a nil). These tests decode each model from JSON
// containing exactly the columns its read selects, so a future
// narrowing that drops a required field fails here instead of on a
// live screen. Added by the Auth+Home builder, Nov 9, 2026, after
// five reads (fundLedger, surplusReleases, plaidItems,
// activeCharityIncome, charitySettings) were found to select too
// few columns to decode. Four more of the same class (fundTopups,
// activePlaidItems, plaidAccounts, charityIncomeHistory) were
// widened and pinned the same day. No network.

import Foundation
import XCTest
@testable import OnBudgetKit

final class APISelectShapeTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testFundLedgerRowDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "kind": "release",
          "amount_cents": 12000,
          "week_start": "2026-11-08",
          "request_id": null,
          "note": "Week close",
          "created_by": null,
          "created_at": "2026-11-09T00:00:00Z"
        }
        """, as: FundLedgerEntry.self)
        XCTAssertEqual(row.amountCents, 12000)
        XCTAssertEqual(row.kind, "release")
    }

    func testSurplusReleaseDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "week_start": "2026-11-01",
          "surplus_cents": 5000,
          "release_date": "2026-11-09",
          "status": "pending",
          "released_cents": 0,
          "created_at": "2026-11-09T00:00:00Z",
          "closed_at": null
        }
        """, as: SurplusRelease.self)
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.surplusCents, 5000)
    }

    func testPlaidItemDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "plaid_item_id": "item-1",
          "institution_name": "Chase",
          "institution_id": "ins_1",
          "status": "active",
          "last_sync_at": "2026-11-09T12:00:00Z",
          "created_at": "2026-11-01T00:00:00Z"
        }
        """, as: PlaidItemPublic.self)
        XCTAssertTrue(row.isActive)
        XCTAssertEqual(row.lastSyncAt, "2026-11-09T12:00:00Z")
    }

    func testCharityIncomeDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "source_label": "Paycheck",
          "amount_cents": 100000,
          "income_date": "2026-11-06",
          "rate_bp": 1000,
          "status": "active",
          "replaces_id": null,
          "note": "",
          "created_by": null,
          "created_at": "2026-11-06T00:00:00Z"
        }
        """, as: CharityIncome.self)
        XCTAssertEqual(row.committedCents, 10000)
    }

    func testCharitySettingsDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "household_id": "22222222-2222-2222-2222-222222222222",
          "default_rate_bp": 1000,
          "updated_at": null
        }
        """, as: CharitySettings.self)
        XCTAssertEqual(row.defaultRateBp, 1000)
    }

    func testFundTopupDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "client_key": "topup-1",
          "amount_cents": 10000,
          "shortfall_covered_cents": 4000,
          "fund_added_cents": 6000,
          "shortfall_after_cents": 0,
          "note": "Top-up",
          "created_by": null,
          "created_at": "2026-11-09T00:00:00Z"
        }
        """, as: FundTopup.self)
        XCTAssertEqual(row.amountCents, 10000)
        XCTAssertEqual(row.clientKey, "topup-1")
        XCTAssertEqual(row.shortfallCoveredCents, 4000)
        XCTAssertEqual(row.fundAddedCents, 6000)
    }

    func testActivePlaidItemDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "plaid_item_id": "item-1",
          "institution_name": "Chase",
          "institution_id": "ins_1",
          "status": "active",
          "last_sync_at": "2026-11-09T12:00:00Z",
          "created_at": "2026-11-01T00:00:00Z"
        }
        """, as: PlaidItemPublic.self)
        XCTAssertTrue(row.isActive)
        XCTAssertEqual(row.plaidItemId, "item-1")
    }

    func testPlaidAccountDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "plaid_item_id": "item-1",
          "plaid_account_id": "acc-1",
          "name": "Checking",
          "mask": "1234",
          "type": "depository",
          "subtype": "checking",
          "disconnected_at": null,
          "created_at": "2026-11-01T00:00:00Z",
          "updated_at": "2026-11-01T00:00:00Z"
        }
        """, as: PlaidAccount.self)
        XCTAssertEqual(row.plaidAccountId, "acc-1")
        XCTAssertFalse(row.isDisconnected)
        XCTAssertEqual(row.plainType, "Checking")
    }

    func testCharityIncomeHistoryDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "source_label": "Paycheck",
          "amount_cents": 100000,
          "income_date": "2026-11-06",
          "rate_bp": 1000,
          "status": "active",
          "replaces_id": null,
          "note": "",
          "created_by": null,
          "created_at": "2026-11-06T00:00:00Z"
        }
        """, as: CharityIncome.self)
        XCTAssertEqual(row.committedCents, 10000)
        XCTAssertEqual(row.sourceLabel, "Paycheck")
    }

    // MARK: - Integration pass (Nov 9, 2026): six more narrow selects
    // that could not decode their full model (same class as the nine
    // above). Each JSON below contains exactly the columns its read
    // now selects.

    func testHouseholdDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "Friedman Household",
          "base_allowance_cents": 37500,
          "fund_shortfall_cents": 0,
          "auto_sync_enabled": true,
          "created_at": "2026-11-01T00:00:00Z"
        }
        """, as: Household.self)
        XCTAssertEqual(row.name, "Friedman Household")
        XCTAssertEqual(row.baseAllowanceCents, 37500)
        XCTAssertTrue(row.autoSyncEnabled)
    }

    func testTransactionDecodesFromRefundLinkCandidateColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "household_id": "22222222-2222-2222-2222-222222222222",
          "date": "2026-11-06",
          "merchant": "Trader Joe's",
          "amount_cents": 4523,
          "card_suffix": "1234",
          "source": "plaid",
          "state": "verified",
          "kind": "charge",
          "fund_allocation_cents": 0,
          "excluded": false,
          "exclude_reason": "",
          "late": false,
          "dedupe_hash": "abc123",
          "created_at": "2026-11-06T00:00:00Z"
        }
        """, as: Transaction.self)
        XCTAssertEqual(row.merchant, "Trader Joe's")
        XCTAssertEqual(row.amountCents, 4523)
        XCTAssertFalse(row.isInTrash)
    }

    func testWeekCloseDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "household_id": "22222222-2222-2222-2222-222222222222",
          "week_start": "2026-11-01",
          "surplus_cents": 5000,
          "outgoing_debt_cents": 0
        }
        """, as: WeekClose.self)
        XCTAssertEqual(row.weekStart, "2026-11-01")
        XCTAssertEqual(row.surplusCents, 5000)
    }

    func testSurplusReleaseForHistoryDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "household_id": "22222222-2222-2222-2222-222222222222",
          "week_start": "2026-11-01",
          "surplus_cents": 5000,
          "release_date": "2026-11-09",
          "status": "pending",
          "released_cents": 0
        }
        """, as: SurplusRelease.self)
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.releaseDate, "2026-11-09")
    }

    func testWebhookEventDecodesFromSelectedColumns() throws {
        let row = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "webhook_code": "DEFAULT_UPDATE",
          "processed": false
        }
        """, as: WebhookEvent.self)
        XCTAssertEqual(row.webhookCode, "DEFAULT_UPDATE")
        XCTAssertFalse(row.processed)
    }
}
