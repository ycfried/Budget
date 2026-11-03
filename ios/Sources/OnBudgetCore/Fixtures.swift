import Foundation

/// Invented merchants/amounts/identifiers only. These are independent display fixtures,
/// not a reconstructed household ledger and not results calculated by Swift.
public enum Fixtures {
    public static let instant = Date(timeIntervalSince1970: 1_793_642_400)
    public static func snapshot(overspent: Bool = false) -> HouseholdSnapshot {
        let week = WeekResponse(weekStart: "2026-11-01", baseAvailableCents: 35_000,
            tempCents: 5_000, carriedDebtCents: 2_500, chargesCents: overspent ? 42_500 : 18_750,
            availableCents: overspent ? -2_500 : 21_250, weekLocked: false, pendingRefundExcludedCents: 1_500)
        return HouseholdSnapshot(
            dashboard: Dashboard(week: week, allowance: Money(cents: 37_500),
                outgoingDebt: Money(cents: overspent ? 2_500 : 0), daysLeft: 5, computedAt: instant),
            purchases: [
                purchase("sample-1", "2026-11-02", "Maple Market", 4_250, "1111", "plaid", "verified"),
                purchase("sample-2", "2026-11-02", "Harbor Café", 1_875, "2222", "amex_alert", "provisional"),
                purchase("sample-3", "2026-11-01", "Trail Supply", 8_000, "1111", "manual", "provisional", review: true),
                purchase("sample-4", "2026-10-31", "Maple Market refund", -1_500, "1111", "plaid", "pending", kind: "refund"),
                purchase("sample-5", "2026-10-30", "Card payment", -25_000, "1111", "plaid", "verified", kind: "payment"),
                purchase("sample-6", "2026-10-29", "Rewards credit", -500, "1111", "plaid", "verified", kind: "cashback"),
                purchase("sample-7", "2026-10-28", "Duplicate sample", 1_000, "2222", "manual", "excluded", excluded: true),
                purchase("sample-8", "2026-10-27", "Reversed hold", 6_000, "1111", "plaid", "reversed"),
                purchase("sample-9", "2026-10-26", "Quarantined sample", 900, "2222", "amex_alert", "quarantined"),
                purchase("sample-10", "2026-10-25", "Voided sample", 900, "2222", "manual", "voided")
            ],
            fund: FundSummary(available: Money(cents: 13_000), pending: Money(cents: 7_500),
                released: Money(cents: 25_000), spent: Money(cents: 12_000), adjustments: Money(cents: 0), shortfall: Money(cents: 0)),
            requests: [FundRequest(id: "request-sample", merchant: "Trail Supply", requester: "Sample member",
                note: "Weekend supplies", status: "pending", amount: Money(cents: 8_000), remainder: Money(cents: 0)),
                FundRequest(id: "split-sample", merchant: "Stationery", requester: "Sample member", note: "",
                    status: "split", amount: Money(cents: 3_000), remainder: Money(cents: 1_000))],
            fundLedger: [LedgerRecord(id: "ledger-1", title: "Surplus released", detail: "Sample closed week", amount: Money(cents: 7_500)),
                LedgerRecord(id: "ledger-2", title: "Fund allocation", detail: "Sample approved purchase", amount: Money(cents: -4_000))],
            heldRefunds: [HeldRefund(id: "held-sample", merchant: "Sample excess refund", status: "pending", amount: Money(cents: 2_500))],
            restorations: [LedgerRecord(id: "restoration-sample", title: "Refund restoration", detail: "Surplus restored; debt reduction $0.00. Last completed week horizon.", amount: Money(cents: 5_000))],
            savings: SavingsSummary(fundAvailable: Money(cents: 13_000), earnedNotTransferred: Money(cents: 3_000),
                interestAndMovements: Money(cents: 200), actualBalance: Money(cents: 10_200),
                records: [LedgerRecord(id: "savings-1", title: "Transfer in (attested)", detail: "Sample posted movement; no transfer initiated by app", amount: Money(cents: 10_000)),
                    LedgerRecord(id: "savings-2", title: "Interest", detail: "Not spendable", amount: Money(cents: 200))]),
            history: [HistoryWeek(weekStart: "2026-10-25", allowance: Money(cents: 37_500), increment: Money(cents: 0),
                debtIn: Money(cents: 0), debtOut: Money(cents: 0), spent: Money(cents: 30_000), surplus: Money(cents: 7_500),
                releaseStatus: "Pending · releases 7 days after actual close", revisionNote: "Revised after a late posted charge"),
                HistoryWeek(weekStart: "2026-10-18", allowance: Money(cents: 37_500), increment: Money(cents: 0),
                    debtIn: Money(cents: 0), debtOut: Money(cents: 0), spent: Money(cents: 32_000), surplus: Money(cents: 5_500),
                    releaseStatus: "Released", revisionNote: "")],
            audit: [AuditEvent(id: "audit-sample", actor: "Sample admin", action: "Fund request approved",
                detail: "Synthetic allocation recorded by the sample service.", date: instant)],
            sources: [SourceHealth(name: "Bank", status: "Sample connected account", lastUpdated: instant, freshness: .fresh),
                SourceHealth(name: "Email", status: "Preview only · native connection deferred", lastUpdated: nil, freshness: .unavailable),
                SourceHealth(name: "CSV", status: "No sample import yet", lastUpdated: nil, freshness: .neverSynced)])
    }
    private static func purchase(_ id: String, _ date: String, _ name: String, _ cents: Int64,
        _ suffix: String, _ source: String, _ state: String, kind: String = "charge",
        excluded: Bool = false, review: Bool = false) -> Purchase {
        Purchase(id: id, date: try! PurchaseDate(date), merchant: name, amount: Money(cents: cents),
            cardSuffix: suffix, source: source, state: state, kind: kind, excluded: excluded, needsReview: review,
            provenance: "Synthetic \(source) fixture. No real account or matching evidence.", allocation: Money(cents: 0),
            priorState: excluded ? .provisional : nil)
    }
}
