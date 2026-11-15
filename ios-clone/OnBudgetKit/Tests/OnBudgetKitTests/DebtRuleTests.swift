// OnBudgetKitTests — DebtRuleTests.swift
//
// Carried Debt fund (build 29, Nov 15, 2026): the repayment rule,
// the Weekly sheet's new Debt Payment / Debt Remaining rows, the
// Home math line, and the debt row decoding. No network.

import Foundation
import XCTest
@testable import OnBudgetKit

final class DebtRuleTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func weekResult(
        baseAvailable: Int, temp: Int = 0,
        debt: Int = 0, debtPayment: Int? = nil,
        charges: Int = 0, available: Int = 0,
        locked: Bool = false
    ) -> WeekResult {
        WeekResult(
            weekStart: "2026-11-15", baseAvailableCents: baseAvailable, tempCents: temp,
            carriedDebtCents: debt, chargesCents: charges, availableCents: available,
            weekLocked: locked, pendingRefundExcludedCents: 0,
            unlinkedExcessCents: 0, debtPaymentCents: debtPayment
        )
    }

    // MARK: - The rule

    func testDebtRulePercentPaysTwentyFivePercentOfBase() {
        let rule = DebtRule(mode: .percent, percentBp: 2500)
        XCTAssertEqual(rule.rulePaymentCents(baseCents: 40000), 10000)
        // The owner's numbers: $400 base, $3,485.46 debt — the week
        // starts at $300 and the debt clears in ~35 weeks.
        XCTAssertEqual(DebtRule.paymentCents(baseCents: 40000, debtCents: 348546, rule: rule), 10000)
    }

    func testDebtRuleFixedAndOff() {
        XCTAssertEqual(DebtRule(mode: .fixed, fixedCents: 5000).rulePaymentCents(baseCents: 40000), 5000)
        XCTAssertEqual(DebtRule(mode: .off).rulePaymentCents(baseCents: 40000), 0)
        XCTAssertEqual(DebtRule(mode: .percent, percentBp: 0).rulePaymentCents(baseCents: 40000), 0)
        XCTAssertEqual(DebtRule(mode: .percent, percentBp: 10000).rulePaymentCents(baseCents: 40000), 40000)
    }

    func testDebtRulePaymentNeverExceedsDebtOrBase() {
        // Fixed $500 rule on a $400 base: the base is the only
        // money, so at most $400 is paid.
        XCTAssertEqual(
            DebtRule.paymentCents(baseCents: 40000, debtCents: 348546, rule: DebtRule(mode: .fixed, fixedCents: 50000)),
            40000
        )
        // Small debt: the payment stops at the debt.
        XCTAssertEqual(
            DebtRule.paymentCents(baseCents: 40000, debtCents: 3000, rule: DebtRule(mode: .fixed, fixedCents: 10000)),
            3000
        )
    }

    func testDebtRuleDefaultIsTwentyFivePercent() {
        XCTAssertEqual(DebtRule.default.mode, .percent)
        XCTAssertEqual(DebtRule.default.percentBp, 2500)
    }

    // MARK: - Weekly sheet rows

    func testWeekSheetRowsDebtPaymentReplacesCarriedDebt() {
        // New server: the base pays P toward the debt, so the sheet
        // shows the Debt Payment as the deduction and the debt left
        // after it as a trailing display row — never the old
        // "Carried Debt" deduction, which would no longer add up
        // (Allowance is B − P, not B − D).
        let rows = weekResult(baseAvailable: 30000, debt: 348546, debtPayment: 10000, charges: 5000, available: 25000)
            .sheetRows(baseAllowanceCents: 40000)
        XCTAssertEqual(rows.map(\.label),
                       ["Base Allowance", "Debt Payment", "Allowance", "Spent", "Balance", "Debt Remaining"])
        XCTAssertEqual(rows[1].cents, 10000)
        XCTAssertTrue(rows[1].isDeduction)
        XCTAssertEqual(rows[2].cents, 30000)
        XCTAssertEqual(rows[5].cents, 338546)
        XCTAssertFalse(rows[5].isDeduction)
    }

    func testWeekSheetRowsRuleOffShowsRemainingWithoutPayment() {
        // Rule off: nothing is deducted this week, but the debt
        // still owed shows as a trailing display row.
        let rows = weekResult(baseAvailable: 40000, debt: 348546, debtPayment: 0, charges: 0, available: 40000)
            .sheetRows(baseAllowanceCents: 40000)
        XCTAssertEqual(rows.map(\.label),
                       ["Base Allowance", "Allowance", "Spent", "Balance", "Debt Remaining"])
        XCTAssertEqual(rows[4].cents, 348546)
    }

    func testWeekSheetRowsOldServerKeepsCarriedDebt() {
        // Nil payment means the old server: the old rows, exactly.
        let rows = weekResult(baseAvailable: 0, debt: 34810, charges: 12169, available: -9479)
            .sheetRows(baseAllowanceCents: 37500)
        XCTAssertEqual(rows.map(\.label),
                       ["Base Allowance", "Carried Debt", "Allowance", "Spent", "Balance"])
        XCTAssertEqual(rows[1].cents, 34810)
        XCTAssertTrue(rows[1].isDeduction)
    }

    func testWeekSheetRowsNoDebtShowsNoDebtRows() {
        let rows = weekResult(baseAvailable: 40000, debt: 0, debtPayment: 0, charges: 0, available: 40000)
            .sheetRows(baseAllowanceCents: 40000)
        XCTAssertEqual(rows.map(\.label), ["Allowance", "Spent", "Balance"])
    }

    // MARK: - Home math line

    func testDebtMathLine() {
        let week = weekResult(baseAvailable: 30000, debt: 348546, debtPayment: 10000, available: 30000)
        XCTAssertEqual(
            week.debtMathLine(baseAllowanceCents: 40000),
            "Base $400.00 − Debt $100.00 = $300.00"
        )
    }

    func testDebtMathLineNilWhenNothingToExplain() {
        // Old server: no payment reported.
        XCTAssertNil(weekResult(baseAvailable: 0, debt: 34810, available: 0)
            .debtMathLine(baseAllowanceCents: 37500))
        // Rule off: the week keeps the full base.
        XCTAssertNil(weekResult(baseAvailable: 40000, debt: 348546, debtPayment: 0, available: 40000)
            .debtMathLine(baseAllowanceCents: 40000))
        // Stored base unknown.
        XCTAssertNil(weekResult(baseAvailable: 30000, debt: 348546, debtPayment: 10000, available: 30000)
            .debtMathLine(baseAllowanceCents: nil))
    }

    // MARK: - Decoding

    func testWeekResultDecodesDebtPaymentCents() throws {
        let week: WeekResult = try decode("""
        {"week_start": "2026-11-15", "base_available_cents": 30000,
         "temp_cents": 0, "carried_debt_cents": 348546,
         "debt_payment_cents": 10000, "charges_cents": 0,
         "available_cents": 30000, "week_locked": false,
         "pending_refund_excluded_cents": 0, "unlinked_excess_cents": 0}
        """)
        XCTAssertEqual(week.debtPaymentCents, 10000)
        XCTAssertEqual(week.debtMathLine(baseAllowanceCents: 40000),
                       "Base $400.00 − Debt $100.00 = $300.00")
    }

    func testWeekResultDecodesWithoutDebtPaymentCents() throws {
        // Responses from before build 29 carry no `debt_payment_cents`
        // key — they still decode, with the old display in effect.
        let week: WeekResult = try decode("""
        {"week_start": "2026-11-08", "base_available_cents": 0,
         "temp_cents": 0, "carried_debt_cents": 34810, "charges_cents": 12169,
         "available_cents": -9479, "week_locked": false,
         "pending_refund_excluded_cents": 0, "unlinked_excess_cents": 0}
        """)
        XCTAssertNil(week.debtPaymentCents)
        XCTAssertEqual(week.sheetRows(baseAllowanceCents: 37500).map(\.label),
                       ["Base Allowance", "Carried Debt", "Allowance", "Spent", "Balance"])
    }

    func testDebtRuleDecodes() throws {
        let rule: DebtRule = try decode("""
        {"mode": "percent", "percent_bp": 2500, "fixed_cents": 0}
        """)
        XCTAssertEqual(rule, .default)
        let fixed: DebtRule = try decode("""
        {"mode": "fixed", "percent_bp": 0, "fixed_cents": 5000}
        """)
        XCTAssertEqual(fixed.mode, .fixed)
        XCTAssertEqual(fixed.fixedCents, 5000)
    }

    func testDebtPaymentDecodes() throws {
        let payment: DebtPayment = try decode("""
        {"id": "33333333-3333-3333-3333-333333333333",
         "household_id": "22222222-2222-2222-2222-222222222222",
         "amount_cents": 10000, "source": "extra_fund",
         "week_start": "2026-11-15", "note": "",
         "created_at": "2026-11-15T12:00:00Z"}
        """)
        XCTAssertEqual(payment.amountCents, 10000)
        XCTAssertEqual(payment.source, "extra_fund")
        XCTAssertEqual(payment.weekStart, "2026-11-15")
    }

    func testFundDescriptorBuiltIns() {
        // The model that anticipates custom funds: exactly one
        // spending fund, one debt fund tied to it, plus the two
        // existing funds — no hard-coded "exactly three funds".
        XCTAssertEqual(FundDescriptor.debt.kind, .debt)
        XCTAssertEqual(FundDescriptor.debt.name, "Carried Debt")
        XCTAssertEqual(FundDescriptor.spending.kind, .spending)
        XCTAssertEqual(FundDescriptor.charity.kind, .charity)
        XCTAssertEqual(FundDescriptor.extraFund.kind, .savings)
    }
}
