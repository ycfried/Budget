// OnBudgetKitTests — WeeklyBudgetTopupsTests.swift
//
// Build 43, item 21 (owner, Nov 17, 2026): the Spending breakdown's
// "Top Ups" line. The override IS the week's total, so it folds the
// temporary allowance and all top-ups together; the new
// `weekly_budget_topups` table (`supabase/weekly-budget-topups.sql`)
// records one row per "Top Up Budget" grant so the client can split
// the total back into Base + Top Ups + Temporary Increase/Decrease.
//
// These tests pin, with fixtures only (no network):
//   1. The new row model decodes from exactly the columns the fetch
//      selects, so a future narrowing fails here instead of on a
//      live screen (the Nov 9 select-shape lesson).
//   2. The fetch hits `weekly_budget_topups` filtered by household
//      and week, through the stub transport.
//   3. The Temporary delta EXCLUDES top-ups, and is nil when there
//      is nothing left to explain.
//   4. The breakdown rows sum to the week's Total — Base + Top Ups
//      + TempDelta − Debt Payment == baseAvailableCents + tempCents
//      — for override weeks (the only weeks that can carry top-ups:
//      `add_to_weekly_budget` always upserts an override).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OnBudgetKit

final class WeeklyBudgetTopupsTests: XCTestCase {
    private let householdId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - 1. Row decoding (fixed select shape)

    func testWeeklyBudgetTopupDecodesFromFixedColumns() throws {
        let rows = try decode([WeeklyBudgetTopup].self, """
            [{"id":"11111111-1111-1111-1111-111111111111","household_id":"\(householdId.uuidString)","week_start":"2026-11-15","amount_cents":5000,"created_by":"33333333-3333-3333-3333-333333333333","created_at":"2026-11-17T12:00:00Z"}]
            """)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].weekStart, "2026-11-15")
        XCTAssertEqual(rows[0].amountCents, 5000)
    }

    // MARK: - 2. Fetch query shape

    func testWeeklyBudgetTopupsFetchFiltersByHouseholdAndWeek() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json([[
                "id": UUID().uuidString,
                "household_id": self.householdId.uuidString,
                "week_start": "2026-11-15",
                "amount_cents": 5000,
                "created_by": UUID().uuidString,
                "created_at": "2026-11-17T12:00:00Z",
            ]])
        })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let rows = try await client.weeklyBudgetTopups(
            householdId: householdId, weekStart: "2026-11-15"
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amountCents, 5000)
        let url = transport.requests[0].url!.absoluteString
        XCTAssertTrue(url.contains("/rest/v1/weekly_budget_topups"), url)
        XCTAssertTrue(url.contains("household_id=eq.\(householdId.uuidString)"), url)
        XCTAssertTrue(url.contains("week_start=eq.2026-11-15"), url)
    }

    // MARK: - 3. Temporary delta excludes top-ups

    func testTemporaryDeltaExcludesTopUps() {
        // $500 override on a $400 base, $50 of it a top-up: the
        // temporary increase is the remaining $50, not $100.
        XCTAssertEqual(
            WeeklyBudgetTopup.temporaryDeltaCents(overrideCents: 50000, baseAllowanceCents: 40000, topUpsCents: 5000),
            5000
        )
    }

    func testTemporaryDeltaIsNilWhenTopUpsExplainTheWholeOverride() {
        // $450 override on a $400 base, all $50 of it a top-up:
        // no temporary adjustment left to explain, so no row.
        XCTAssertNil(
            WeeklyBudgetTopup.temporaryDeltaCents(overrideCents: 45000, baseAllowanceCents: 40000, topUpsCents: 5000)
        )
    }

    func testTemporaryDeltaIsNilWithoutAnOverride() {
        XCTAssertNil(
            WeeklyBudgetTopup.temporaryDeltaCents(overrideCents: nil, baseAllowanceCents: 40000, topUpsCents: 0)
        )
    }

    func testTemporaryDeltaDecreaseWithoutTopUps() {
        XCTAssertEqual(
            WeeklyBudgetTopup.temporaryDeltaCents(overrideCents: 35000, baseAllowanceCents: 40000, topUpsCents: 0),
            -5000
        )
    }

    // MARK: - 4. Row arithmetic: Base + Top Ups + TempDelta − Debt Payment == Total

    /// The FundsView Spending Total for a week: the same figure as
    /// `FundsViewModel.currentWeekTotalCents` /
    /// `FundsView.spendingTotalCents` (`baseAvailableCents +
    /// tempCents`). `baseAvailable` is the effective total B less
    /// the week's debt payment P (engine.mjs: `baseAvailable = B -
    /// debtPayment`); for override weeks the server reports
    /// `temp_cents` 0.
    private func weekResult(
        baseAvailable: Int, temp: Int = 0, override: Int? = nil,
        debtPayment: Int? = nil
    ) -> WeekResult {
        WeekResult(
            weekStart: "2026-11-15", baseAvailableCents: baseAvailable, tempCents: temp,
            carriedDebtCents: 0, chargesCents: 0, availableCents: baseAvailable + temp,
            weekLocked: false, pendingRefundExcludedCents: 0,
            unlinkedExcessCents: 0, overrideCents: override, debtPaymentCents: debtPayment
        )
    }

    /// The breakdown rows as the Funds Spending card renders them
    /// (build 43, item 21): Base + Top Ups (always) + TempDelta
    /// (only when non-nil) − Debt Payment (only when > 0).
    private func breakdownSum(
        week: WeekResult, base: Int, topUps: Int
    ) -> Int {
        var sum = base + topUps
        if let delta = WeeklyBudgetTopup.temporaryDeltaCents(
            overrideCents: week.overrideCents, baseAllowanceCents: base, topUpsCents: topUps) {
            sum += delta
        }
        if let payment = week.debtPaymentCents, payment > 0 {
            sum -= payment
        }
        return sum
    }

    func testRowsSumToTotalForOverrideWeekWithTopUpsAndDebtPayment() {
        // Owner's case, with debt: $400 base, $50 top-up, $50
        // temporary increase → $500 override, $100 debt payment.
        // Total = override − payment = $400.
        let week = weekResult(baseAvailable: 40000, override: 50000, debtPayment: 10000)
        XCTAssertEqual(week.baseAvailableCents + week.tempCents, 40000)
        XCTAssertEqual(breakdownSum(week: week, base: 40000, topUps: 5000), 40000)
    }

    func testRowsSumToTotalForOverrideWeekWithTopUpsOnly() {
        // $400 base + $50 top-up, no temporary change, no debt:
        // override $450, Total $450. The $50 now reads on the
        // Top Ups line (always shown) instead of hiding inside
        // a "Temporary Increase" row.
        let week = weekResult(baseAvailable: 45000, override: 45000)
        XCTAssertEqual(week.baseAvailableCents + week.tempCents, 45000)
        XCTAssertEqual(breakdownSum(week: week, base: 40000, topUps: 5000), 45000)
    }

    func testRowsSumToTotalForOverrideDecrease() {
        // $400 base, override cut to $300, no top-ups, $50 debt
        // payment: Total = $250.
        let week = weekResult(baseAvailable: 25000, override: 30000, debtPayment: 5000)
        XCTAssertEqual(week.baseAvailableCents + week.tempCents, 25000)
        XCTAssertEqual(breakdownSum(week: week, base: 40000, topUps: 0), 25000)
    }
}
