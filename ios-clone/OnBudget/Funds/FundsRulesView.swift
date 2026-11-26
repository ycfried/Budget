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
                    // Build 74 (B5): skeletons shaped like the
                    // rate editor below — a label line + a 52pt
                    // field — not "Loading…" text.
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(height: 20)
                        SkeletonBlock(height: 52)
                    }
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
                // 48pt tall and the Apply button is the small
                // primary size (build 56), not the small list-row
                // sizes. The value is untouched: the field still
                // shows the live default.
                // Owner, Nov 16, 2026 (build 40): the "%" is a LEFT
                // prefix INSIDE the field ("Percent sign on the
                // left."), mirroring the "$" prefix in
                // DollarTextField — nothing sits on the right.
                HStack(spacing: 2) {
                    Text("%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField(MoneyFormat.formatRateBp(defaultRateBp), text: $rateText)
                        // Dark Mode (owner's father, Nov 26, 2026):
                        // the field background is hardcoded white,
                        // so the typed text must be explicit ink.
                        .foregroundStyle(DesignTokens.ink)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17))
                }
                .padding(.horizontal, 14)
                // Build 37 (owner, Nov 16, 2026): the field
                // expands to fill the row — the 72pt field left
                // a large empty space on the right. Apply sits at
                // the row's right end (build 56: Save + Reset are
                // gone, Reset removed entirely). Build 68
                // (item 27): the field and Apply are the same
                // height (52pt) — the small Apply was shorter
                // than its field.
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                FundsEditorPrimaryButton("Apply", isBusy: viewModel.busyAction == "rate") {
                    saveRate()
                }
                .frame(minHeight: 52)
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
                    // Build 74 (B5): skeletons shaped like the
                    // rule editor below — a label line + a 52pt
                    // field — not "Loading…" text.
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(height: 20)
                        SkeletonBlock(height: 52)
                    }
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
    /// own line so it can never truncate, the mode picker + Apply
    /// on the next row (build 57: the picker is shortened so Apply
    /// fits beside it on the same line), then the field on its own
    /// row below (in %/$ mode; Off has no field). Save + Reset are
    /// gone (build 56 — one small Apply, Reset removed entirely).
    /// The picker uses "%" for Percent (owner rule: a word
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
            // Build 57 (owner, Nov 22, 2026): the picker bar is
            // shorter now — Apply sits on the SAME row as the
            // control, to its right — so the row reads
            // [picker][Apply] instead of the picker full-width
            // with Apply alone underneath (Off mode). The control
            // is flexible, so it takes whatever width is left
            // after Apply — on an iPhone (390pt) the three short
            // cells still get ~80pt each, no clipping. The
            // field (in %/$ mode) sits below this row, full
            // width; in Off mode there is no field. Build 64
            // (C-6): the segmented picker is gone — a squarish
            // control (8pt radius, ink text, pale-blue selected
            // cell), no pill track.
            HStack(spacing: 8) {
                SquarishPicker(
                    [(DebtRule.Mode.percent, "%"), (DebtRule.Mode.fixed, "$"), (DebtRule.Mode.off, "Off")],
                    selection: $selectedMode,
                    minHeight: 52
                )
                // Build 68 (item 25a): Apply is the SAME HEIGHT
                // as the slider (52pt) — the small Apply was
                // shorter than the control beside it.
                FundsEditorPrimaryButton("Apply", isBusy: viewModel.busyAction == "debt-rule") {
                    saveRule()
                }
                .frame(minHeight: 52)
            }
            // Identifier for a UI test to find the picker+Apply row
            // and prove both sit on the same line at iPhone width.
            .accessibilityIdentifier("debt-rule-picker-apply-row")
            // The field row (build 56, owner Nov 22, 2026): the %
            // or $ editor, full width below the picker+Apply row
            // — Save + Reset are gone (Reset removed entirely).
            // In % mode the "%" is a LEFT prefix INSIDE the field,
            // mirroring the "$" prefix in DollarTextField and the
            // Tzedaka rate field — the "% of base" label outside
            // the box is gone. In Off mode there is no field.
            if selectedMode == .percent {
                HStack(spacing: 2) {
                    Text("%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField(MoneyFormat.formatRateBp(savedRule.percentBp), text: $percentText)
                        .foregroundStyle(DesignTokens.ink)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17))
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if selectedMode == .fixed {
                DollarTextField(text: $fixedText, placeholder: "0.00", maxWidth: .infinity, minHeight: 52)
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
/// fund's setting). The row + the admin editor (field + small Apply
/// beside it, build 56) and the preview line, then the Temporary
/// Allowance block below it. No heading — the "Weekly Allowance"
/// row says what it is, and the Spending card above is the section
/// header. A change applies from the current week onward; closed
/// weeks are never rewritten (the confirm dialog says so, as the
/// Settings card did).
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
    /// Per-field explanations (owner, Nov 25, 2026): each label
    /// carries a small blue ⓘ that shows a short plain-language
    /// alert — the same pattern as CharityIncomeForm. No inline
    /// paragraphs; the explanations live behind the ⓘ.
    @State private var showingAllowanceInfo = false
    @State private var showingThresholdInfo = false
    @State private var showingTempInfo = false
    /// True inside the Spending fund container: no card of its own.
    public let bare: Bool
    /// Opens the merged Adjust This Week's Budget sheet (build
    /// 68, item 29 — owned by FundsView). The old separate Top Up
    /// / Set Temporary Allowance entry points are gone.
    public let onAdjustBudget: () -> Void
    /// Opens the Weekly Budget Calculator (owned by FundsView).
    /// Nil when the section is shown without a calculator — the
    /// button is then omitted.
    public let onCalculate: (() -> Void)?
    /// The walkthrough state (Nov 26, 2026 refresh): when set,
    /// the Calculate button carries the `.calculatorButton`
    /// anchor so the tour can point at it. Nil everywhere else.
    public let tour: TourState?

    public init(viewModel: FundsViewModel, bare: Bool = false, onCalculate: (() -> Void)? = nil, tour: TourState? = nil, onAdjustBudget: @escaping () -> Void) {
        self.viewModel = viewModel
        self.bare = bare
        self.onCalculate = onCalculate
        self.tour = tour
        self.onAdjustBudget = onAdjustBudget
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
        .appConfirmDialog(item: $confirmChange) { change in
            let message: String
            if let old = change.oldCents {
                message = "Change the weekly allowance from \(MoneyFormat.formatCents(old)) to \(MoneyFormat.formatCents(change.newCents))?\nThis applies from the current week onward. It does not rewrite closed weeks."
            } else {
                message = "Set the weekly allowance to \(MoneyFormat.formatCents(change.newCents))?\nThis applies from the current week onward. It does not rewrite closed weeks."
            }
            return AppConfirmDialog.Config(
                title: "Change Allowance",
                message: message,
                primaryTitle: "Change Allowance",
                secondaryTitle: "Keep Current",
                onPrimary: { Task { await viewModel.setBaseAllowance(cents: change.newCents) } }
            )
        }
    }

    /// The row + editor + Temporary Allowance block, without chrome:
    /// the caller (the Spending fund container) wraps it, or
    /// FundsCard when standalone. The editor is the same shape as
    /// the other fund editors (owner, Nov 15, 2026 — build 33):
    /// the label on its own line, the field + small Apply on the
    /// row below (build 56). There is NO separate "Weekly Allowance
    /// $400.00" value row for admins — the amount is already in the
    /// card header and in the field itself, so the row was redundant.
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
                // Build 74 (B5): skeletons shaped like the
                // allowance field below, not "Loading…" text.
                // Loading mandate (owner, Nov 26, 2026): the field
                // block is 52pt, like the real field — the old
                // 48pt block left a 4pt jump on reveal.
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(height: 20)
                    SkeletonBlock(height: 52)
                }
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
    /// + small Apply on the row below, build 56). A purchase at or
    /// above this amount sends a large purchase notification.
    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Large Purchase Threshold")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Button(action: { showingThresholdInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About the large purchase threshold")
            }
            HStack(spacing: 10) {
                DollarTextField(text: $thresholdText, placeholder: "0.00", maxWidth: .infinity, minHeight: 52)
                // Build 68 (item 27): Apply matches its field's
                // height (52pt) — the small Apply was shorter.
                FundsEditorPrimaryButton("Apply", isBusy: viewModel.busyAction == "large-purchase-threshold") {
                    thresholdSaveTapped()
                }
                .frame(minHeight: 52)
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
        .alert(TitleCase.apply(to: "Large Purchase Threshold"), isPresented: $showingThresholdInfo) {
            Button("OK") {}
        } message: {
            Text("A purchase at or above this amount sends you a large purchase notification.")
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
            HStack(spacing: 6) {
                Text("Weekly Allowance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Button(action: { showingAllowanceInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About the weekly allowance")
            }
            HStack(spacing: 10) {
                // Build 36 (owner, Nov 16, 2026): the allowance
                // field and its buttons were the small sizes — the
                // field is now 52pt tall and Apply is the small
                // primary size (build 56: Save / Reset are gone).
                // The value is untouched: still $400.00.
                // Build 37 (owner, Nov 16, 2026): the allowance
                // field expands to fill the row — the 180pt field
                // left a large empty space on the right. Apply sits
                // at the row's right end.
                DollarTextField(text: $allowanceText, placeholder: "0.00", maxWidth: .infinity, minHeight: 52)
                // Build 68 (item 27): Apply matches its field's
                // height (52pt) — the small Apply was shorter.
                FundsEditorPrimaryButton("Apply", isBusy: viewModel.busyAction == "base-allowance") {
                    saveTapped()
                }
                .frame(minHeight: 52)
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
        .alert(TitleCase.apply(to: "Weekly Allowance"), isPresented: $showingAllowanceInfo) {
            Button("OK") {}
        } message: {
            Text("Your base spending allowance each week. Top-ups add to it; a Temporary Allowance changes this week's total only.")
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
            // as one row. No values change: still "Not set"
            // until an override is in effect.
            // Owner, Nov 25, 2026: the block was a dead label — no
            // field, no button. The whole label + status area is an
            // entry point to the Adjust This Week's Budget sheet
            // (admins): tapping it calls onAdjustBudget, and the
            // chevron says so. The ⓘ is a real Button inside the
            // tappable area and takes precedence over the tap, so it
            // still shows its explanation. Members see the same
            // label + status with no chevron and no tap.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Temporary Allowance")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Button(action: { showingTempInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DesignTokens.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About the temporary allowance")
                    }
                    Text(tempOverrideCents.map { MoneyFormat.formatCents($0) } ?? "Not set")
                        .font(.system(size: 15))
                        .foregroundStyle(tempOverrideCents == nil ? Color(hex: "#6b7280") : DesignTokens.ink)
                }
                Spacer()
                if isAdmin {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#6b7280"))
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isAdmin { onAdjustBudget() }
            }
            .padding(.bottom, 8)
            if let temp = tempOverrideCents, let base = savedBase, temp != base {
                FundsMuted("This week's total is \(MoneyFormat.formatCents(temp)) instead of \(MoneyFormat.formatCents(base)).")
            }
            // Build 68 (item 29): ONE entry point — "Adjust This
            // Week's Budget" — for both the one-time top-up and
            // the temporary total. The merged sheet holds the Add
            // / Set Total choice and wires to the existing
            // operations; the old Top Up Budget and Set Temporary
            // Allowance buttons are gone from this card.
            // Build 68 (item 11): the Calculate button carries
            // the custom calculator glyph (CalculatorGlyph) —
            // the "calculator" SF Symbol renders nothing and
            // "±" does not read as a calculator.
            if let onCalculate {
                Button(action: onCalculate) {
                    HStack(spacing: 10) {
                        CalculatorGlyph(size: 20, color: .white)
                        Text("Calculate")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    // Build 74 (B3): the one primary blue (#2f6bff)
                    // — the deep blue (#1d4ed8) was a second primary.
                    .background(DesignTokens.primary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("funds.openWeeklyBudgetCalculator")
                // Walkthrough anchor (Nov 26, 2026 refresh): the
                // Calculator entry point — the tour expands the
                // Spending card, then points here.
                .tourAnchor(.calculatorButton, tour: tour)
                .id(TourAnchor.calculatorButton)
            }
            if isAdmin {
                FundsInkOutlineButton("Adjust This Week's Allowance", isLarge: true) {
                    onAdjustBudget()
                }
            }
        }
        .padding(.top, 8)
        .alert(TitleCase.apply(to: "Temporary Allowance"), isPresented: $showingTempInfo) {
            Button("OK") {}
        } message: {
            Text("A one-time change to this week's total only. Next week goes back to your Weekly Allowance.")
        }
    }
}

// MARK: - Top Up Budget (Nov 16, 2026; renamed from "Add to Budget", build 43, owner Nov 17, 2026)

/// The Top Up Budget popup (owner, Nov 16, 2026): a one-time top-up
/// to the CURRENT week's budget only. An amount field + Add/Cancel,
/// in the Add to Charity popup's style (iPad 600pt centred, 17pt).
/// Build 68 (item 29): the Funds page's entry point moved to the
/// merged AdjustWeeklyBudgetSheet below — this popup remains for
/// the Weekly Budget sheet (HomeView) until that sheet is rewired.
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
            SheetHeader(title: "Top Up Allowance", onClose: onClose)
            DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
            if let addError {
                FundsErrorBox(addError)
            }
            // Build 70, item 5 (owner, Nov 24, 2026): the Cancel
            // button is gone — the SheetHeader X + swipe-right
            // dismiss without saving, so Cancel was a third
            // redundant way out.
            FundsPrimaryButton("Add", isBusy: viewModel.busyAction == "add-budget") {
                add()
            }
            // Build 43 (owner, Nov 17, 2026 — item 18): the
            // trailing Spacer top-anchors the content in the
            // sheet — without it the short form centres itself
            // vertically in the detent.
            Spacer()
        }
        .padding()
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // rename sheet and the Add to Charity popup.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 67 (owner, Nov 23, 2026 — item 3): a fitted sheet
        // sized to the content (C-4 fitted detents), not a
        // full-screen page — the form is one field and two
        // buttons, and the full screen left a huge empty area.
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
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

// MARK: - Adjust This Week's Budget (build 68, item 29)
//
// ONE entry point merging the old "Top Up Budget" popup and the
// "Set This Week's Budget" (Temporary Allowance) sheet: a slider
// with two choices — "Add" (a one-time amount added to this week
// only, the old Top Up) and "Set Total" (a new weekly total for
// 1–4 weeks, the old Temporary Allowance). The sheet shows the
// current total, and when a temporary total is already active it
// shows it with a red (#dc2626) Remove to clear it. Both choices
// wire to the EXISTING operations — addToBudget and
// setTemporaryAllowance / removeTemporaryAllowance — so it works
// with the live server as-is; no new backend API. The old
// separate entry points are gone from the Spending card; the old
// AddToBudgetSheet above and TemporaryAllowanceView remain for
// the Weekly Budget sheet (HomeView) until that sheet is rewired
// to this one.
public struct AdjustWeeklyBudgetSheet: View {
    public enum Mode: Hashable {
        case add
        case setTotal
    }

    @ObservedObject public var viewModel: FundsViewModel
    public var onClose: () -> Void
    @State private var mode: Mode = .add
    @State private var addAmountText = ""
    @State private var newTotalText = ""
    @State private var weeks = 1
    @State private var fieldError: String?
    @State private var showConfirm = false
    @State private var showRemoveConfirm = false
    @State private var showModeInfo = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    private var addCents: Int? { MoneyFormat.parseDollarsStrict(addAmountText) }
    private var newTotalCents: Int? { MoneyFormat.parseDollarsStrict(newTotalText) }
    private var currentTotalCents: Int? { viewModel.currentWeekTotalCents }
    private var tempOverrideCents: Int? { viewModel.debtWeek?.overrideCents }
    private var baseCents: Int? { viewModel.baseAllowanceCents }

    /// Preview: "Base `$B` · New total `$N` · `W` week(s) · `Mon D, …`."
    /// Empty until values are entered. Dates render short ("Nov 15,
    /// Nov 22"), never raw ISO (F-P2-1).
    private var previewText: String {
        guard let base = baseCents,
              let total = newTotalCents, total >= 0 else { return "" }
        let dates = MoneyFormat.sundays(from: MoneyFormat.currentSundayNY(), count: weeks)
            .map { MoneyFormat.fmtShort($0) }
        return "Base \(MoneyFormat.formatCents(base)) · New total \(MoneyFormat.formatCents(total)) · \(weeks) week(s) · \(dates.joined(separator: ", "))."
    }

    /// Confirm-dialog text: the new total + weeks + dates, calling
    /// out $0 explicitly — $0 is allowed only when confirmed here
    /// (F-P2-3).
    private var confirmMessage: String {
        guard let total = newTotalCents else { return "" }
        let dates = MoneyFormat.sundays(from: MoneyFormat.currentSundayNY(), count: weeks)
            .map { MoneyFormat.fmtShort($0) }
        var message = "Set the weekly allowance to \(MoneyFormat.formatCents(total)) for \(weeks) week\(weeks == 1 ? "" : "s") (\(dates.joined(separator: ", ")))."
        if total == 0 {
            message += " That is $0.00 — no spending room for those weeks."
        }
        return message
    }

    /// Build 69 (owner, Nov 24, 2026 — "looks ugly.. needs to be
    /// cleaned up and planned better"): the sheet is fitted to
    /// its content (`.presentationSizing(.fitted)` — the
    /// build-68 fitted-sheet pattern — instead of the
    /// `.fraction(0.45)` detent that left a big empty area above
    /// the title and below the buttons); the current total reads
    /// in a bordered summary card; the confirm button reads as
    /// the action ("Add Amount", not the mode name "Add"); and
    /// both mode descriptions live behind an ⓘ, never inline.
    /// Behaviour is unchanged (Add = one-time amount this week
    /// only; Set Total = new weekly total + how many weeks).
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Adjust This Week's Allowance", onClose: onClose)
            // The current total, in a bordered summary card — so
            // the title and the total read as one planned header,
            // and the temporary total (with its red Remove) lives
            // inside the same card.
            if let current = currentTotalCents {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Current Total")
                            .font(.system(size: 15))
                            .foregroundStyle(DesignTokens.muted)
                        Spacer()
                        Text(MoneyFormat.formatCents(current))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                    }
                    if let temp = tempOverrideCents, let base = baseCents, temp != base {
                        Divider()
                        HStack(spacing: 8) {
                            Text("Temporary Total \(MoneyFormat.formatCents(temp))")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DesignTokens.ink)
                            Spacer()
                            FundsEditorDangerButton("Remove", isBusy: viewModel.busyAction == "remove-temp") {
                                showRemoveConfirm = true
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
            } else if let error = viewModel.allowanceError ?? viewModel.debtError {
                FundsErrorBox(error)
            } else {
                // Loading mandate (owner, Nov 26, 2026): the card
                // holds its space while the total loads — the old
                // bare `if let` left the sheet without it, so the
                // mode slider, fields and button all jumped down
                // a card-height when the total landed. Shaped like
                // the no-temporary-total card (label + amount row
                // in the same bordered card); see the report for
                // the temporary-total case.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SkeletonBlock(width: 110, height: 16)
                        Spacer()
                        SkeletonBlock(width: 90, height: 24)
                    }
                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
            }
            // The mode slider (the build-69 unified slider), with
            // the mode's description behind an ⓘ — the standing
            // rule (explanations behind an info icon, never
            // inline). The mode choice is the slider, not two
            // separate boxes.
            HStack(spacing: 6) {
                SquarishPicker(
                    [(Mode.add, "Add"), (Mode.setTotal, "Set Total")],
                    selection: $mode
                )
                Button { showModeInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About this mode")
            }
            if mode == .add {
                // Build 78 (owner, Nov 25, 2026): the Add-mode
                // amount field has the same FieldLabel as Set
                // Total's "New Total" — the bare field made a
                // label pop up on switching modes, which read as
                // a glitch. The Weeks stepper stays Set Total-only
                // (Add is one week only).
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Amount to Add", required: true)
                    DollarTextField(text: $addAmountText, maxWidth: .infinity, minHeight: 52)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("New Total", required: true)
                        DollarTextField(text: $newTotalText, maxWidth: .infinity, minHeight: 52)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel("Weeks")
                        Picker("Weeks", selection: $weeks) {
                            ForEach(1...4, id: \.self) { week in
                                Text("\(week)").tag(week)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 64, height: 52)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                if baseCents == nil {
                    if let allowanceError = viewModel.allowanceError {
                        FundsErrorBox(allowanceError)
                    } else {
                        // Build 74 (B5): skeletons shaped like the
                        // preview line below, not "Loading…" text.
                        // Loading mandate (owner, Nov 26, 2026):
                        // the old 20+48 block stood in for a one-
                        // line preview — the sheet jumped ~60pt
                        // when the base loaded and the block was
                        // replaced by one line (or nothing).
                        SkeletonBlock(height: 20)
                    }
                } else if !previewText.isEmpty {
                    // Dynamic feedback, not an explainer — it
                    // stays inline.
                    Text(previewText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            if let fieldError {
                FundsErrorBox(fieldError)
            }
            // Build 70, item 5 (owner, Nov 24, 2026): the Cancel
            // button is gone — the SheetHeader X + swipe-right
            // dismiss without saving, so Cancel was a third
            // redundant way out.
            // The confirm reads as the ACTION, not the mode:
            // "Add Amount" in Add mode (the mode is "Add"),
            // "Set New Total" in Set Total mode.
            FundsPrimaryButton(mode == .add ? "Add Amount" : "Set New Total", isBusy: viewModel.busyAction == "add-budget" || viewModel.busyAction == "temp") {
                saveTapped()
            }
        }
        .padding()
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
        .alert(mode == .add ? "Add" : "Set Total", isPresented: $showModeInfo) {
            Button("OK") {}
        } message: {
            Text(mode == .add ? "Adds a one-time amount to this week only." : "Sets a new weekly total for 1–4 weeks.")
        }
        .alert("Set New Total", isPresented: $showConfirm) {
            Button(TitleCase.apply(to: "Set New Total")) {
                Task {
                    guard let cents = newTotalCents else { return }
                    if await viewModel.setTemporaryAllowance(newTotalCents: cents, weeks: weeks) {
                        onClose()
                    }
                }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("Remove Temporary Total", isPresented: $showRemoveConfirm) {
            Button("Remove") {
                Task { await viewModel.removeTemporaryAllowance() }
            }
            Button(TitleCase.apply(to: "Cancel"), role: .cancel) {}
        } message: {
            Text("The base allowance applies again from this week.")
        }
    }

    private func saveTapped() {
        if mode == .add {
            guard let cents = addCents, cents > 0 else {
                fieldError = "Enter an amount above $0.00."
                return
            }
            fieldError = nil
            Task {
                if await viewModel.addToBudget(amountCents: cents) {
                    onClose()
                }
            }
        } else {
            guard let cents = newTotalCents, cents >= 0 else {
                fieldError = "Enter a valid amount."
                return
            }
            fieldError = nil
            showConfirm = true
        }
    }
}
