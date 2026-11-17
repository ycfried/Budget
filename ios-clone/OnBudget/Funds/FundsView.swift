import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WidgetKit
import OnBudgetKit

// MARK: - Funds tab (spec §9)
//
// Top: two balance panels side by side in the web app — stacked here,
// same face as the Home stat cards (Title + Amount only, chevron `⌄`
// bottom-right) with the same in-place expansion, except the Funds
// expansions INCLUDE action buttons (Home does not). One fund IS one
// section (owner, Nov 15, 2026; redesigned build 33; banner
// redesign build 37): the fund's coloured BANNER heads its section
// and its detail — breakdown, actions, editor, Activity — sits below
// it on plain white, so each fund reads as one group, not a card
// with loose rows hanging below it. Spending (Weekly
// Allowance editor + Temporary Allowance), Extra Fund (shortfall
// row, Activity), Charity (rate editor + Activity), Carried Debt
// (rule editor, Activity) — then standalone Review.
//
// Forms: one at a time; the sections below the cards hide while a
// form is open. Back returns to the Funds list (swipe-right closes
// the form too, via the navigation stack in the coordinator).
//
// Entry point for the app shell's tab bar:
//   FundsView(context: FundsContext(client:householdId:role:userId:),
//             appState: appState)
// The view model is owned here. Card expansion is the SHARED
// `appState.expandedCard` (integration, Nov 9, 2026 — the local
// `FundsExpandedCard` state is deleted): one-open-at-a-time spans
// Home + Funds. Temporary Allowance opens as a form from the
// Spending section (build 30 — the Settings Budget link is gone).

public enum FundsForm: Equatable {
    case add
    case use
    case ask
    case income
    /// Temporary Allowance — opened from the Spending section,
    /// presented as a form, never duplicated in Settings.
    case temp
    /// Pay Carried Debt from the Extra Fund (build 29).
    case payDebt
    /// Clear Carried Debt in part or in full (build 30 — slider).
    case clearDebt
}

public enum FundsMoreSection: Equatable {
    case fundActivity
    case charityActivity
    case debtActivity
}

/// The four reorderable funds on the Funds page (build 30).
/// Raw values persist in UserDefaults under
/// `hb-fund-order-<household-UUID>`; the default order is the
/// order below (Spending first — the fund the week runs on).
public enum FundSectionID: String, CaseIterable, Identifiable {
    case spending
    case fund
    case charity
    case debt

    public var id: String { rawValue }

    public static var defaultOrder: [FundSectionID] {
        [.spending, .fund, .charity, .debt]
    }

    public var displayName: String {
        switch self {
        case .spending: return "Spending"
        case .fund: return "Extra Fund"
        case .charity: return "Charity"
        case .debt: return "Carried Debt"
        }
    }

    /// The name to SHOW (build 37 — fund rename, owner Nov 16,
    /// 2026): the household's custom name for this fund when one
    /// is stored, else the default above. The custom name is shown
    /// exactly as typed — no Title Case forcing. A blank stored
    /// value falls back to the default, so a reset is just a
    /// missing/empty key. This is the ONE resolution every view
    /// uses (Funds, Home, Transactions filters, buttons, widget),
    /// reading the same `appState.fundNames` source.
    public func displayName(customNames: [String: String]) -> String {
        if let custom = customNames[rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return displayName
    }
}

public struct FundsView: View {
    @StateObject private var viewModel: FundsViewModel
    /// Shared shell state: card expansion, one-open-at-a-time
    /// across Home + Funds.
    @ObservedObject var appState: AppViewModel
    @State private var openForm: FundsForm?
    /// The fund being renamed (build 37 — fund rename, owner Nov
    /// 16, 2026): set by the Rename button in a fund's expanded
    /// detail, opens the rename sheet. Admin-only — the button is
    /// hidden for non-admins.
    @State private var renamingFund: FundSectionID?
    @State private var openMore: FundsMoreSection?
    @State private var correctingIncome: CharityIncome?
    /// The funds' order on this page (build 30 — reorderable with
    /// up/down arrows in reorder mode, build 34). Loaded per
    /// household, saved on every change.
    @State private var fundOrder: [FundSectionID] = FundSectionID.defaultOrder
    @State private var isRearranging = false
    /// iPad content width (build 36): the tabs read as a centered
    /// 900pt column on the regular size class.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(context: FundsContext, appState: AppViewModel) {
        self.appState = appState
        self._viewModel = StateObject(wrappedValue: FundsViewModel(context: context))
    }

    /// The shared view model, for Review (same data, one refresh).
    public var fundsViewModel: FundsViewModel { viewModel }

    private var isAdmin: Bool { viewModel.context.isAdmin }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let form = openForm {
                    backButton
                    // The balance the open form acts on stays visible
                    // above it (F-P2-12); the sections below the cards
                    // stay hidden while a form is open.
                    formBalanceStrip(for: form)
                    switch form {
                    case .add:
                        AddMoneyForm(viewModel: viewModel, onClose: { openForm = nil })
                    case .use:
                        UseFundForm(viewModel: viewModel, onClose: { openForm = nil })
                    case .ask:
                        AskFundForm(viewModel: viewModel, onClose: { openForm = nil })
                    case .income:
                        CharityIncomeForm(viewModel: viewModel, correcting: $correctingIncome, onClose: { openForm = nil })
                    case .temp:
                        TemporaryAllowanceView(viewModel: viewModel)
                    case .payDebt:
                        PayDebtForm(viewModel: viewModel, onClose: { openForm = nil })
                    case .clearDebt:
                        ClearDebtForm(viewModel: viewModel, onClose: { openForm = nil })
                    }
                } else {
                    rearrangeRow
                    // Four fund sections (owner, Nov 15, 2026): each
                    // fund is ONE container — its card heads the
                    // block and its rules, info and transactions sit
                    // inside the same card, not as loose rows below
                    // it. Review is NOT here any more (build 30): it
                    // lives on its own page off Transactions, with a
                    // count badge on the Review button there.
                    // Spending is first by default: the week's
                    // allowance is the fund the week runs on
                    // (build 30 — moved from Settings). The order is
                    // the user's own: reorder mode moves the
                    // containers with up/down arrows and remembers
                    // it per household.
                    VStack(spacing: 24) {
                        ForEach(fundOrder) { id in
                            fundContainer(for: id)
                        }
                    }
                }
            }
            .padding()
        }
        .background(DesignTokens.background)
        // Build 36 (owner, Nov 16, 2026 — iPad): the page reads as
        // a centered 900pt column on the regular size class (see
        // mainContentWidth), never stretched edge-to-edge.
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
        // Build 36 (owner, Nov 16, 2026 — iPad): fund-editor
        // success messages ("Default charity rate saved…") rendered
        // INLINE inside the card, mid-screen, through the Funds-
        // local toast overlay — not at the bottom. They now go
        // through the ONE root bottom toast (ContentView
        // .toastOverlay, the standing rule: bottom only, auto-
        // dismiss ~4s, green badge treatment): when the view model
        // raises a success toast, forward it to appState and clear
        // the local one. Errors still use the alert below. The
        // local FundsToastOverlay stays for the Review page, which
        // has no appState to forward to.
        .onChange(of: viewModel.toast) { _, newValue in
            if let toast = newValue {
                appState.showToast(toast.message, kind: toast.kind)
                viewModel.toast = nil
            }
        }
        .alert(
            viewModel.alertTitle ?? "Could Not Complete",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil; viewModel.alertTitle = nil } }
            )
        ) {
            Button(TitleCase.apply(to: "Close"), role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        // Rename sheet (build 37 — fund rename, owner Nov 16,
        // 2026): a fund's Rename button sets `renamingFund`. On a
        // successful save the shared `appState.fundNames` is
        // refreshed from the RPC result, so the new name updates
        // everywhere at once (Funds, Home, Transactions, widget).
        .sheet(item: $renamingFund) { section in
            RenameFundSheet(
                section: section,
                currentName: section.displayName(customNames: appState.fundNames),
                viewModel: viewModel,
                onSaved: { names in
                    appState.fundNames = names
                    // Build 40 (owner, Nov 16, 2026): the new name
                    // must show on the WIDGET too when updated — e.g.
                    // "Charity left" reads "Tzedaka left" after the
                    // rename. The snapshot is normally rewritten on
                    // a Home refresh, but a rename happens on Funds
                    // and the widget may update first — so push the
                    // new names into the STORED snapshot now (the
                    // numbers are unchanged by a rename) and reload
                    // the widget timeline, so the next widget update
                    // shows the new name without waiting for Home.
                    if let snapshot = WidgetSnapshotStore.read() {
                        WidgetSnapshotStore.write(snapshot.withFundNames(names))
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                },
                onClose: { renamingFund = nil }
            )
            .presentationSizing(.fitted)
        }
        .task {
            loadFundOrder()
            await viewModel.refresh()
        }
        .onChange(of: fundOrder) { _, _ in
            saveFundOrder()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    /// Reorder / Done, above the funds (build 30). Reorder mode
    /// shows up/down arrows above each fund's card; Done exits and
    /// the order is already saved. The Reorder control is a blue
    /// primary button (owner, Nov 15, 2026 — the grey "Rearrange"
    /// pill looked ugly); same treatment as Save.
    private var rearrangeRow: some View {
        HStack {
            Spacer()
            if isRearranging {
                FundsSmallPrimaryButton("Done") { isRearranging = false }
            } else {
                FundsSmallPrimaryButton("Reorder") { isRearranging = true }
            }
        }
    }

    /// The user's fund order, per household (build 30): Spending,
    /// Extra Fund, Charity, Carried Debt by default; a stored order
    /// with anything missing or extra is ignored, not repaired
    /// into a wrong order.
    private var fundOrderKey: String {
        "hb-fund-order-\(viewModel.context.householdId.uuidString)"
    }

    private func loadFundOrder() {
        guard let raw = UserDefaults.standard.array(forKey: fundOrderKey) as? [String] else { return }
        let ids = raw.compactMap { FundSectionID(rawValue: $0) }
        guard Set(ids) == Set(FundSectionID.allCases), ids.count == FundSectionID.allCases.count else { return }
        fundOrder = ids
    }

    private func saveFundOrder() {
        UserDefaults.standard.set(fundOrder.map(\.rawValue), forKey: fundOrderKey)
    }

    private var backButton: some View {
        BackButton(action: { openForm = nil })
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Back to Funds")
    }

    /// The balance the open form acts on, kept visible above the
    /// form while it is open (F-P2-12): Use Fund / Ask show current
    /// Available; Add Money keeps its split preview in the form AND
    /// the current Available here; Charity Income shows charity
    /// Available; Temporary Allowance shows the current base.
    @ViewBuilder
    private func formBalanceStrip(for form: FundsForm) -> some View {
        switch form {
        case .add, .use, .ask:
            FundsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let summary = viewModel.fundSummary {
                        FundsBreakdownRow("Available", value: MoneyFormat.formatCents(summary.availableCents), isNegative: summary.availableCents < 0)
                        if summary.shortfallCents > 0 {
                            FundsBreakdownRow("Owed back", value: MoneyFormat.formatCents(summary.shortfallCents))
                        }
                    } else if let error = viewModel.fundError {
                        FundsErrorBox(error)
                    } else {
                        SkeletonBlock(width: 160, height: 16)
                    }
                }
            }
        case .income:
            FundsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let summary = viewModel.charitySummary {
                        FundsBreakdownRow("Available", value: MoneyFormat.formatCents(summary.remainingCents), isNegative: summary.remainingCents < 0)
                        FundsBreakdownRow("Given", value: MoneyFormat.formatCents(summary.givenCents))
                    } else if let error = viewModel.charityError {
                        FundsErrorBox(error)
                    } else {
                        SkeletonBlock(width: 160, height: 16)
                    }
                }
            }
        case .temp:
            FundsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let base = viewModel.baseAllowanceCents {
                        FundsBreakdownRow("Current weekly allowance", value: MoneyFormat.formatCents(base))
                    } else if let error = viewModel.allowanceError {
                        FundsErrorBox(error)
                    } else {
                        SkeletonBlock(width: 160, height: 16)
                    }
                }
            }
        case .payDebt:
            FundsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let debt = viewModel.debtBalanceCents {
                        FundsBreakdownRow(FundSectionID.debt.displayName(customNames: appState.fundNames), value: MoneyFormat.formatCents(debt))
                    } else if let error = viewModel.debtError {
                        FundsErrorBox(error)
                    } else {
                        SkeletonBlock(width: 160, height: 16)
                    }
                    if let summary = viewModel.fundSummary {
                        FundsBreakdownRow("Available in \(FundSectionID.fund.displayName(customNames: appState.fundNames))", value: MoneyFormat.formatCents(summary.availableCents), isNegative: summary.availableCents < 0)
                    }
                }
            }
        case .clearDebt:
            FundsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let debt = viewModel.debtBalanceCents {
                        FundsBreakdownRow(FundSectionID.debt.displayName(customNames: appState.fundNames), value: MoneyFormat.formatCents(debt))
                    } else if let error = viewModel.debtError {
                        FundsErrorBox(error)
                    } else {
                        SkeletonBlock(width: 160, height: 16)
                    }
                }
            }
        }
    }

    // MARK: - Spending card (§9.1, build 30)
    //
    // The weekly budget fund (moved from the Settings Budget card):
    // the face is this week's total allowance — base, plus a
    // temporary total when one is in effect, less this week's debt
    // payment — the same figure as the Home hero's effective
    // allowance. The breakdown reconciles: Base ± Temporary
    // increase/decrease − Debt Payment = Total. The Weekly
    // Allowance editor + Temporary Allowance live INSIDE the section
    // (build 33): the banner heads the section and the detail sits
    // below it on plain white, so the whole thing reads as one group
    // — the editor used to sit below the card, outside it.

    private var spendingCard: some View {
        FundsExpandableCard(
            title: FundSectionID.spending.displayName(customNames: appState.fundNames),
            amountText: spendingFaceText,
            isExpanded: appState.expandedCard == .spending,
            amountIsStatus: spendingFaceCents == nil,
            isLoading: spendingFaceCents == nil && viewModel.allowanceError == nil && !viewModel.cardsReady,
            theme: .spending,
            accessibilityLabel: spendingAccessibilityLabel,
            onToggle: { toggleCard(.spending) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .spending }
        ) {
            if let base = viewModel.baseAllowanceCents {
                // Build 36 (owner, Nov 16, 2026): the expanded
                // detail felt cramped — the breakdown rows sit 12pt
                // apart (was 8) and the blocks 16pt apart (was 12),
                // so the rows and the buttons breathe. Same
                // treatment on all four fund cards.
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        FundsBreakdownRow("Base", value: MoneyFormat.formatCents(base))
                        if let override = viewModel.debtWeek?.overrideCents, override != base {
                            let delta = override - base
                            FundsBreakdownRow(
                                delta > 0 ? "Temporary Increase" : "Temporary Decrease",
                                value: "\(delta > 0 ? "+" : "−")\(MoneyFormat.formatCents(abs(delta)))"
                            )
                        }
                        if let payment = viewModel.debtWeek?.debtPaymentCents, payment > 0 {
                            FundsBreakdownRow("Less Debt Payment", value: "−\(MoneyFormat.formatCents(payment))")
                        }
                        if let total = spendingFaceCents {
                            FundsBreakdownRow("Total", value: MoneyFormat.formatCents(total))
                        }
                    }
                    Divider()
                    SpendingAllowanceSection(viewModel: viewModel, bare: true) {
                        openForm = .temp
                    }
                }
            } else if let error = viewModel.allowanceError {
                FundsErrorBox(error)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 200, height: 16)
                    SkeletonBlock(width: 170, height: 16)
                    SkeletonBlock(width: 190, height: 16)
                }
            }
        }
        .accessibilityIdentifier("funds.spending")
    }

    /// This week's total allowance: the week's base available
    /// (base less this week's debt payment) plus any temporary
    /// amount — the same figure as the Home hero's effective
    /// allowance. Falls back to the stored base while the week's
    /// figures are still loading.
    private var spendingFaceCents: Int? {
        if let week = viewModel.debtWeek {
            return week.baseAvailableCents + week.tempCents
        }
        return viewModel.baseAllowanceCents
    }

    private var spendingFaceText: String {
        guard let cents = spendingFaceCents else {
            return ""
        }
        return MoneyFormat.formatCents(cents)
    }

    private var spendingAccessibilityLabel: String {
        guard let cents = spendingFaceCents else {
            return "Spending, could not load allowance, show breakdown"
        }
        return "Spending, \(MoneyFormat.formatCents(cents)) this week, show breakdown"
    }

    // MARK: - Extra Fund card (§9.1)

    private var fundCard: some View {
        FundsExpandableCard(
            title: FundSectionID.fund.displayName(customNames: appState.fundNames),
            amountText: fundFaceText,
            isExpanded: appState.expandedCard == .fund,
            amountIsStatus: viewModel.fundSummary == nil,
            isLoading: viewModel.fundSummary == nil && viewModel.fundError == nil && !viewModel.cardsReady,
            theme: .fund,
            accessibilityLabel: fundAccessibilityLabel,
            onToggle: { toggleCard(.fund) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .fund }
        ) {
            if let error = viewModel.fundError {
                FundsErrorBox(error)
            } else if let summary = viewModel.fundSummary {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        FundsBreakdownRow(
                            isAdmin ? "Spendable Available" : "Available to Request",
                            value: MoneyFormat.formatCents(summary.availableCents),
                            isNegative: summary.availableCents < 0
                        )
                        FundsBreakdownRow("Pending", value: MoneyFormat.formatCents(summary.pendingIncludingHeldCents))
                        FundsBreakdownRow("Total", value: MoneyFormat.formatCents(summary.totalCents))
                        // A shortfall is a labelled number, only
                        // when one exists (owner, Nov 15, 2026 —
                        // build 33: the old "Nothing owed back
                        // right now." sentence was confusing, and
                        // when nothing is owed the $0.00 face
                        // already says the fund is empty).
                        if summary.shortfallCents > 0 {
                            FundsBreakdownRow("Shortfall", value: MoneyFormat.formatCents(summary.shortfallCents))
                        }
                    }
                    // Three actions cannot sit side by side on an
                    // iPhone — their labels wrap (owner button
                    // audit, build 33). A vertical stack, full
                    // width, primary first, pale middle, tertiary
                    // last (the two-button-row order, extended).
                    VStack(alignment: .leading, spacing: 12) {
                        if isAdmin {
                            FundsPrimaryButton("Add Money") { openForm = .add }
                            FundsPaleButton("Spend from Fund") { openForm = .use }
                            // Owner, Nov 16, 2026 (build 40): record
                            // cash taken/spent out of Savings — the
                            // same "record on the fund, not a
                            // transaction" function as the charity
                            // cash gift. Available decreases, NO
                            // transaction row, recorded in the Savings
                            // Activity feed. Primary blue (blue, pale,
                            // blue, grey — no two adjacent share a
                            // color), same size as the others.
                            RecordCashSpentSection(
                                viewModel: viewModel,
                                fundName: FundSectionID.fund.displayName(customNames: appState.fundNames)
                            )
                            FundsTertiaryButton("Request Money") { openForm = .ask }
                        } else {
                            FundsTertiaryButton("Request Money") { openForm = .ask }
                        }
                    }
                    Divider()
                    fundActivitySection
                }
            } else {
                // Loading inside the expanded card: skeleton rows
                // shaped like the breakdown rows, no "Loading…"
                // text (owner loading language, Nov 12, 2026).
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 200, height: 16)
                    SkeletonBlock(width: 170, height: 16)
                    SkeletonBlock(width: 190, height: 16)
                }
            }
        }
        .accessibilityIdentifier("funds.extraFund")
    }

    /// Face text is only rendered when loaded: loading shows the
    /// shimmer amount block, failure the static grey block — never
    /// a "Loading…" line or a bare "—" in amount type.
    private var fundFaceText: String {
        guard let summary = viewModel.fundSummary else {
            return ""
        }
        return MoneyFormat.formatCents(summary.availableCents)
    }

    private var fundAccessibilityLabel: String {
        guard let summary = viewModel.fundSummary else {
            return "Extra Fund, could not load balances, show breakdown"
        }
        let word = isAdmin ? "available to use" : "available to request"
        if summary.pendingIncludingHeldCents > 0 {
            return "Extra Fund, \(MoneyFormat.formatCents(summary.availableCents)) \(word), \(MoneyFormat.formatCents(summary.pendingIncludingHeldCents)) pending, show breakdown"
        }
        return "Extra Fund, \(MoneyFormat.formatCents(summary.availableCents)) \(word), show breakdown"
    }

    // MARK: - Charity card (§9.1)

    private var charityCard: some View {
        FundsExpandableCard(
            title: FundSectionID.charity.displayName(customNames: appState.fundNames),
            amountText: charityFaceText,
            isExpanded: appState.expandedCard == .charity,
            amountIsStatus: viewModel.charitySummary == nil,
            isLoading: viewModel.charitySummary == nil && viewModel.charityError == nil && !viewModel.cardsReady,
            theme: .charity,
            accessibilityLabel: charityAccessibilityLabel,
            onToggle: { toggleCard(.charity) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .charity }
        ) {
            if let error = viewModel.charityError {
                FundsErrorBox(error)
            } else if let summary = viewModel.charitySummary {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        FundsBreakdownRow("Available", value: MoneyFormat.formatCents(summary.remainingCents))
                        FundsBreakdownRow("Given", value: MoneyFormat.formatCents(summary.givenCents))
                        // Pending gifts are computed but were never shown,
                        // so Available looked wrong until gifts post
                        // (F-P2-11).
                        if summary.pendingGiftCents > 0 {
                            FundsBreakdownRow("Pending gifts", value: MoneyFormat.formatCents(summary.pendingGiftCents))
                        }
                        FundsBreakdownRow("Total", value: MoneyFormat.formatCents(summary.committedCents))
                    }
                    // Build 37 (owner, Nov 16, 2026): the grey
                    // "Close" button is gone — the card already
                    // collapses by tapping its header/chevron, so
                    // the button was redundant clutter.
                    if isAdmin {
                        AddToCharitySection(
                            viewModel: viewModel,
                            fundName: FundSectionID.charity.displayName(customNames: appState.fundNames)
                        )
                    }
                    if isAdmin {
                        // Owner, Nov 16, 2026 (build 40): record a
                        // cash gift given off-card — Available
                        // decreases, Given increases, Total unchanged,
                        // NO transaction row. The middle of the three
                        // stacked buttons, so it is the PALE
                        // treatment (Nov 4, 2026: pale is the middle
                        // tier of a three-button row) — blue, pale,
                        // grey, no two adjacent share a color — and
                        // isLarge so all three are the same size.
                        RecordCashGiftSection(
                            viewModel: viewModel,
                            fundName: FundSectionID.charity.displayName(customNames: appState.fundNames)
                        )
                    }
                    if isAdmin {
                        // Owner, Nov 16, 2026 (build 40): "Record
                        // Income" is the GREY tertiary treatment,
                        // not primary blue — the stacked full-width
                        // Charity buttons must not share a color
                        // (standing no-adjacent-same-color rule).
                        // They stay the SAME SIZE: isLarge: true,
                        // matching "Add to Charity" and "Record a
                        // Gift" (17pt, 16pt vertical padding, full
                        // width).
                        HStack(spacing: 12) {
                            FundsTertiaryButton("Record Income", isLarge: true) {
                                correctingIncome = nil
                                openForm = .income
                            }
                        }
                    }
                    Divider()
                    CharityRateSection(viewModel: viewModel, bare: true)
                    Divider()
                    charityActivitySection
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 200, height: 16)
                    SkeletonBlock(width: 170, height: 16)
                    SkeletonBlock(width: 190, height: 16)
                }
            }
        }
        .accessibilityIdentifier("funds.charity")
    }

    private var charityFaceText: String {
        guard let summary = viewModel.charitySummary else {
            return ""
        }
        return MoneyFormat.formatCents(summary.remainingCents)
    }

    private var charityAccessibilityLabel: String {
        guard let summary = viewModel.charitySummary else {
            return "Charity, could not load, show breakdown"
        }
        if summary.committedCents == 0 && summary.givenCents == 0 {
            return "Charity, no charity tracked yet, show breakdown"
        }
        if summary.remainingCents < 0 {
            return "Charity, ahead by \(MoneyFormat.formatCents(-summary.remainingCents)), show breakdown"
        }
        return "Charity, \(MoneyFormat.formatCents(summary.remainingCents)) remaining, \(MoneyFormat.formatCents(summary.givenCents)) given, \(MoneyFormat.formatCents(summary.committedCents)) committed, show breakdown"
    }

    // MARK: - Carried Debt card (§9.1, build 29)
    //
    // The third fund section (owner, Nov 15, 2026): the debt
    // balance, what it is from, the rule in effect, and its actions.
    // The face is the current balance D, white on the black banner
    // (build 37 — the muted deep red #991b1b outline is gone).

    private var debtCard: some View {
        FundsExpandableCard(
            title: FundSectionID.debt.displayName(customNames: appState.fundNames),
            amountText: debtFaceText,
            isExpanded: appState.expandedCard == .debt,
            amountIsStatus: viewModel.debtWeek == nil,
            isLoading: viewModel.debtWeek == nil && viewModel.debtError == nil && !viewModel.cardsReady,
            theme: .debt,
            accessibilityLabel: debtAccessibilityLabel,
            onToggle: { toggleCard(.debt) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .debt }
        ) {
            if let error = viewModel.debtError {
                FundsErrorBox(error)
            } else if let week = viewModel.debtWeek {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        FundsMuted("Money spent over past weekly allowances.")
                        if let payment = week.debtPaymentCents {
                            FundsBreakdownRow("This Week's Payment", value: MoneyFormat.formatCents(payment))
                            FundsBreakdownRow("Remaining After This Week", value: MoneyFormat.formatCents(max(0, week.carriedDebtCents - payment)))
                        } else {
                            // Old server: the payment is unknown, so only
                            // the balance shows — never a $0 that would be wrong.
                            FundsBreakdownRow(FundSectionID.debt.displayName(customNames: appState.fundNames), value: MoneyFormat.formatCents(week.carriedDebtCents))
                        }
                    }
                    HStack(spacing: 12) {
                        if isAdmin && viewModel.debtRule != nil {
                            // "Pay from Fund" — the full "Pay from
                            // Extra Fund" wrapped to two lines on
                            // iPhone (owner, Nov 15, 2026 — build
                            // 33); the fund here is the Extra Fund,
                            // so nothing is lost.
                            FundsPrimaryButton("Pay from Fund") { openForm = .payDebt }
                            // No button that cannot work (owner, Nov 13):
                            // with no debt left there is nothing to clear.
                            if week.carriedDebtCents > 0 {
                                FundsTertiaryButton("Clear Debt") { openForm = .clearDebt }
                            }
                            // Build 37 (owner, Nov 16, 2026): the
                            // grey "Close" button is gone — the card
                            // collapses by tapping its header/chevron.
                        }
                    }
                    Divider()
                    DebtRuleSection(viewModel: viewModel, bare: true)
                    Divider()
                    debtActivitySection
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 200, height: 16)
                    SkeletonBlock(width: 170, height: 16)
                    SkeletonBlock(width: 190, height: 16)
                }
            }
        }
        .accessibilityIdentifier("funds.carriedDebt")
    }

    /// Face text is only rendered when loaded: loading shows the
    /// shimmer amount block, failure the static grey block — never
    /// a "Loading…" line or a bare "—" in amount type.
    private var debtFaceText: String {
        guard let week = viewModel.debtWeek else {
            return ""
        }
        return MoneyFormat.formatCents(week.carriedDebtCents)
    }

    private var debtAccessibilityLabel: String {
        guard let week = viewModel.debtWeek else {
            return "Carried Debt, could not load, show breakdown"
        }
        if week.carriedDebtCents == 0 {
            return "Carried Debt, no debt, show breakdown"
        }
        return "Carried Debt, \(MoneyFormat.formatCents(week.carriedDebtCents)) owed, show breakdown"
    }

    // MARK: - One container per fund (owner, Nov 15, 2026;
    // redesigned build 33)
    //
    // One fund IS one section: the fund's `FundsExpandableCard`
    // carries its coloured banner, and the detail — breakdown,
    // actions, editor, Activity — sits below that banner on plain
    // white, so the whole thing reads as one group. There is no outer
    // wrapper card any more (build 33): it was a plain white card
    // whose faint shadow was invisible against the page, so the
    // card and the sections below it read as loose rows instead
    // of one block. In reorder mode up/down arrows sit above
    // the card; tapping one moves the fund one step (build 34 —
    // the drag handle did not grab and drag easily).
    @ViewBuilder
    private func fundContainer(for id: FundSectionID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isRearranging {
                reorderArrows(for: id)
            }
            switch id {
            case .spending:
                spendingCard
            case .fund:
                fundCard
            case .charity:
                charityCard
            case .debt:
                debtCard
            }
        }
    }

    /// Move a fund one step in the reorder list (build 34): the
    /// order saves via the `fundOrder` onChange. The move itself
    /// keeps a short ease — it is a reorder, not an expand/collapse
    /// (those are instant since build 34, owner decision Nov 15).
    private func moveFund(_ id: FundSectionID, by offset: Int) {
        guard let from = fundOrder.firstIndex(of: id),
              fundOrder.indices.contains(from + offset) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            fundOrder.swapAt(from, from + offset)
        }
    }

    /// The up/down arrows shown above a fund's card in reorder mode
    /// (build 34 — they replace the drag handle, which did not grab
    /// and drag easily). Tapping an arrow moves the fund one step.
    /// An arrow that cannot move the fund any further is not shown
    /// at all — no greyed-out buttons, only buttons that work
    /// (owner rule, Nov 13, 2026).
    private func reorderArrows(for id: FundSectionID) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if let index = fundOrder.firstIndex(of: id) {
                if index > fundOrder.startIndex {
                    reorderArrowButton(systemName: "chevron.up", label: "Move \(id.displayName) up") {
                        moveFund(id, by: -1)
                    }
                }
                if index < fundOrder.index(before: fundOrder.endIndex) {
                    reorderArrowButton(systemName: "chevron.down", label: "Move \(id.displayName) down") {
                        moveFund(id, by: 1)
                    }
                }
            }
        }
    }

    /// One reorder arrow: a clearly tappable 44pt button, light
    /// grey fill like the tertiary treatment, ink chevron.
    private func reorderArrowButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
                .frame(width: 44, height: 44)
                .background(Color(hex: "#e5e7eb"))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(label)
    }

    private func toggleCard(_ card: ExpandedCard) {
        if appState.expandedCard == card {
            appState.expandedCard = nil
        } else {
            appState.expandedCard = card
        }
    }

    // MARK: - Dissolved More sections (§9.2)
    //
    // The old "More" card is gone (owner, Nov 12, 2026 — it was
    // unclear what it was for). Each fund has ONE "Activity &
    // Transactions" expandable (owner, Nov 15, 2026 — build 30,
    // fewer headers; renamed build 36, owner Nov 16, 2026 — the
    // section now includes the TRANSACTIONS that touched the fund,
    // not only fund activity events, in one combined feed): the
    // Extra Fund's top-ups + fund-charge transactions and the past
    // savings records share one, the Debt fund's payments and where
    // the debt came from share one, Charity's income + gift
    // transactions share one. Sub-parts keep a quiet muted inline
    // label, never a bold sub-header. Review is NOT here any more
    // (build 30): it lives on its own page off Transactions. Same
    // expand-in-place row as the old More card; the sections hide
    // while a form is open (the else branch above).

    private var fundActivitySection: some View {
        // ONE activity header per fund (owner, Nov 15, 2026 —
        // build 30): the top-ups and the past savings records share
        // this one expandable. The savings part keeps a quiet inline
        // label ("Past Savings", muted — not a bold header).
        // Top-ups stay admin-only; the savings records stay visible
        // to every role.
        fundsSectionRow(
            title: "Activity & Transactions",
            section: .fundActivity,
            isAdminOnly: false,
            hPad: 0
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if isAdmin {
                    FundTopupsHistory(viewModel: viewModel)
                    Divider()
                }
                Text("Past Savings")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                SavingsSection(viewModel: viewModel)
            }
        }
    }

    private var charityActivitySection: some View {
        fundsSectionRow(
            title: "Activity & Transactions",
            section: .charityActivity,
            isAdminOnly: true,
            hPad: 0
        ) {
            CharityIncomeHistory(
                viewModel: viewModel,
                correcting: $correctingIncome,
                openIncomeForm: Binding(
                    get: { openForm == .income },
                    set: { if $0 { openForm = .income } }
                )
            )
        }
    }

    private var debtActivitySection: some View {
        // ONE activity header (build 30): the payments and where
        // the debt came from share this expandable; the origin
        // keeps a quiet inline label, not its own bold header.
        // Build 36: debt has no transaction rows to add — the
        // overspend charges that created the debt are not
        // attributable per week (nothing stored), so the feed stays
        // payments + rule changes + week closes; nothing is
        // fabricated to fill a transactions slot.
        fundsSectionRow(
            title: "Activity & Transactions",
            section: .debtActivity,
            isAdminOnly: false,
            hPad: 0
        ) {
            VStack(alignment: .leading, spacing: 8) {
                DebtActivityView(viewModel: viewModel)
                Divider()
                Text("Where it came from")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                DebtHistoryView(viewModel: viewModel)
            }
        }
    }

    /// The expandable row itself (title + chevron + content), with
    /// no card chrome: the caller decides the chrome — bare inside
    /// its fund's card, or its own FundsCard for standalone
    /// Review. `hPad` lines the row's text up with its fund card's
    /// interior text (0 inside a fund — the card's expanded detail
    /// is already padded 20pt; 16 for the standalone Review card).
    ///
    /// Whole-row tap target (owner rule, Nov 11 2026, and the Nov
    /// 15, 2026 app-wide pass): the entire row is the toggle; the
    /// chevron is only a hint. `.contentShape(Rectangle())` makes
    /// the empty space between the title and the chevron respond
    /// too, and the row padding lives inside the Button so the
    /// padded edge toggles as well.
    @ViewBuilder
    private func fundsSectionRow<Content: View>(
        title: String,
        section: FundsMoreSection,
        isAdminOnly: Bool,
        hPad: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if !isAdminOnly || isAdmin {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    openMore = openMore == section ? nil : section
                } label: {
                    HStack {
                        Text(TitleCase.apply(to: title))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Spacer()
                        Text("⌄")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .rotationEffect(.degrees(openMore == section ? 180 : 0))
                    }
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if openMore == section {
                    content()
                        .padding(.horizontal, hPad)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

// MARK: - Past Savings Records (§9.2, read-only)
//
// Four numbers from `savings_ledger` kinds: Balance (latest attested
// `actual_balance_cents` — NEVER a sum of movements; "Not recorded yet"
// if none), Transferred in, Withdrawn, Interest / adjustments.
// Below: latest 20 records + "Showing the latest 20 records." when
// more exist. No form writes savings anymore.

public struct SavingsSection: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private var latestBalance: Int? {
        viewModel.savings
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            .compactMap { $0.actualBalanceCents }
            .first
    }

    private func sum(kind: String) -> Int {
        viewModel.savings.filter { $0.kind == kind }.reduce(0) { $0 + $1.amountCents }
    }

    /// Plain words for a stored savings kind, matching the summary
    /// labels above: transfer_in → "Transferred In", withdrawal →
    /// "Withdrawn", interest → "Interest", adjustment → "Adjustments"
    /// (kinds per supabase/savings-movements.sql:19 + 'adjustment'
    /// in live-savings-rpc.sql:35).
    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "transfer_in": return "Transferred In"
        case "withdrawal": return "Withdrawn"
        case "interest": return "Interest"
        case "adjustment": return "Adjustments"
        default: return kind.capitalized
        }
    }

    /// One savings-ledger line, MINIMAL in the overview (build 36,
    /// owner Nov 16, 2026): kind + amount only — the recorded
    /// balance, date and note expand on tap. Transfer-in and
    /// interest are money in — green with a "+" prefix under the
    /// shared kind rule; withdrawals and adjustments stay muted and
    /// plain. The recorded balance is a balance, never an inflow.
    private func savingsRecordRow(_ row: SavingsLedgerEntry) -> some View {
        let isInflow = row.kind == "transfer_in" || row.kind == "interest"
        let amount = TransactionFormatting.inflowDisplay(cents: row.amountCents)
        return FundsActivityRow {
            HStack(spacing: 4) {
                Text(kindLabel(row.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Text("·")
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(isInflow ? amount.text : MoneyFormat.formatCents(row.amountCents))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isInflow ? amount.color : Color(hex: "#6b7280"))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recorded balance \(row.actualBalanceCents.map { MoneyFormat.formatCents($0) } ?? "—")")
                if let createdAt = row.createdAt {
                    Text(MoneyFormat.fmtDateTime(createdAt))
                }
                if !row.note.isEmpty {
                    Text(row.note)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.savingsError {
                FundsErrorBox(error)
            } else if viewModel.savings.isEmpty {
                FundsMuted("No past savings records.")
            } else {
                FundsBreakdownRow(
                    "Balance",
                    value: latestBalance.map { MoneyFormat.formatCents($0) } ?? "Not recorded yet"
                )
                // "Transferred In" is money in: green with a "+"
                // prefix under the shared kind rule. A zero sum
                // stays plain "$0.00" (inflowDisplay's guard).
                let transferredIn = sum(kind: "transfer_in")
                FundsBreakdownRow(
                    "Transferred In",
                    value: TransactionFormatting.inflowDisplay(cents: transferredIn).text,
                    isInflow: transferredIn > 0
                )
                FundsBreakdownRow("Withdrawn", value: MoneyFormat.formatCents(sum(kind: "withdrawal")))
                FundsBreakdownRow(
                    "Interest / Adjustments",
                    value: MoneyFormat.formatCents(
                        viewModel.savings
                            .filter { $0.kind != "transfer_in" && $0.kind != "withdrawal" }
                            .reduce(0) { $0 + $1.amountCents }
                    )
                )
                if latestBalance == nil {
                    FundsMuted("Past savings records exist, but no balance was ever recorded for them — that is a missing balance, not $0.")
                }
                Divider()
                let latest = Array(viewModel.savings.prefix(20))
                ForEach(Array(latest.enumerated()), id: \.offset) { _, row in
                    savingsRecordRow(row)
                }
                if viewModel.savings.count > 20 {
                    FundsMuted("Showing the latest 20 records.")
                }
            }
        }
    }
}

// MARK: - Debt Activity + Where It Came From (§9.2, build 29)
//
// Debt Activity: every debt payment (all sources) plus the audit
// rows for rule changes, newest first, max 20. Where It Came From:
// the week_closes history — which weeks carried debt out, most
// recent first, max 8. Per-week overspend attribution is NOT stored
// anywhere (the engine's newDebt is never persisted), so no
// fabricated "overspent $X" figures — only the carried-out amount
// per week.

public struct DebtActivityView: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    private var entries: [Entry] {
        // Both sources carry ISO timestamps, so a plain string sort
        // is newest-first. The detail line carries the date; the
        // sort key itself is not shown.
        var dated: [(Entry, String)] = viewModel.debtPayments.map { payment in
            let label: String
            switch payment.source {
            case "extra_fund": label = "Paid from Extra Fund"
            case "surplus": label = "Paid from Surplus"
            case "clear": label = "Debt Cleared"
            default: label = "Debt Payment"
            }
            let detail = "\(payment.createdAt.map { MoneyFormat.displayDay($0) } ?? "") · Week of \(MoneyFormat.fmtLong(payment.weekStart))\(payment.note.isEmpty ? "" : " · \(payment.note)")"
            return (Entry(
                id: "payment-\(payment.id.uuidString)",
                title: "\(label) \(MoneyFormat.formatCents(payment.amountCents))",
                detail: detail
            ), payment.createdAt ?? "")
        }
        dated += viewModel.debtRuleAudit.map { row in
            (Entry(
                id: "audit-\(row.id.uuidString)",
                title: "Rule Changed",
                detail: "\(MoneyFormat.displayDay(row.createdAt)) · \(row.detail)"
            ), row.createdAt)
        }
        return dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.debtError {
                FundsErrorBox(error)
            } else if entries.isEmpty {
                FundsMuted("No debt payments yet.")
            } else {
                // Build 36 (owner, Nov 16, 2026): overview rows are
                // MINIMAL — the title only — and tapping a row
                // expands the detail (date, week, note) inline.
                ForEach(Array(entries.prefix(20).enumerated()), id: \.element.id) { index, entry in
                    FundsActivityRow {
                        Text(entry.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                    } detail: {
                        Text(entry.detail)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                    if index < min(entries.count, 20) - 1 {
                        Divider()
                    }
                }
                if entries.count > 20 {
                    FundsMuted("Showing the latest 20 entries.")
                }
            }
        }
    }
}

public struct DebtHistoryView: View {
    @ObservedObject public var viewModel: FundsViewModel

    public init(viewModel: FundsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.debtError {
                FundsErrorBox(error)
            } else if viewModel.debtHistory.isEmpty {
                FundsMuted("No closed weeks carried debt out.")
            } else {
                ForEach(Array(viewModel.debtHistory.prefix(8).enumerated()), id: \.element.weekStart) { index, close in
                    Text("Week of \(MoneyFormat.fmtLong(close.weekStart)) — \(MoneyFormat.formatCents(close.outgoingDebtCents)) carried out")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                    if index < min(viewModel.debtHistory.count, 8) - 1 {
                        Divider()
                    }
                }
                if viewModel.debtHistory.count > 8 {
                    FundsMuted("Showing the latest 8 weeks.")
                }
            }
        }
    }
}
