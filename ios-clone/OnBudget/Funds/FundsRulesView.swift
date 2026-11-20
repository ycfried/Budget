import SwiftUI
import OnBudgetKit

// MARK: - Per-fund rules & info (owner, Nov 15, 2026)
//
// The old shared "Funds & Charity Rules" card is split by fund —
// the page reads as three fund sections now, and each fund's own
// pieces sit under its card:
// - Extra Fund: a shortfall is shown as a labelled "Shortfall"
//   row in the card's own detail, only when one exists (owner,
//   Nov 15, 2026 — build 33: the old "Nothing owed back right
//   now." sentence was confusing — "owed back" is internal
//   machinery — and when nothing is owed the $0.00 face already
//   says the fund is empty, so nothing shows at all).
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
    /// The household's custom fund names (build 43, owner Nov 17,
    /// 2026 — item 16): the "Default <fund> Rate" label and the
    /// How It Works copy read the fund's CURRENT display name.
    public let fundNames: [String: String]

    public init(viewModel: FundsViewModel, bare: Bool = false, fundNames: [String: String] = [:]) {
        self.viewModel = viewModel
        self.bare = bare
        self.fundNames = fundNames
    }

    private var charityName: String { FundSectionID.charity.displayName(customNames: fundNames) }

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
                // No extra horizontal padding (build 33): the
                // section lives inside the card's expanded detail,
                // which is already padded 20pt — padding here would
                // double it to 40.
                rateContent
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
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(isPresented: $showHowItWorks) {
            HowItWorksSheet(defaultRateBp: defaultRateBp, fundNames: fundNames)
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
                        "Default \(charityName) Rate",
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

    /// ONE editor, the same shape as the other fund editors
    /// (owner, Nov 15, 2026 — build 33: the old one-row layout
    /// truncated the label to "Default..." and wrapped Reset to
    /// two lines). The label sits on its own line with the ⓘ beside
    /// it — it can never truncate — and the field, %, Save and
    /// Reset sit together on the row below. The field IS the value,
    /// so nothing floats far right. Only the pending-rate preview
    /// shows below — the "already the default rate" note restated
    /// the obvious and is gone. No heading — the "Default Charity
    /// Rate" row says what it is, and the Charity card above is the
    /// section header. The ⓘ opens How It Works as a popup (owner,
    /// Nov 15, 2026 — the expandable row is gone); the content
    /// itself is unchanged.
    private var rateEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Default \(charityName) Rate")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
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
            HStack(spacing: 8) {
                // Build 36 (owner, Nov 16, 2026): the editor controls
                // were small and cheap — the field is now 17pt /
                // 48pt tall and the Save / Reset are the editor
                // sizes, not the small list-row sizes. The value is
                // untouched: the field still shows the live default.
                // Owner, Nov 16, 2026 (build 40): the "%" is a LEFT
                // prefix INSIDE the field ("Percent sign on the
                // left."), mirroring the "$" prefix in
                // DollarTextField — nothing sits on the right.
                HStack(spacing: 2) {
                    Text("%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField(MoneyFormat.formatRateBp(defaultRateBp), text: $rateText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17))
                }
                .padding(.horizontal, 12)
                // Build 37 (owner, Nov 16, 2026): the field
                // expands to fill the row — the 72pt field left
                // a large empty space on the right. Save and
                // Reset sit at the row's right end.
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                FundsEditorPrimaryButton("Save", isBusy: viewModel.busyAction == "rate") {
                    saveRate()
                }
                FundsEditorQuietButton("Reset") {
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

/// How It Works, as a popup (owner, Nov 15, 2026 — the expandable
/// row under the Charity card is gone; the ⓘ at the right of the
/// Default Charity Rate row opens this popup instead). The three
/// rule blocks are unchanged.
public struct HowItWorksSheet: View {
    public let defaultRateBp: Int
    public let fundNames: [String: String]
    @Environment(\.dismiss) private var dismiss

    public init(defaultRateBp: Int, fundNames: [String: String] = [:]) {
        self.defaultRateBp = defaultRateBp
        self.fundNames = fundNames
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "How It Works") { dismiss() }
            HowItWorksContent(defaultRateBp: defaultRateBp, fundNames: fundNames)
            // The trailing Spacer top-anchors the content in the
            // full-screen cover (build 43, item 18) — without it
            // the short content centres itself vertically.
            Spacer(minLength: 0)
        }
        .padding()
    }
}

/// The three rule blocks: charity Basis, Rate per Entry, fund
/// Top-Ups — each titled with the fund's CURRENT display name
/// (build 43, item 16).
public struct HowItWorksContent: View {
    public let defaultRateBp: Int
    public let fundNames: [String: String]

    public init(defaultRateBp: Int, fundNames: [String: String] = [:]) {
        self.defaultRateBp = defaultRateBp
        self.fundNames = fundNames
    }

    private var charityName: String { FundSectionID.charity.displayName(customNames: fundNames) }
    private var extraFundName: String { FundSectionID.fund.displayName(customNames: fundNames) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ruleBlock(
                title: "\(charityName) Basis",
                text: "\(charityName) is \(MoneyFormat.formatRateBp(defaultRateBp))% of money actually received and manually entered amounts, from November 2026. Transfers, refunds, reimbursements, loans, and \(extraFundName) top-ups do not count on their own — nothing is pulled in automatically."
            )
            ruleBlock(
                title: "Rate per Entry",
                text: "A rate set on one income replaces the default for that entry only — it never adds to it. Correcting an old income reverses it and adds a replacement; the old entry stays, marked reversed."
            )
            ruleBlock(
                title: "\(extraFundName) Top-Ups",
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
/// rule row plus the admin editor (% / Fixed $ / Off + value +
/// Save, Reset a small quiet link). Same compact pattern as the
/// Charity rate editor (owner, Nov 15, 2026): the label, the mode
/// picker, the field with its unit, Save and Reset sit together —
/// the field IS the value, so nothing floats far right. No heading
/// — the "Debt Repayment Rule" row says what it is, and the
/// Carried Debt card above is the section header. A rule change is
/// future-only: it applies to the current open week and future
/// weeks; closed weeks keep their stored payment. The rule lives
/// here and nowhere else — never in Settings (owner, Nov 15, 2026:
/// ALL fund-related settings belong on the Funds page).
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
    /// The household's custom fund names (build 43, owner Nov 17,
    /// 2026 — item 16): the "<debt> Repayment Rule" label reads
    /// the debt fund's CURRENT display name.
    public let fundNames: [String: String]

    public init(viewModel: FundsViewModel, bare: Bool = false, fundNames: [String: String] = [:]) {
        self.viewModel = viewModel
        self.bare = bare
        self.fundNames = fundNames
    }

    private var debtName: String { FundSectionID.debt.displayName(customNames: fundNames) }

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
                // No extra horizontal padding (build 33): see
                // CharityRateSection — the card's detail already
                // pads 20pt.
                ruleContent
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
                FundsBreakdownRow("\(debtName) Repayment Rule", value: ruleText)
                FundsMuted("Only the admin can change the debt repayment rule.")
            }
        }
    }

    private func syncFromSaved() {
        selectedMode = savedRule.mode
        percentText = MoneyFormat.formatRateBp(savedRule.percentBp)
        fixedText = savedRule.fixedCents > 0 ? String(format: "%.2f", Double(savedRule.fixedCents) / 100.0) : ""
    }

    /// The editor (owner, Nov 15, 2026 — build 33): the label on its
    /// own line so it can never truncate, the mode picker
    /// full-width on the next row, then the field on its own row,
    /// then Save + Reset on their own row, each 1/2 the width
    /// (owner, Nov 16, 2026 — build 37: the small Save / quiet
    /// Reset bunched on the left left a large empty space on the
    /// right). The picker uses "%" for Percent (owner rule: a word
    /// that does not fit becomes a symbol, never a truncation —
    /// "Percent" was rendering as "Perc...") and "$" for Fixed
    /// (owner, Nov 16, 2026 — build 37: the word "Fixed" is gone,
    /// the dollar sign alone is clear enough). The field IS the
    /// value, so nothing floats far right. There is NO preview
    /// paragraph under the editor (owner, Nov 15, 2026 — build 33:
    /// the "Each week $X goes to debt…" paragraph restated what the
    /// card already shows — This Week's Payment, Remaining After
    /// This Week, the Spending card's week start — so it is gone).
    /// A bad Save still reports via the error box.
    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(debtName) Repayment Rule")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            Picker("Rule", selection: $selectedMode) {
                Text("%").tag(DebtRule.Mode.percent)
                Text("$").tag(DebtRule.Mode.fixed)
                Text("Off").tag(DebtRule.Mode.off)
            }
            .pickerStyle(.segmented)
            // Build 36 (owner, Nov 16, 2026): the picker segments
            // were small and cheap — taller segments with larger
            // text, like the other fund editors. Build 37 (owner,
            // Nov 16, 2026): thicker still and more square — the
            // thin rounded bar read as flimsy. The rule value is
            // untouched: the picker still shows the saved rule.
            .font(.system(size: 16, weight: .semibold))
            .frame(minHeight: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // The field row: the % or $ editor spans the full width
            // when its mode is selected (owner, Nov 16, 2026 —
            // build 37), with no Save / Reset crowding it — those
            // sit on their own row below, each 1/2 the width.
            HStack(spacing: 8) {
                if selectedMode == .percent {
                    TextField(MoneyFormat.formatRateBp(savedRule.percentBp), text: $percentText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    Text("% of base")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "#6b7280"))
                } else if selectedMode == .fixed {
                    DollarTextField(text: $fixedText, placeholder: "0.00", maxWidth: .infinity, minHeight: 52)
                }
            }
            // Save + Reset, each 1/2 the width, together filling
            // the full width (owner, Nov 16, 2026 — build 37).
            // The two-button rule: primary blue Save + grey
            // tertiary Reset. In Off mode there is no field row, so
            // the buttons sit directly under the picker.
            HStack(spacing: 8) {
                FundsPrimaryButton("Save", isBusy: viewModel.busyAction == "debt-rule", isLarge: true) {
                    saveRule()
                }
                FundsTertiaryButton("Reset", isLarge: true) {
                    syncFromSaved()
                    ruleError = nil
                }
            }
            if let ruleError {
                FundsErrorBox(ruleError)
            }
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
    /// Large-purchase threshold field (Nov 16, 2026): same editor
    /// shape as the allowance field.
    @State private var thresholdText = ""
    @State private var thresholdError: String?
    /// Add to Budget popup (Nov 16, 2026).
    @State private var showAddToBudget = false
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

    /// The saved large-purchase threshold, in cents. Always a
    /// value: $100 (10000) until loaded (or when the column is
    /// not yet migrated).
    private var savedThreshold: Int { viewModel.largePurchaseThresholdCents ?? 10000 }

    private var thresholdCents: Int? {
        MoneyFormat.parseDollarsStrict(thresholdText)
    }

    private var thresholdDiffers: Bool {
        guard let pending = thresholdCents else { return false }
        return pending != savedThreshold
    }

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
                // No extra horizontal padding (build 33): see
                // CharityRateSection — the card's detail already
                // pads 20pt.
                allowanceContent
            } else {
                FundsCard {
                    allowanceContent
                }
            }
        }
        .accessibilityIdentifier("funds.spendingAllowance")
        .onAppear { syncField(); syncThresholdField() }
        .onChange(of: savedBase) { _, _ in syncField() }
        .onChange(of: savedThreshold) { _, _ in syncThresholdField() }
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
    /// FundsCard when standalone. The editor is the same shape as
    /// the other fund editors (owner, Nov 15, 2026 — build 33):
    /// the label on its own line, the field + Save + Reset on the
    /// row below. There is NO separate "Weekly Allowance $400.00"
    /// value row for admins — the amount is already in the card
    /// header and in the field itself, so the row was redundant.
    /// Members (who cannot edit) keep the read-only value row.
    private var allowanceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let base = savedBase {
                if isAdmin {
                    allowanceEditor
                    thresholdEditor
                } else {
                    FundsBreakdownRow("Weekly Allowance", value: MoneyFormat.formatCents(base))
                    FundsBreakdownRow("Large Purchase Threshold", value: MoneyFormat.formatCents(savedThreshold))
                    FundsMuted("Only the admin can change the weekly allowance and the large purchase threshold.")
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

    private func syncThresholdField() {
        thresholdText = String(format: "%.2f", Double(savedThreshold) / 100)
    }

    /// The large-purchase threshold editor (Nov 16, 2026): the same
    /// shape as the allowance editor (label on its own line, $ field
    /// + Save + Reset on the row below). A purchase at or above this
    /// amount sends a large purchase notification.
    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Large Purchase Threshold")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            HStack(spacing: 10) {
                DollarTextField(text: $thresholdText, placeholder: "0.00", maxWidth: .infinity, minHeight: 52)
                FundsEditorPrimaryButton("Save", isBusy: viewModel.busyAction == "large-purchase-threshold") {
                    thresholdSaveTapped()
                }
                FundsEditorQuietButton("Reset") {
                    syncThresholdField()
                    thresholdError = nil
                }
            }
            // Build 42 (owner, Nov 17, 2026 — spending card
            // clutter): the "This is already the large purchase
            // threshold." helper line is gone — when the field
            // matches the saved value, no helper line shows at
            // all. The differs-explanation and the invalid-amount
            // lines stay.
            if thresholdDiffers {
                FundsMuted("A purchase at or above this amount sends a large purchase notification.")
            } else if thresholdCents == nil {
                FundsMuted("Enter a valid amount (empty is not 0).")
            }
            if let thresholdError {
                FundsErrorBox(thresholdError)
            }
        }
    }

    private func thresholdSaveTapped() {
        guard let cents = thresholdCents, cents >= 0 else {
            thresholdError = "Enter a valid amount (empty is not 0)."
            return
        }
        guard thresholdDiffers else {
            thresholdError = "That is already the large purchase threshold."
            return
        }
        thresholdError = nil
        Task { await viewModel.setLargePurchaseThreshold(cents: cents) }
    }

    private var allowanceEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weekly Allowance")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            HStack(spacing: 10) {
                // Build 36 (owner, Nov 16, 2026): the allowance
                // field and Save were the small sizes — the field is
                // now 52pt tall and Save / Reset are the editor
                // sizes. The value is untouched: still $400.00.
                // Build 37 (owner, Nov 16, 2026): the allowance
                // field expands to fill the row — the 180pt field
                // left a large empty space on the right. Save and
                // Reset sit at the row's right end.
                DollarTextField(text: $allowanceText, placeholder: "0.00", maxWidth: .infinity, minHeight: 52)
                FundsEditorPrimaryButton("Save", isBusy: viewModel.busyAction == "base-allowance") {
                    saveTapped()
                }
                FundsEditorQuietButton("Reset") {
                    syncField()
                    allowanceError = nil
                }
            }
            // Build 42 (owner, Nov 17, 2026 — spending card
            // clutter): the "This is already the weekly
            // allowance." helper line is gone — when the field
            // matches the saved value, no helper line shows at
            // all. The differs-explanation and the invalid-amount
            // lines stay.
            if pendingDiffers {
                FundsMuted("Applies from the current week onward. It does not rewrite closed weeks.")
            } else if pendingCents == nil {
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
        // Build 42 (owner, Nov 17, 2026 — temporary allowance
        // padding): the "Temporary Allowance / Not set" section
        // was cramped against the buttons above (threshold
        // Save/Reset) and below (Add to Budget / Set Temporary
        // Allowance), so it gets 8pt of air on each side — 20pt
        // above the label (12pt section spacing + 8pt) and 16pt
        // below it (8pt section spacing + 8pt) before the buttons.
        VStack(alignment: .leading, spacing: 8) {
            // Build 36 (owner, Nov 16, 2026): the old row was a
            // FundsBreakdownRow — label left, "Not set" stranded at
            // the far right edge, disconnected from its label. The
            // label and its status now sit together in one group:
            // the status directly under the label, so the two read
            // as one row. The "Set Temporary Allowance" button stays,
            // at the editor size. No values change: still "Not set"
            // until an override is in effect.
            VStack(alignment: .leading, spacing: 2) {
                Text("Temporary Allowance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Text(tempOverrideCents.map { MoneyFormat.formatCents($0) } ?? "Not set")
                    .font(.system(size: 15))
                    .foregroundStyle(tempOverrideCents == nil ? Color(hex: "#6b7280") : DesignTokens.ink)
            }
            .padding(.bottom, 8)
            if let temp = tempOverrideCents, let base = savedBase, temp != base {
                FundsMuted("This week's total is \(MoneyFormat.formatCents(temp)) instead of \(MoneyFormat.formatCents(base)).")
            }
            if isAdmin {
                // Top Up Budget (Nov 16, 2026): a one-time top-up to
                // this week's budget. PALE #bfdbfe, full-width large
                // (17pt, 16pt vertical padding) — build 52 (owner,
                // Nov 20, 2026): solid blue here sat as a second
                // stark blue button below "Calculate" in the same
                // Spending card. The Temporary Allowance button
                // below stays grey tertiary, so no two adjacent
                // buttons share a colour.
                FundsPaleButton("Top Up Budget", isBusy: viewModel.busyAction == "add-budget", isLarge: true) {
                    showAddToBudget = true
                }
                FundsTertiaryButton(tempOverrideCents == nil ? "Set Temporary Allowance" : "Change Temporary Allowance", isLarge: true) {
                    onOpenTemp()
                }
            }
        }
        .padding(.top, 8)
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        .fullScreenCover(isPresented: $showAddToBudget) {
            AddToBudgetSheet(viewModel: viewModel, onClose: { showAddToBudget = false })
        }
    }
}

// MARK: - Top Up Budget (Nov 16, 2026; renamed from "Add to Budget", build 43, owner Nov 17, 2026)

/// The Top Up Budget popup (owner, Nov 16, 2026): a one-time top-up
/// to the CURRENT week's budget only. An amount field + Add/Cancel,
/// in the Add to Charity popup's style (iPad 600pt centred, 17pt).
/// Validation lives here: the amount must be above $0.00 — empty /
/// zero / negative shows a plain-language error INSIDE the popup and
/// the popup stays open (the field keeps the typed input). The user
/// never does the math — they enter only the amount to add; the
/// server adds it to the week's current total. On success the popup
/// closes, the field clears, and the week's budget updates
/// everywhere (add_to_weekly_budget).
public struct AddToBudgetSheet: View {
    @ObservedObject public var viewModel: FundsViewModel
    public var onClose: () -> Void
    @State private var amountText = ""
    @State private var addError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Top Up Budget", onClose: onClose)
            DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
            if let addError {
                FundsErrorBox(addError)
            }
            HStack(spacing: 12) {
                FundsPrimaryButton("Add", isBusy: viewModel.busyAction == "add-budget") {
                    add()
                }
                FundsTertiaryButton("Cancel") { onClose() }
            }
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // full-screen cover — without it the short form
            // centres itself vertically in the full screen.
            Spacer()
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // rename sheet and the Add to Charity popup.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private func add() {
        guard let cents = MoneyFormat.parseDollarsStrict(amountText), cents > 0 else {
            addError = "Enter an amount above $0.00."
            return
        }
        addError = nil
        Task {
            // Clear only on success — on failure the typed input
            // stays beside the error (F-P1-4).
            if await viewModel.addToBudget(amountCents: cents) {
                amountText = ""
                onClose()
            }
        }
    }
}
