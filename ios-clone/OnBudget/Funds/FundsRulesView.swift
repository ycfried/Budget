import SwiftUI
import OnBudgetKit

// MARK: - Funds & Charity Rules (admin edits, everyone reads)
//
// Owner rules, Nov 3, 2026 (R12 + R13, HANDOFF.md):
// - Charity: 10% of money actually received + manually entered
//   amounts, from November 2026. Transfers, refunds,
//   reimbursements, loans, and Extra Fund top-ups do NOT auto-accrue.
// - Default charity rate: changeable by the admin; a change applies
//   to future incomes only — past incomes stay as they are, unless
//   an old income is corrected (append-only reversal + replacement
//   via `correct_charity_income`, in the income form).
// - Per-entry rate override REPLACES the default for that entry
//   only; it never stacks on top of it.
// - Extra Fund top-ups cover what the fund owes back FIRST; the
//   remainder increases spendable Available (the Add Money form
//   previews that split before saving; the server split is
//   authoritative).
//
// The rate editor lives HERE and nowhere else: the income form
// shows the current default rate but does not edit it, so the two
// can never disagree. Rate changes go through the live
// `set_charity_default_rate` RPC (admin-only, server-audited;
// `r13-charity.sql:126-149`); the view model toasts success in
// green (kind `.success`, owner rule Nov 11) and alerts on failure
// with a sanitised message, never raw server text.
//
// Visibility decision: the section is visible to every role,
// read-only for regular members ("Only the admin can change the
// default rate."). Members already see the fund and charity
// balances; hiding the rules that produce those numbers would
// leave them unexplained.

public struct FundsRulesSection: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var rateText = ""
    @State private var rateError: String?

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var isAdmin: Bool { viewModel.context.isAdmin }
    private var defaultRateBp: Int { viewModel.charitySettings?.defaultRateBp ?? 1000 }

    /// The rate the admin typed, when it parses and differs from
    /// the live default — the only case a preview is shown for.
    private var pendingRateBp: Int? {
        guard let bp = MoneyFormat.parseRatePercent(rateText), bp != defaultRateBp else { return nil }
        return bp
    }

    public var body: some View {
        FundsCard {
            VStack(alignment: .leading, spacing: 12) {
                FundsHeading("Funds & Charity Rules")
                if viewModel.charitySettings == nil {
                    if let error = viewModel.charityError {
                        FundsErrorBox(error)
                    } else {
                        FundsMuted("Loading rules…")
                    }
                } else {
                    FundsBreakdownRow(
                        "Default Charity Rate",
                        value: "\(MoneyFormat.formatRateBp(defaultRateBp))%"
                    )
                    if isAdmin {
                        rateEditor
                    } else {
                        FundsMuted("Only the admin can change the default rate.")
                    }
                }
                Divider()
                ruleBlock(
                    title: "Charity Basis",
                    text: "Charity is \(MoneyFormat.formatRateBp(defaultRateBp))% of money actually received and manually entered amounts, from November 2026. Transfers, refunds, reimbursements, loans, and Extra Fund top-ups do not count on their own — nothing is pulled in automatically."
                )
                ruleBlock(
                    title: "Rate per Entry",
                    text: "A rate set on one income replaces the default for that entry only — it never adds to it. Correcting an old income reverses it and adds a replacement; the old entry stays, marked reversed."
                )
                Divider()
                ruleBlock(
                    title: "Extra Fund Top-Ups",
                    text: "Money added covers what the fund owes back first, then the rest increases spendable Available. The Add Money form shows that split before you save."
                )
                if let summary = viewModel.fundSummary {
                    FundsMuted(
                        summary.shortfallCents > 0
                            ? "Owed back now: \(MoneyFormat.formatCents(summary.shortfallCents))."
                            : "Nothing owed back right now."
                    )
                }
            }
        }
        .accessibilityIdentifier("funds.rules")
        .onAppear {
            if rateText.isEmpty { rateText = MoneyFormat.formatRateBp(defaultRateBp) }
        }
        .onChange(of: defaultRateBp) { _, newValue in
            // A saved rate (or a refresh) re-syncs the field so it
            // always shows the live default, not a stale edit.
            rateText = MoneyFormat.formatRateBp(newValue)
        }
    }

    // MARK: - Admin rate editor

    private var rateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Rate (%)")
                        .font(.system(size: 14, weight: .semibold))
                    TextField(MoneyFormat.formatRateBp(defaultRateBp), text: $rateText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("")
                        .font(.system(size: 14, weight: .semibold))
                    FundsPrimaryButton("Save Default Rate", isBusy: viewModel.busyAction == "rate") {
                        saveRate()
                    }
                }
            }
            if let pending = pendingRateBp {
                FundsMuted("New incomes will commit \(MoneyFormat.formatRateBp(pending))% — future incomes only. Past incomes stay as they are.")
            } else if MoneyFormat.parseRatePercent(rateText) != nil {
                FundsMuted("This is already the default rate.")
            } else {
                FundsMuted("Affects future incomes only.")
            }
            if let rateError {
                FundsErrorBox(rateError)
            }
            HStack(spacing: 12) {
                FundsTertiaryButton("Reset") {
                    rateText = MoneyFormat.formatRateBp(defaultRateBp)
                    rateError = nil
                }
            }
        }
    }

    private func ruleBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TitleCase.apply(to: title))
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    private func saveRate() {
        guard let bp = MoneyFormat.parseRatePercent(rateText) else {
            rateError = "Enter a rate between 0 and 100."
            return
        }
        guard bp != defaultRateBp else {
            rateError = "That is already the default rate."
            return
        }
        rateError = nil
        Task { await viewModel.setDefaultRate(basisPoints: bp) }
    }
}
