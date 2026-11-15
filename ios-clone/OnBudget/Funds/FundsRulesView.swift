import SwiftUI
import OnBudgetKit

// MARK: - Per-fund rules & info (owner, Nov 15, 2026)
//
// The old shared "Funds & Charity Rules" card is split by fund —
// the page reads as three fund sections now, and each fund's own
// pieces sit under its card:
// - Extra Fund: the shortfall line ("Nothing owed back right
//   now." / "Owed back now: $X.") lives under the Extra Fund card.
// - Charity: the Default Charity Rate editor lives under the
//   Charity card; How It Works opens from the ⓘ next to the label
//   (owner, Nov 15, 2026 — no longer an expandable row, and no
//   longer floating at the far right of the row).
// - Carried Debt (build 29): the Debt Repayment Rule editor lives
//   under the Carried Debt card.
// - Spending (build 30): the Weekly Allowance editor + Temporary
//   Allowance block live under the Spending card (moved from the
//   Settings Budget card — ALL fund settings live on the Funds page).
// Nothing was removed: the rate editor, the shortfall line, and
// the three How It Works blocks are the same content, just re-homed.
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
// The rate editor lives in CharityRateSection and nowhere else:
// the income form shows the current default rate but does not edit
// it, so the two can never disagree. Rate changes go through the
// live `set_charity_default_rate` RPC (admin-only, server-audited;
// `r13-charity.sql:126-149`); the view model toasts success in
// green (kind `.success`, owner rule Nov 11) and alerts on failure
// with a sanitised message, never raw server text.
//
// Visibility decision: the rate section is visible to every role,
// read-only for regular members ("Only the admin can change the
// default rate."). Members already see the fund and charity
// balances; hiding the rules that produce those numbers would
// leave them unexplained.

/// Default Charity Rate, under the Charity card: ONE compact row
/// (owner, Nov 15, 2026 — the old layout scattered the row: label
/// left, "20%" + ⓘ floating far right, field + Save + Reset on a
/// second line, a grey note on a third). Now the label, the ⓘ
/// (next to the label, where it belongs), the field with its %,
/// Save and Reset sit together on one row; the field IS the value,
/// so nothing floats far right. Only the pending-rate preview
/// shows below — the "already the default rate" note restated the
/// obvious and is gone. No heading — the "Default Charity Rate"
/// row says what it is, and the Charity card above is the section
/// header. The ⓘ opens How It Works as a popup (owner, Nov 15,
/// 2026 — the expandable row is gone); the content itself is
/// unchanged.
public struct CharityRateSection: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var rateText = ""
    @State private var rateError: String?
    /// The ⓘ beside the rate row opens How It Works as a sheet.
    @State private var showHowItWorks = false
    /// True inside the Charity fund container: no card of its own.
    public let bare: Bool

    public init(viewModel: FundsViewModel, bare: Bool = false) {
        self.viewModel = viewModel
        self.bare = bare
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
        Group {
            if bare {
                rateContent
                    .padding(.horizontal, 20)
            } else {
                FundsCard {
                    rateContent
                }
            }
        }
        .accessibilityIdentifier("funds.charityRate")
        .onAppear {
            if rateText.isEmpty { rateText = MoneyFormat.formatRateBp(defaultRateBp) }
        }
        .onChange(of: defaultRateBp) { _, newValue in
            // A saved rate (or a refresh) re-syncs the field so it
            // always shows the live default, not a stale edit.
            rateText = MoneyFormat.formatRateBp(newValue)
        }
        .sheet(isPresented: $showHowItWorks) {
            HowItWorksSheet(defaultRateBp: defaultRateBp)
        }
    }

    /// The rate row + editor, without chrome: the caller (the
    /// Charity fund container) wraps it, or FundsCard when
    /// standalone. Admins get the one-row editor; members get the
    /// read-only row (label + value) and the admin-only line.
    private var rateContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.charitySettings == nil {
                if let error = viewModel.charityError {
                    FundsErrorBox(error)
                } else {
                    FundsMuted("Loading rules…")
                }
            } else if isAdmin {
                rateEditor
            } else {
                HStack(spacing: 8) {
                    FundsBreakdownRow(
                        "Default Charity Rate",
                        value: "\(MoneyFormat.formatRateBp(defaultRateBp))%"
                    )
                    Button {
                        showHowItWorks = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How it works")
                }
                FundsMuted("Only the admin can change the default rate.")
            }
        }
    }

    // MARK: - Admin rate editor

    /// ONE compact row (owner, Nov 15, 2026): label + ⓘ + field
    /// with its % + Save + Reset, together. The field shows the
    /// live default, so there is no separate far-right value. Only
    /// the pending-rate preview shows below — the "already the
    /// default rate" and "enter a rate" notes restated the obvious
    /// and are gone; a bad Save still reports via the error box.
    private var rateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Default Charity Rate")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Button {
                    showHowItWorks = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How it works")
                TextField(MoneyFormat.formatRateBp(defaultRateBp), text: $rateText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 56)
                Text("%")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                FundsSmallPrimaryButton("Save", isBusy: viewModel.busyAction == "rate") {
                    saveRate()
                }
                FundsQuietButton("Reset") {
                    rateText = MoneyFormat.formatRateBp(defaultRateBp)
                    rateError = nil
                }
            }
            if let pending = pendingRateBp {
                FundsMuted("New incomes will commit \(MoneyFormat.formatRateBp(pending))% — future incomes only. Past incomes stay as they are.")
            }
            if let rateError {
                FundsErrorBox(rateError)
            }
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

/// The Extra Fund shortfall line, directly under the Extra Fund
/// card: "Nothing owed back right now." or "Owed back now: $X."
/// A bare muted line, not a card — the horizontal padding lines
/// it up with the card's interior text. It reads the fund summary
/// on its own: unlike the old shared rules card, it no longer
/// waits for the charity settings to load first (its own loading
/// and error lines cover those states).
public struct FundShortfallLine: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if let summary = viewModel.fundSummary {
                FundsMuted(
                    summary.shortfallCents > 0
                        ? "Owed back now: \(MoneyFormat.formatCents(summary.shortfallCents))."
                        : "Nothing owed back right now."
                )
            } else if viewModel.fundError != nil {
                // The shortfall line stays visible even when the fund
                // fails to load, with an error note in its place
                // (F-P2-9).
                FundsMuted("Owed back: could not load fund balances — try again.")
            } else {
                FundsMuted("Owed back: loading…")
            }
        }
        .padding(.horizontal, 20)
        .accessibilityIdentifier("funds.shortfall")
    }
}

/// How It Works, as a popup (owner, Nov 15, 2026 — the expandable
/// row under the Charity card is gone; the ⓘ at the right of the
/// Default Charity Rate row opens this sheet instead). The three
/// rule blocks are unchanged.
public struct HowItWorksSheet: View {
    public let defaultRateBp: Int
    @Environment(\.dismiss) private var dismiss

    public init(defaultRateBp: Int) {
        self.defaultRateBp = defaultRateBp
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "How It Works") { dismiss() }
            HowItWorksContent(defaultRateBp: defaultRateBp)
            Spacer(minLength: 0)
        }
        .padding()
        .presentationDetents([.medium, .large])
        .presentationBackground(.white)
    }
}

/// The three rule blocks: Charity Basis, Rate per Entry, Extra Fund
/// Top-Ups.
public struct HowItWorksContent: View {
    public let defaultRateBp: Int

    public init(defaultRateBp: Int) {
        self.defaultRateBp = defaultRateBp
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ruleBlock(
                title: "Charity Basis",
                text: "Charity is \(MoneyFormat.formatRateBp(defaultRateBp))% of money actually received and manually entered amounts, from November 2026. Transfers, refunds, reimbursements, loans, and Extra Fund top-ups do not count on their own — nothing is pulled in automatically."
            )
            ruleBlock(
                title: "Rate per Entry",
                text: "A rate set on one income replaces the default for that entry only — it never adds to it. Correcting an old income reverses it and adds a replacement; the old entry stays, marked reversed."
            )
            ruleBlock(
                title: "Extra Fund Top-Ups",
                text: "Money added covers what the fund owes back first, then the rest increases spendable Available. The Add Money form shows that split before you save."
            )
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
}

/// Debt Repayment Rule, under the Carried Debt card (build 29): the
/// rule row plus the admin editor (Percent / Fixed $ / Off + value
/// + Save, Reset a small quiet link) and the preview line. Same
/// compact pattern as the Charity rate editor (owner, Nov 15,
/// 2026): the label, the mode picker, the field with its unit, Save
/// and Reset sit together — the field IS the value, so nothing
/// floats far right. No heading — the "Debt Repayment Rule" row
/// says what it is, and the Carried Debt card above is the section
/// header. A rule change is future-only: it applies to the current
/// open week and future weeks; closed weeks keep their stored
/// payment. The rule lives here and nowhere else — never in
/// Settings (owner, Nov 15, 2026: ALL fund-related settings belong
/// on the Funds page).
///
/// Visibility decision: the rule section is visible to every role,
/// read-only for regular members ("Only the admin can change the
/// debt repayment rule."). Members already see the debt balance;
/// hiding the rule that produces this week's payment would leave
/// it unexplained.
public struct DebtRuleSection: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var selectedMode: DebtRule.Mode = .percent
    @State private var percentText = ""
    @State private var fixedText = ""
    @State private var ruleError: String?
    /// True inside the Carried Debt fund container: no card of its own.
    public let bare: Bool

    public init(viewModel: FundsViewModel, bare: Bool = false) {
        self.viewModel = viewModel
        self.bare = bare
    }

    private var isAdmin: Bool { viewModel.context.isAdmin }
    private var savedRule: DebtRule { viewModel.debtRule ?? .default }

    /// The rule the admin has picked in the editor, when it parses.
    private var pendingRule: DebtRule? {
        switch selectedMode {
        case .percent:
            guard let bp = MoneyFormat.parseRatePercent(percentText) else { return nil }
            return DebtRule(mode: .percent, percentBp: bp)
        case .fixed:
            guard let cents = MoneyFormat.parseDollarsStrict(fixedText), cents > 0 else { return nil }
            return DebtRule(mode: .fixed, fixedCents: cents)
        case .off:
            return DebtRule(mode: .off)
        }
    }

    /// True when the editor holds a valid rule that differs from the
    /// saved one — the only case the preview describes the new rule.
    private var pendingDiffers: Bool {
        guard let pending = pendingRule else { return false }
        return pending != savedRule
    }

    private var ruleText: String {
        switch savedRule.mode {
        case .percent: return "\(MoneyFormat.formatRateBp(savedRule.percentBp))% of Base"
        case .fixed: return "\(MoneyFormat.formatCents(savedRule.fixedCents)) per Week"
        case .off: return "Off"
        }
    }

    public var body: some View {
        Group {
            if bare {
                ruleContent
                    .padding(.horizontal, 20)
            } else {
                FundsCard {
                    ruleContent
                }
            }
        }
        .accessibilityIdentifier("funds.debtRule")
        .onAppear { syncFromSaved() }
        .onChange(of: savedRule) { _, _ in syncFromSaved() }
    }

    /// The rule row + editor, without chrome: the caller (the
    /// Carried Debt fund container) wraps it, or FundsCard when
    /// standalone. Admins get the compact editor; members get the
    /// read-only row (label + value) and the admin-only line.
    private var ruleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.debtRule == nil {
                if let error = viewModel.debtError {
                    FundsErrorBox(error)
                } else {
                    FundsMuted("Loading rules…")
                }
            } else if isAdmin {
                ruleEditor
            } else {
                FundsBreakdownRow("Debt Repayment Rule", value: ruleText)
                FundsMuted("Only the admin can change the debt repayment rule.")
            }
        }
    }

    private func syncFromSaved() {
        selectedMode = savedRule.mode
        percentText = MoneyFormat.formatRateBp(savedRule.percentBp)
        fixedText = savedRule.fixedCents > 0 ? String(format: "%.2f", Double(savedRule.fixedCents) / 100.0) : ""
    }

    /// The compact editor (owner, Nov 15, 2026 — same pattern as
    /// the Charity rate editor): label + mode picker on one row,
    /// then the field with its unit + Save + Reset on the next.
    /// The field IS the value, so nothing floats far right. The
    /// preview shows below only when it says something useful.
    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Debt Repayment Rule")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Picker("Rule", selection: $selectedMode) {
                    Text("Percent").tag(DebtRule.Mode.percent)
                    Text("Fixed $").tag(DebtRule.Mode.fixed)
                    Text("Off").tag(DebtRule.Mode.off)
                }
                .pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                if selectedMode == .percent {
                    TextField(MoneyFormat.formatRateBp(savedRule.percentBp), text: $percentText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 56)
                    Text("% of base")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                } else if selectedMode == .fixed {
                    DollarTextField(text: $fixedText, placeholder: "0.00", maxWidth: 140)
                }
                FundsSmallPrimaryButton("Save", isBusy: viewModel.busyAction == "debt-rule") {
                    saveRule()
                }
                FundsQuietButton("Reset") {
                    syncFromSaved()
                    ruleError = nil
                }
            }
            previewLine
            if let ruleError {
                FundsErrorBox(ruleError)
            }
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        if pendingDiffers, let pending = pendingRule {
            // The preview describes the PENDING rule, from the base
            // only — the same caps the server applies.
            if let base = viewModel.baseAllowanceCents, let debt = viewModel.debtBalanceCents {
                let payment = DebtRule.paymentCents(baseCents: base, debtCents: debt, rule: pending)
                FundsMuted("Each week \(MoneyFormat.formatCents(payment)) goes to debt — the week starts at \(MoneyFormat.formatCents(base - payment)). Future weeks only; closed weeks keep their stored payment.")
            } else {
                FundsMuted("Each week \(pendingRuleText(pending)) goes to debt. Future weeks only; closed weeks keep their stored payment.")
            }
        } else if savedRule.mode == .off {
            FundsMuted("The rule is off — no part of the base goes to debt each week. Unspent allowance at week close still pays the debt first.")
        } else if let preview = viewModel.debtPaymentPreview() {
            FundsMuted("Each week \(MoneyFormat.formatCents(preview.payment)) goes to debt — the week starts at \(MoneyFormat.formatCents(preview.weekStartsAt)).")
        }
        // No "Enter a value" line (build 30): an empty field states
        // itself; the note restated the obvious. A bad Save still
        // reports via the error box.
    }

    private func pendingRuleText(_ rule: DebtRule) -> String {
        switch rule.mode {
        case .percent: return "\(MoneyFormat.formatRateBp(rule.percentBp))% of the base"
        case .fixed: return MoneyFormat.formatCents(rule.fixedCents)
        case .off: return "nothing"
        }
    }

    private func saveRule() {
        guard let pending = pendingRule else {
            ruleError = selectedMode == .percent
                ? "Enter a percent between 0 and 100."
                : "Enter an amount over $0."
            return
        }
        guard pending != savedRule else {
            ruleError = "That is already the rule."
            return
        }
        if pending.mode == .fixed,
           let base = viewModel.baseAllowanceCents,
           pending.fixedCents > base {
            ruleError = "The fixed amount cannot be more than the base allowance (\(MoneyFormat.formatCents(base)))."
            return
        }
        ruleError = nil
        Task { await viewModel.setDebtRule(pending) }
    }
}

/// Weekly Allowance, under the Spending card (build 30 — moved from
/// the Settings Budget card; owner, Nov 15, 2026: ALL fund settings
/// live on the Funds page, and the base allowance is the spending
/// fund's setting). The row + the admin editor (field + Save sized
/// to fit, Reset a small quiet link) and the preview line, then the
/// Temporary Allowance block below it. No heading — the "Weekly
/// Allowance" row says what it is, and the Spending card above is
/// the section header. A change applies from the current week
/// onward; closed weeks are never rewritten (the confirm dialog
/// says so, as the Settings card did).
///
/// Visibility decision (same as the rate/rule sections): visible to
/// every role, read-only for regular members ("Only the admin can
/// change the weekly allowance."). Members already see the week's
/// allowance; hiding the setting that produces it would leave it
/// unexplained.
public struct SpendingAllowanceSection: View {
    @ObservedObject public var viewModel: FundsViewModel
    @State private var allowanceText = ""
    @State private var allowanceError: String?
    @State private var confirmChange: AllowanceConfirm?
    /// True inside the Spending fund container: no card of its own.
    public let bare: Bool
    /// Opens the Temporary Allowance form (owned by FundsView).
    public let onOpenTemp: () -> Void

    public init(viewModel: FundsViewModel, bare: Bool = false, onOpenTemp: @escaping () -> Void) {
        self.viewModel = viewModel
        self.bare = bare
        self.onOpenTemp = onOpenTemp
    }

    private struct AllowanceConfirm: Identifiable {
        let oldCents: Int?
        let newCents: Int
        var id: String { "change-\(newCents)" }
    }

    private var isAdmin: Bool { viewModel.context.isAdmin }
    private var savedBase: Int? { viewModel.baseAllowanceCents }

    private var pendingCents: Int? {
        MoneyFormat.parseDollarsStrict(allowanceText)
    }

    private var pendingDiffers: Bool {
        guard let pending = pendingCents, let base = savedBase else { return false }
        return pending != base
    }

    /// The week's temporary total, when a Temporary Allowance
    /// override is in effect for the current week.
    private var tempOverrideCents: Int? {
        viewModel.debtWeek?.overrideCents
    }

    public var body: some View {
        Group {
            if bare {
                allowanceContent
                    .padding(.horizontal, 20)
            } else {
                FundsCard {
                    allowanceContent
                }
            }
        }
        .accessibilityIdentifier("funds.spendingAllowance")
        .onAppear { syncField() }
        .onChange(of: savedBase) { _, _ in syncField() }
        .alert(item: $confirmChange) { change in
            let message: String
            if let old = change.oldCents {
                message = "Change the weekly allowance from \(MoneyFormat.formatCents(old)) to \(MoneyFormat.formatCents(change.newCents))?\nThis applies from the current week onward. It does not rewrite closed weeks."
            } else {
                message = "Set the weekly allowance to \(MoneyFormat.formatCents(change.newCents))?\nThis applies from the current week onward. It does not rewrite closed weeks."
            }
            return Alert(
                title: Text("Change Allowance"),
                message: Text(message),
                primaryButton: .default(Text("Change Allowance")) {
                    Task { await viewModel.setBaseAllowance(cents: change.newCents) }
                },
                secondaryButton: .cancel(Text("Keep Current"))
            )
        }
    }

    /// The row + editor + Temporary Allowance block, without chrome:
    /// the caller (the Spending fund container) wraps it, or
    /// FundsCard when standalone.
    private var allowanceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let base = savedBase {
                FundsBreakdownRow("Weekly Allowance", value: MoneyFormat.formatCents(base))
                if isAdmin {
                    allowanceEditor
                } else {
                    FundsMuted("Only the admin can change the weekly allowance.")
                }
                tempBlock
            } else if let error = viewModel.allowanceError {
                FundsErrorBox(error)
                FundsSmallTertiaryButton("Try Again") {
                    Task { await viewModel.reloadAllowance() }
                }
            } else {
                FundsMuted("Loading allowance…")
            }
        }
    }

    private func syncField() {
        if let base = savedBase {
            allowanceText = String(format: "%.2f", Double(base) / 100)
        }
    }

    private var allowanceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DollarTextField(text: $allowanceText, placeholder: "0.00", maxWidth: 140)
                FundsSmallPrimaryButton("Save", isBusy: viewModel.busyAction == "base-allowance") {
                    saveTapped()
                }
                FundsQuietButton("Reset") {
                    syncField()
                    allowanceError = nil
                }
            }
            if pendingDiffers {
                FundsMuted("Applies from the current week onward. It does not rewrite closed weeks.")
            } else if pendingCents != nil {
                FundsMuted("This is already the weekly allowance.")
            } else {
                FundsMuted("Enter a valid allowance (empty is not 0).")
            }
            if let allowanceError {
                FundsErrorBox(allowanceError)
            }
        }
    }

    private func saveTapped() {
        guard let cents = pendingCents, cents >= 0 else {
            allowanceError = "Enter a valid allowance (empty is not 0)."
            return
        }
        guard pendingDiffers else {
            allowanceError = "That is already the weekly allowance."
            return
        }
        allowanceError = nil
        confirmChange = AllowanceConfirm(oldCents: savedBase, newCents: cents)
    }

    private var tempBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            FundsBreakdownRow(
                "Temporary Allowance",
                value: tempOverrideCents.map { MoneyFormat.formatCents($0) } ?? "Not set"
            )
            if let temp = tempOverrideCents, let base = savedBase, temp != base {
                FundsMuted("This week's total is \(MoneyFormat.formatCents(temp)) instead of \(MoneyFormat.formatCents(base)).")
            }
            if isAdmin {
                FundsSmallTertiaryButton(tempOverrideCents == nil ? "Set Temporary Allowance" : "Change Temporary Allowance") {
                    onOpenTemp()
                }
            }
        }
    }
}
