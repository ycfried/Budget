// MARK: - Debt ledger (build 69, owner Nov 24, 2026)
//
// The Overspent (Past) fund's "Where It Came From" used to show the
// debt balance at the END of each closed week (week_closes
// .outgoing_debt_cents) — cumulative balances that do NOT add up to
// the current total, so the owner could not see where the debt came
// from ("nothing tappable.. a bit unclear"). The ledger replaces it
// with what each week/event DID to the debt, with +/-, so the rows
// add up exactly to the current debt:
//
//   Week of Nov 1:   +$4,058.16 overspent
//   Week of Nov 8:   -$179.99 surplus paid toward debt
//   Nov 16:          -$2,988.24 cleared
//   Week of Nov 15:  +$238.03 overspent
//   = $1,127.96 now
//
// Derivation (no hardcoding — the per-week overspend is NOT stored
// anywhere; the engine's newDebt is never persisted). The debt
// balance evolves as
//
//   D(W) = D(W-1) + overspend(W) - payments(W) + adjustments(W)
//
// where D(W) is the week's outgoing_debt_cents, payments(W) is
// every debt_payments row attributed to week W (by week_start),
// and adjustments(W) is every debt_adjustments row attributed to
// week W (signed amountCents). So
//
//   overspend(W) = D(W) - D(W-1) + payments(W) - adjustments(W)
//
// and the ledger is: one +overspend entry per week that overspent,
// one -payment entry per debt payment, one signed entry per manual
// adjustment. Summing them telescopes to D(last close) minus the
// payments/adjustments since that close — i.e. the current debt,
// provided compute-week's carriedDebtCents accounts for them the
// same way (it does: it is the same engine).
//
// A week that did not overspend gets no week entry — its effect is
// already in its payment entries (e.g. a surplus week shows only
// the "surplus paid toward debt" payment). A negative overspend
// (the balances fell by more than the recorded payments —
// inconsistent data) is clamped to 0 and gets no entry, so the
// ledger never shows a fabricated negative overspend.
//
// Ordering is chronological by when each item became known: week
// entries sort by their close's created_at (the week is only known
// at close), payments/adjustments by their created_at — falling
// back to week_start when a timestamp is missing. That is the
// order the owner wrote it in (the Nov 16 clear before the Nov 15
// week's result, which only closed Nov 22).

public struct DebtLedgerEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A week that overspent: +overspend.
        case week
        /// A debt payment: -amount.
        case payment
        /// A manual Add/Set: signed amount.
        case adjustment
    }

    public let id: String
    public let kind: Kind
    /// The Sunday starting the week this entry belongs to.
    public let weekStart: String
    /// "Week of Nov 1, 2026" for a week row, "Nov 16, 2026" for a
    /// payment/adjustment row.
    public let title: String
    /// "Overspent", "Surplus paid toward debt", "Cleared",
    /// "Paid from Extra Fund", "Added to debt", "Set to …".
    public let subtitle: String
    /// SIGNED cents: + overspend / added, - payment / reduction.
    public let amountCents: Int
    /// The week's close, for a week row (the detail sheet reads
    /// the weekStart and the overspend from it).
    public let weekClose: WeekClose?
    /// The week's overspend, for a week row.
    public let weekOverspendCents: Int?
    /// The payment, for a payment row (the detail sheet reads
    /// amount, source, date, week, note from it).
    public let payment: DebtPayment?
    /// The adjustment, for an adjustment row.
    public let adjustment: DebtAdjustment?

    public init(
        id: String,
        kind: Kind,
        weekStart: String,
        title: String,
        subtitle: String,
        amountCents: Int,
        weekClose: WeekClose? = nil,
        weekOverspendCents: Int? = nil,
        payment: DebtPayment? = nil,
        adjustment: DebtAdjustment? = nil
    ) {
        self.id = id
        self.kind = kind
        self.weekStart = weekStart
        self.title = title
        self.subtitle = subtitle
        self.amountCents = amountCents
        self.weekClose = weekClose
        self.weekOverspendCents = weekOverspendCents
        self.payment = payment
        self.adjustment = adjustment
    }
}

public enum DebtLedger {
    /// Build the ledger from the closed weeks, the debt payments
    /// and the manual adjustments. `debtName` / `extraFundName`
    /// are the funds' CURRENT display names (build 43) — the
    /// payment subtitles read them, never hardcoded names.
    public static func build(
        closes: [WeekClose],
        payments: [DebtPayment],
        adjustments: [DebtAdjustment],
        debtName: String = "Carried Debt",
        extraFundName: String = "Extra Fund"
    ) -> [DebtLedgerEntry] {
        // The closes arrive newest-first; the derivation walks
        // them oldest-first so each week's "previous balance" is
        // the close before it.
        let ascending = closes.sorted { $0.weekStart < $1.weekStart }
        var entries: [DebtLedgerEntry] = []
        // Sort key per entry (when it became known), kept
        // alongside so the final sort is one pass.
        var sortKeys: [String: String] = [:]

        let paymentsByWeek: [String: [DebtPayment]] = Dictionary(grouping: payments, by: \.weekStart)
        let adjustmentsByWeek: [String: [DebtAdjustment]] = Dictionary(grouping: adjustments, by: \.weekStart)

        for (index, close) in ascending.enumerated() {
            let previousDebt = index == 0 ? 0 : ascending[index - 1].outgoingDebtCents
            let paymentsW = (paymentsByWeek[close.weekStart] ?? []).reduce(0) { $0 + $1.amountCents }
            let adjustmentsW = (adjustmentsByWeek[close.weekStart] ?? []).reduce(0) { $0 + $1.amountCents }
            let overspend = close.outgoingDebtCents - previousDebt + paymentsW - adjustmentsW
            guard overspend > 0 else { continue }
            let id = "week-\(close.weekStart)"
            entries.append(DebtLedgerEntry(
                id: id,
                kind: .week,
                weekStart: close.weekStart,
                title: "Week of \(MoneyFormat.fmtLong(close.weekStart))",
                subtitle: "Overspent",
                amountCents: overspend,
                weekClose: close,
                weekOverspendCents: overspend
            ))
            sortKeys[id] = close.createdAt ?? close.weekStart
        }

        for payment in payments {
            let label: String
            switch payment.source {
            case "extra_fund": label = "Paid from \(extraFundName)"
            case "surplus": label = "Surplus paid toward debt"
            case "clear": label = "\(debtName) Cleared"
            default: label = "\(debtName) Payment"
            }
            let id = "payment-\(payment.id.uuidString)"
            entries.append(DebtLedgerEntry(
                id: id,
                kind: .payment,
                weekStart: payment.weekStart,
                title: payment.createdAt.map { MoneyFormat.displayDay($0) } ?? "Week of \(MoneyFormat.fmtLong(payment.weekStart))",
                subtitle: label,
                amountCents: -payment.amountCents,
                payment: payment
            ))
            sortKeys[id] = payment.createdAt ?? payment.weekStart
        }

        for adjustment in adjustments {
            let (subtitle, amount): (String, Int)
            if adjustment.kind == "set" {
                subtitle = "\(debtName) Set to \(MoneyFormat.formatCents(adjustment.balanceAfterCents))"
                amount = adjustment.amountCents
            } else {
                subtitle = "\(debtName) Added"
                amount = adjustment.amountCents
            }
            let id = "adjustment-\(adjustment.id.uuidString)"
            entries.append(DebtLedgerEntry(
                id: id,
                kind: .adjustment,
                weekStart: adjustment.weekStart,
                title: adjustment.createdAt.map { MoneyFormat.displayDay($0) } ?? "Week of \(MoneyFormat.fmtLong(adjustment.weekStart))",
                subtitle: subtitle,
                amountCents: amount,
                adjustment: adjustment
            ))
            sortKeys[id] = adjustment.createdAt ?? adjustment.weekStart
        }

        // Chronological by when each item became known (the ISO
        // timestamps sort as strings). Ties — a week and a payment
        // known the same day — keep the week's entry first, so the
        // week's result reads before the payment inside it.
        return entries.sorted { a, b in
            let ka = sortKeys[a.id] ?? a.weekStart
            let kb = sortKeys[b.id] ?? b.weekStart
            if ka != kb { return ka < kb }
            if a.kind != b.kind { return a.kind == .week }
            return a.id < b.id
        }
    }

    /// The ledger's total — the current debt, by construction.
    public static func totalCents(_ entries: [DebtLedgerEntry]) -> Int {
        entries.reduce(0) { $0 + $1.amountCents }
    }
}
