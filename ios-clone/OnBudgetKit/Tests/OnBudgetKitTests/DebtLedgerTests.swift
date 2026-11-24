import XCTest
@testable import OnBudgetKit

/// Build 69 (owner, Nov 24, 2026): the debt ledger — "Where It
/// Came From" showed the debt balance at the END of each closed
/// week (cumulative balances that do not add up), so the owner
/// could not see where the debt came from. The ledger shows what
/// each week/event DID to the debt, with +/-, so the rows add up
/// exactly to the current debt. These tests pin the derivation
/// against the live household's real figures (Nov 24, 2026):
///   Week of Nov 1:  +$4,058.16 overspent
///   Week of Nov 8:  -$179.99 surplus paid toward debt
///   Nov 16:         -$2,988.24 cleared
///   Week of Nov 15: +$238.03 overspent
///   = $1,127.96 now
final class DebtLedgerTests: XCTestCase {
    private let householdId = UUID(uuidString: "647d1f23-606f-43af-92e5-1de2f1f34377")!

    private func close(weekStart: String, outgoingDebtCents: Int, createdAt: String) -> WeekClose {
        WeekClose(
            id: UUID(), householdId: householdId, weekStart: weekStart,
            surplusCents: 0, outgoingDebtCents: outgoingDebtCents, outgoingCreditCents: 0,
            baseAllowanceCents: 40000, tempIncreaseCents: 0, lateAdjustmentCents: 0,
            debtPaymentCents: nil, createdAt: createdAt
        )
    }

    private func payment(amountCents: Int, source: String, weekStart: String, createdAt: String) -> DebtPayment {
        DebtPayment(
            id: UUID(), householdId: householdId, amountCents: amountCents,
            source: source, weekStart: weekStart, note: "", createdAt: createdAt
        )
    }

    private func adjustment(amountCents: Int, balanceAfterCents: Int, kind: String, weekStart: String, createdAt: String) -> DebtAdjustment {
        DebtAdjustment(
            id: UUID(), householdId: householdId, amountCents: amountCents,
            balanceAfterCents: balanceAfterCents, kind: kind, weekStart: weekStart,
            note: "", createdAt: createdAt
        )
    }

    /// The live household, Nov 24, 2026 — the exact figures the
    /// owner asked about. The rows must come out in the order he
    /// wrote them (the Nov 16 clear before the Nov 15 week's
    /// result, which only closed Nov 22) and add up to $1,127.96.
    func testLiveHouseholdLedgerAddsUp() {
        let closes = [
            close(weekStart: "2026-11-15", outgoingDebtCents: 112796, createdAt: "2026-11-22 12:11:58.229044+00"),
            close(weekStart: "2026-11-08", outgoingDebtCents: 387817, createdAt: "2026-11-15 12:01:11.666838+00"),
            close(weekStart: "2026-11-01", outgoingDebtCents: 405816, createdAt: "2026-11-08 05:59:10.05102+00"),
        ]
        let payments = [
            payment(amountCents: 298824, source: "clear", weekStart: "2026-11-15", createdAt: "2026-11-16 16:37:46.621162+00"),
            payment(amountCents: 17999, source: "surplus", weekStart: "2026-11-08", createdAt: "2026-11-15 18:58:07.362463+00"),
        ]
        let entries = DebtLedger.build(
            closes: closes, payments: payments, adjustments: [],
            debtName: "Overspent (Past)", extraFundName: "Extra Fund"
        )
        XCTAssertEqual(entries.map(\.amountCents), [405816, -17999, -298824, 23803])
        XCTAssertEqual(entries.map(\.title), [
            "Week of Nov 1, 2026",
            "Nov 15, 2026",
            "Nov 16, 2026",
            "Week of Nov 15, 2026",
        ])
        XCTAssertEqual(entries.map(\.subtitle), [
            "Overspent",
            "Surplus paid toward debt",
            "Overspent (Past) Cleared",
            "Overspent",
        ])
        XCTAssertEqual(DebtLedger.totalCents(entries), 112796)
    }

    /// A week that came in under budget gets no week entry — its
    /// effect is already in its surplus payment, so adding one
    /// would double-count it.
    func testUnderBudgetWeekHasNoWeekEntry() {
        let closes = [
            close(weekStart: "2026-11-08", outgoingDebtCents: 387817, createdAt: "2026-11-15 12:01:11.666838+00"),
            close(weekStart: "2026-11-01", outgoingDebtCents: 405816, createdAt: "2026-11-08 05:59:10.05102+00"),
        ]
        let payments = [
            payment(amountCents: 17999, source: "surplus", weekStart: "2026-11-08", createdAt: "2026-11-15 18:58:07.362463+00"),
        ]
        let entries = DebtLedger.build(closes: closes, payments: payments, adjustments: [])
        XCTAssertEqual(entries.map(\.amountCents), [405816, -17999])
        XCTAssertEqual(entries.map(\.kind), [.week, .payment])
        XCTAssertEqual(DebtLedger.totalCents(entries), 387817)
    }

    /// A manual Add/Set rides in the ledger with its signed
    /// amount, and the week's overspend is derived net of it — so
    /// a Set that lowered the debt does not inflate that week's
    /// overspend.
    func testManualAdjustmentIsItsOwnEntry() {
        let closes = [
            close(weekStart: "2026-11-08", outgoingDebtCents: 311632, createdAt: "2026-11-15 12:01:11.666838+00"),
            close(weekStart: "2026-11-01", outgoingDebtCents: 405816, createdAt: "2026-11-08 05:59:10.05102+00"),
        ]
        let adjustments = [
            adjustment(amountCents: -100000, balanceAfterCents: 311632, kind: "set", weekStart: "2026-11-08", createdAt: "2026-11-10 10:00:00+00"),
        ]
        // Without the adjustment the week would read as a $94,184
        // pay-down with no payment behind it; with it, the week
        // overspent $5,816 and the $100,000 Set is its own
        // -100,000 entry. The Set (known Nov 10) precedes the
        // week's close (Nov 15) — the ledger is chronological by
        // when each item became known.
        let entries = DebtLedger.build(closes: closes, payments: [], adjustments: adjustments)
        XCTAssertEqual(entries.map(\.amountCents), [405816, -100000, 5816])
        XCTAssertEqual(DebtLedger.totalCents(entries), 311632)
    }

    /// A payment in the current (unclosed) week still counts — it
    /// reduces the total even though no close attributes it.
    func testCurrentWeekPaymentCounts() {
        let closes = [
            close(weekStart: "2026-11-01", outgoingDebtCents: 405816, createdAt: "2026-11-08 05:59:10.05102+00"),
        ]
        let payments = [
            payment(amountCents: 50000, source: "clear", weekStart: "2026-11-22", createdAt: "2026-11-23 09:00:00+00"),
        ]
        let entries = DebtLedger.build(closes: closes, payments: payments, adjustments: [])
        XCTAssertEqual(entries.map(\.amountCents), [405816, -50000])
        XCTAssertEqual(DebtLedger.totalCents(entries), 355816)
    }

    /// No closes, no payments, no adjustments: an empty ledger
    /// totalling zero — never a fabricated row.
    func testEmptyLedger() {
        let entries = DebtLedger.build(closes: [], payments: [], adjustments: [])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(DebtLedger.totalCents(entries), 0)
    }
}
