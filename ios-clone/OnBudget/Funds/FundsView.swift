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
// section (owner, Nov 15, 2026; redesigned build 33; build 64:
// the header is plain white with the fund name in its own colour,
// no solid banner) and its detail — breakdown, actions, editor,
// Activity — sits below it on plain white, so each fund reads as
// one group, not a card
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
    case ask
    case income
    /// Temporary Allowance — opened from the Spending section,
    /// presented as a form, never duplicated in Settings.
    case temp
    /// Pay Carried Debt from the Extra Fund (build 29).
    case payDebt
    /// Debt management (build 70, owner Nov 24, 2026): ONE sheet
    /// for the debt — Clear Debt + Adjust Debt — replacing the
    /// separate Clear Debt form and Edit Debt sheet. The mode
    /// picks which half of the sheet opens first.
    case manageDebt(DebtManagementSheet.Mode)
}

public enum FundsMoreSection: Equatable {
    case fundActivity
    case charityActivity
    case debtActivity

    var accessibilityID: String {
        switch self {
        case .fundActivity: return "funds.activityButton.fund"
        case .charityActivity: return "funds.activityButton.charity"
        case .debtActivity: return "funds.activityButton.debt"
        }
    }
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
        // Build 70 (owner, Nov 24, 2026): the plain word is
        // "Debt" — the old "Carried Debt" name is gone from the
        // flow. A household that stored a custom fund name
        // still sees its own name on the card (the owner can
        // rename it via the pencil); this default only names
        // the section when no custom name exists.
        case .debt: return "Debt"
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

    /// The fund's card theme (banner colour, text colour, glyph).
    public var theme: StatCardTheme {
        switch self {
        case .spending: return .spending
        case .fund: return .fund
        case .charity: return .charity
        case .debt: return .debt
        }
    }

    /// The Funds page's expansion slot for this fund (build 46 —
    /// the simpler Home's cards and quiet rows open their fund on
    /// the Funds tab via `AppState.openFund`).
    public var expandedCard: ExpandedCard {
        switch self {
        case .spending: return .spending
        case .fund: return .fund
        case .charity: return .charity
        case .debt: return .debt
        }
    }

    /// The fund's DEFAULT Home prominence (build 46 — the simpler
    /// Home mockup, owner Nov 18, 2026): Spending is the hero,
    /// Tzedaka the clear second card, Savings and Overspent (Past)
    /// quiet rows. The stored `fund_prominence` map overrides this
    /// per fund; a missing/blank/unknown stored value falls back
    /// here, so the mockup layout is what shows until the owner
    /// changes a card.
    public var defaultProminence: FundProminence {
        switch self {
        case .spending: return .hero
        case .charity: return .card
        case .fund, .debt: return .quiet
        }
    }

    /// How this fund shows on Home (build 46): the stored
    /// prominence when one is stored and valid, else the mockup
    /// default above.
    public func prominence(customProminence: [String: String]) -> FundProminence {
        FundProminence.resolved(customProminence[rawValue], default: defaultProminence)
    }

    /// Whether this fund may be hidden from Home (build 47 —
    /// owner, Nov 19, 2026: "The only ones that stay and are
    /// built in are spending & Charity"). Only Savings and
    /// Overspent (Past) can be removed from Home and added back;
    /// Spending and Tzedaka always stay.
    public var canHideFromHome: Bool {
        FundHomeVisibility.canHide(fundKey: rawValue)
    }

    /// Whether this fund is hidden from Home under the stored
    /// map (build 47). A built-in fund is never hidden, even if
    /// a value were stored for it.
    public func isHidden(customHidden: [String: Bool]) -> Bool {
        FundHomeVisibility.isHidden(fundKey: rawValue, hiddenMap: customHidden)
    }

    /// The one-line fund description (build 42 — owner, Nov 17,
    /// 2026: descriptions live behind an info icon in the card
    /// header, not as a text line in the expanded card). The debt
    /// line is the existing text, reused verbatim; the other three
    /// are new one-liners in the same plain voice — the owner did
    /// not supply their wording, so they are easy to reword here.
    public var fundDescription: String {
        switch self {
        case .spending: return "Money for this week's spending, from the weekly allowance."
        case .fund: return "Money set aside in savings — add to it, or take from it when you spend."
        case .charity: return "Money set aside for charity, given away as you choose."
        case .debt: return "Money spent over past weekly allowances."
        }
    }

    /// The icon to RENDER (build 41): the stored-or-default icon
    /// when it resolves as an SF Symbol, else the theme default.
    /// The rule lives in the kit (FundIconResolver) so the test
    /// suite can pin it; the app supplies the UIImage check (the
    /// Nov 16 handshake lesson: not every SF Symbol name resolves).
    public func resolvedIconName(customIcons: [String: String]) -> String {
        FundIconResolver.resolved(
            custom: customIcons[rawValue],
            default: theme.iconName
        ) { UIImage(systemName: $0) != nil }
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
    /// The fund currently being dragged in reorder mode (build 41).
    /// Build 44 (owner, Nov 18, 2026): the jiggle wobble is removed
    /// — no jiggle phase state any more.
    @State private var draggingId: FundSectionID?
    /// The Remove from Savings sheet (build 42, owner Nov 17,
    /// 2026): opened by the grey-tertiary "Remove from Savings"
    /// button on the Savings card, admin only.
    @State private var showRemoveFromSavings = false
    /// The Record a Donation sheet (build 64, B3): opened by the ink
    /// outline "Record a Donation" button on the Tzedaka card, admin
    /// only. Build 68 (item 30): RecordCashGiftSheet is now the ONE
    /// compact Tzedaka sheet (Add / Record a Donation choice) in
    /// CharityIncomeForm.swift — this state only drives the
    /// presentation from the B3 button row.
    @State private var showRecordGift = false
    /// The Weekly Budget Calculator popup (build 44, owner Nov
    /// 18, 2026): opened by the "Calculate" button in the
    /// expanded Spending card.
    @State private var showCalculator = false
    /// The merged Adjust This Week's Budget sheet (build 68,
    /// item 29): the ONE entry point for the one-time top-up
    /// and the temporary total on the Spending card.
    @State private var showAdjustWeeklyBudget = false
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
        // Build 74 (tour): the ScrollViewReader lets the tour
        // scroll its current target into view on step change
        // (see scrollTourAnchorIntoView).
        ScrollViewReader { proxy in
            ScrollView {
            VStack(spacing: 16) {
                // Build 65: the page select lives in the shell
                // (AppShellView) now — one control for all tabs,
                // so Funds no longer renders its own.
                if let form = openForm {
                    backButton
                    // The balance the open form acts on stays visible
                    // above it (F-P2-12); the sections below the cards
                    // stay hidden while a form is open.
                    formBalanceStrip(for: form)
                    switch form {
                    case .add:
                        AddMoneyForm(viewModel: viewModel, fundName: FundSectionID.fund.displayName(customNames: appState.fundNames), onClose: { openForm = nil })
                    case .ask:
                        AskFundForm(viewModel: viewModel, onClose: { openForm = nil })
                    case .income:
                        CharityIncomeForm(viewModel: viewModel, fundName: FundSectionID.charity.displayName(customNames: appState.fundNames), correcting: $correctingIncome, onClose: { openForm = nil })
                    case .temp:
                        TemporaryAllowanceView(viewModel: viewModel)
                    case .payDebt:
                        PayDebtForm(viewModel: viewModel, fundName: FundSectionID.fund.displayName(customNames: appState.fundNames), debtName: FundSectionID.debt.displayName(customNames: appState.fundNames), onClose: { openForm = nil })
                    case .manageDebt(let mode):
                        DebtManagementSheet(viewModel: viewModel, initialMode: mode, onClose: { openForm = nil })
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
                        ForEach(fundOrder, id: \.rawValue) { id in
                            fundContainer(for: id)
                        }
                    }
                }
            }
            .padding()
        }
        // Build 74 (tour): scroll the current step's target into
        // view on step change — the rate editor and the fund
        // cards can sit below the fold, where the cutout would
        // point at nothing visible.
        .onChange(of: appState.tour.stepIndex) { _, _ in
            scrollTourAnchorIntoView(proxy, tour: appState.tour, tab: .funds)
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
        // through the ONE root top toast (ContentView
        // .toastOverlay, the standing rule: top popup only, auto-
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
        // Rename popup (build 37 — fund rename, owner Nov 16,
        // 2026; build 41 — it is now the combined edit sheet: the
        // pencil opens it for the name AND the icon; build 43,
        // item 17 — full-screen cover, not a detent sheet): a fund's
        // Rename button sets `renamingFund`. On a successful save
        // the shared `appState.fundNames` / `appState.fundIcons`
        // are refreshed from the RPC results, so the new name and
        // icon update everywhere at once (Funds, Home).
        .fullScreenCover(item: $renamingFund) { section in
            RenameFundSheet(
                section: section,
                currentName: section.displayName(customNames: appState.fundNames),
                currentIcon: appState.fundIcons[section.rawValue] ?? "",
                currentProminence: section.prominence(customProminence: appState.fundProminence),
                currentHidden: section.isHidden(customHidden: appState.fundHidden),
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
                        // Build 54: gated — a rename changes the
                        // snapshot's fund names, so this reloads;
                        // a no-op rename does not burn the budget.
                        appState.reloadWidgetTimelinesIfSnapshotChanged()
                    }
                },
                onIconsSaved: { icons in
                    appState.fundIcons = icons
                },
                onProminenceSaved: { map in
                    appState.fundProminence = map
                },
                onHiddenSaved: { map in
                    appState.fundHidden = map
                },
                onClose: { renamingFund = nil }
            )
        }
        .task {
            // Build 43 (owner, Nov 17, 2026 — item 16): the view
            // model composes toasts/alerts with the funds' CURRENT
            // display names, so it reads the same `appState.fundNames`
            // source as the views — synced here and on every rename
            // below.
            viewModel.fundNames = appState.fundNames
            loadFundOrder()
            await viewModel.refresh()
        }
        .onChange(of: appState.fundNames) { _, names in
            viewModel.fundNames = names
        }
        .onChange(of: fundOrder) { _, _ in
            saveFundOrder()
        }
        // Leaving reorder mode clears the drag state. Build 44
        // (owner, Nov 18, 2026): the jiggle wobble is removed, so
        // there is no jiggle driver here any more — the cards sit
        // still in reorder mode.
        .onChange(of: isRearranging) { _, rearranging in
            if !rearranging { draggingId = nil }
        }
        .refreshable {
            await viewModel.refresh()
        }
        }
    }

    /// Reorder / Done, above the funds (build 30). Reorder mode
    /// shows up/down arrows above each fund's card; Done exits and
    /// the order is already saved. The Reorder control is a blue
    /// primary button (owner, Nov 15, 2026 — the grey "Rearrange"
    /// pill looked ugly); same treatment as Save. Build 41 (owner,
    /// Nov 16, 2026): the Reorder button keeps the 3-LINES
    /// (hamburger / drag-handle) glyph. Build 44 (owner, Nov 18,
    /// 2026): the Reorder button is the ONLY way to enter reorder
    /// mode — the long-press-on-a-card entry is removed, so the
    /// cards never jiggle.
    private var rearrangeRow: some View {
        HStack {
            Spacer()
            if isRearranging {
                FundsSmallPrimaryButton("Done") { isRearranging = false }
            } else {
                FundsSmallPrimaryButton("Reorder", systemImage: "line.3.horizontal") { isRearranging = true }
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
    /// Build 77 (owner, Nov 25, 2026): the loading skeleton
    /// blocks are larger (200x20, was 160x16) — the small
    /// boxes read as too small while loading.
    @ViewBuilder
    private func formBalanceStrip(for form: FundsForm) -> some View {
        switch form {
        case .add, .ask:
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
                        SkeletonBlock(width: 200, height: 20)
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
                        SkeletonBlock(width: 200, height: 20)
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
                        SkeletonBlock(width: 200, height: 20)
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
                        SkeletonBlock(width: 200, height: 20)
                    }
                    if let summary = viewModel.fundSummary {
                        FundsBreakdownRow("Available in \(FundSectionID.fund.displayName(customNames: appState.fundNames))", value: MoneyFormat.formatCents(summary.availableCents), isNegative: summary.availableCents < 0)
                    }
                }
            }
        case .manageDebt:
            FundsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let debt = viewModel.debtBalanceCents {
                        FundsBreakdownRow(FundSectionID.debt.displayName(customNames: appState.fundNames), value: MoneyFormat.formatCents(debt))
                    } else if let error = viewModel.debtError {
                        FundsErrorBox(error)
                    } else {
                        SkeletonBlock(width: 200, height: 20)
                    }
                }
            }
        }
    }

    // MARK: - Spending card (§9.1, build 30)
    //
    // The weekly budget fund (moved from the Settings Budget card):
    // the face is what's LEFT to spend this week — the same
    // Available figure as the Home hero (`WeekResult.availableCents`:
    // this week's total allowance less what was spent) — NOT the
    // total allowance (build 42, owner Nov 17, 2026: the face
    // showed $400.00, the Total, while $74.78 was already spent).
    // The breakdown still reconciles with the Total row: Base ±
    // Temporary increase/decrease − Debt Payment = Total. The
    // Weekly Allowance editor + Temporary Allowance live INSIDE
    // the section (build 33): the banner heads the section and the
    // detail sits below it on plain white, so the whole thing reads
    // as one group — the editor used to sit below the card, outside
    // it.

    private var spendingCard: some View {
        FundsExpandableCard(
            title: FundSectionID.spending.displayName(customNames: appState.fundNames),
            amountText: spendingFaceText,
            isExpanded: appState.expandedCard == .spending,
            amountIsStatus: spendingFaceCents == nil,
            // Build 42 (owner, Nov 17, 2026): the ONE page-ready
            // gate — `!cardsReady` — not this card's own data.
            // Gating on the card's own figures let the first card
            // to load reveal while the others still showed
            // skeletons (a partial page). Every card uses this
            // same condition, so all four reveal together; a failed
            // load still flips `cardsReady` (the view model awaits
            // success-or-failure), so the card shows its error box,
            // never a skeleton forever.
            isLoading: !viewModel.cardsReady,
            theme: .spending,
            iconName: FundSectionID.spending.resolvedIconName(customIcons: appState.fundIcons),
            isReorderMode: isRearranging,
            accessibilityLabel: spendingAccessibilityLabel,
            onToggle: { toggleCard(.spending) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .spending },
            fundDescription: FundSectionID.spending.fundDescription,
        ) {
            if !viewModel.cardsReady {
                // The page has not revealed yet: skeletons shaped
                // like the breakdown rows, no "Loading…" text
                // (owner loading language, Nov 12, 2026) — even if
                // this card's own figures already arrived, the
                // detail stays hidden until every card is ready.
                FundsDetailSkeleton()
            } else if let error = viewModel.allowanceError ?? viewModel.debtError {
                // The face needs the week's figures (compute-week),
                // so a debt-load failure fails this card too — the
                // face shows the static grey block and the detail
                // carries the error box.
                FundsErrorBox(error)
            } else if let base = viewModel.baseAllowanceCents {
                // Build 36 (owner, Nov 16, 2026): the expanded
                // detail felt cramped — the breakdown rows sit 12pt
                // apart (was 8) and the blocks 16pt apart (was 12),
                // so the rows and the buttons breathe. Same
                // treatment on all four fund cards.
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        FundsBreakdownRow("Base", value: MoneyFormat.formatCents(base))
                        // Build 43, item 21 (owner, Nov 17, 2026):
                        // the "Top Ups" line — the total of one-time
                        // top-ups added to the current week via
                        // "Top Up Budget". Shown ALWAYS, even $0.00:
                        // the owner wants Base + Top Ups = Total to
                        // read explicitly, not Base and Total
                        // repeating the same number. Until
                        // supabase/weekly-budget-topups.sql is
                        // applied live this reads $0.00.
                        FundsBreakdownRow("Top Ups", value: MoneyFormat.formatCents(viewModel.topUpsCents))
                        if let delta = viewModel.temporaryAllowanceDeltaCents {
                            FundsBreakdownRow(
                                delta > 0 ? "Temporary Increase" : "Temporary Decrease",
                                value: "\(delta > 0 ? "+" : "−")\(MoneyFormat.formatCents(abs(delta)))"
                            )
                        }
                        if let payment = viewModel.debtWeek?.debtPaymentCents, payment > 0 {
                            FundsBreakdownRow("Less \(FundSectionID.debt.displayName(customNames: appState.fundNames)) Payment", value: "−\(MoneyFormat.formatCents(payment))")
                        }
                        if let total = spendingTotalCents {
                            FundsBreakdownRow("Total", value: MoneyFormat.formatCents(total))
                        }
                    }
                    Divider()
                    // Build 68 (item 29): "Calculate" sits with
                    // the ONE merged entry point at the bottom of
                    // the card — Calculate, then "Adjust This
                    // Week's Budget" (the old Top Up Budget and
                    // Set Temporary Allowance buttons are gone).
                    // The calculator sheet itself is unchanged and
                    // the button stays visible to every role
                    // (local-only, suggestion-only).
                    SpendingAllowanceSection(viewModel: viewModel, bare: true, onCalculate: { showCalculator = true }) {
                        showAdjustWeeklyBudget = true
                    }
                    // Build 68 (item 29): the merged sheet holds
                    // the Add / Set Total choice; the old separate
                    // Top Up popup and Set This Week's Budget sheet
                    // have no entry point on this card any more.
                    .sheet(isPresented: $showAdjustWeeklyBudget) {
                        AdjustWeeklyBudgetSheet(viewModel: viewModel, onClose: { showAdjustWeeklyBudget = false })
                    }
                    // Build 68 (item 9): the Calculator is a
                    // fitted sheet (detents live in the sheet
                    // itself), not a full-screen cover — the
                    // content is a ScrollView, so it works in a
                    // compact popup on iPad.
                    // Build 67: the Calculator reads its recurring
                    // costs from the tagged expenses (this page's
                    // view model loads them) — the LIVE ones only,
                    // so an expense in the Trash stops counting
                    // at once.
                    .sheet(isPresented: $showCalculator) {
                        WeeklyBudgetCalculatorSheet(
                            householdId: viewModel.context.householdId,
                            charityName: FundSectionID.charity.displayName(customNames: appState.fundNames),
                            viewModel: viewModel,
                            onClose: { showCalculator = false }
                        )
                    }
                }
            } else {
                // Unreachable once the page is ready — every load
                // sets its figures or its error — kept as a safe
                // fallback rather than a blank detail.
                FundsDetailSkeleton()
            }
        }
        .accessibilityIdentifier("funds.spending")
    }

    /// What's left to spend this week (build 42, owner Nov 17,
    /// 2026): the Home hero's Available figure —
    /// `WeekResult.availableCents`, this week's total allowance
    /// less what was spent. Nil while the week's figures are
    /// unknown — there is no fallback to the stored base, because
    /// the base IS the Total, and showing it here was the bug
    /// ($400.00 face with $74.78 already spent).
    private var spendingFaceCents: Int? {
        viewModel.debtWeek?.availableCents
    }

    /// This week's TOTAL allowance for the breakdown row only:
    /// the week's base available (base less this week's debt
    /// payment) plus any temporary amount — the same figure the
    /// face used to show, and the same figure as the Home hero's
    /// effective allowance. Falls back to the stored base while
    /// the week's figures are still loading.
    private var spendingTotalCents: Int? {
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
        let name = FundSectionID.spending.displayName(customNames: appState.fundNames)
        guard let cents = spendingFaceCents else {
            return "\(name), could not load allowance, show breakdown"
        }
        return "\(name), \(MoneyFormat.formatCents(cents)) left this week, show breakdown"
    }

    // MARK: - Extra Fund card (§9.1)

    private var fundCard: some View {
        FundsExpandableCard(
            title: FundSectionID.fund.displayName(customNames: appState.fundNames),
            amountText: fundFaceText,
            isExpanded: appState.expandedCard == .fund,
            amountIsStatus: viewModel.fundSummary == nil,
            // Build 42 (owner, Nov 17, 2026): the ONE page-ready
            // gate — `!cardsReady` (see spendingCard). A fast card
            // must not reveal while the others still show skeletons.
            isLoading: !viewModel.cardsReady,
            theme: .fund,
            iconName: FundSectionID.fund.resolvedIconName(customIcons: appState.fundIcons),
            isReorderMode: isRearranging,
            accessibilityLabel: fundAccessibilityLabel,
            onToggle: { toggleCard(.fund) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .fund },
            fundDescription: FundSectionID.fund.fundDescription,
            // Build 68 (item 26): Show on Home lives INSIDE the
            // card (FundsExpandableCard), not in a floating row
            // below it.
            showHomeVisibility: FundSectionID.fund.canHideFromHome,
            isHiddenFromHome: FundSectionID.fund.isHidden(customHidden: appState.fundHidden),
            onSetHiddenFromHome: { hidden in
                Task {
                    if let map = await viewModel.setFundHidden(section: .fund, hidden: hidden) {
                        appState.fundHidden = map
                    }
                }
            },
        ) {
            if !viewModel.cardsReady {
                // The page has not revealed yet: skeletons shaped
                // like the breakdown rows (see spendingCard).
                FundsDetailSkeleton()
            } else if let error = viewModel.fundError {
                FundsErrorBox(error)
            } else if let summary = viewModel.fundSummary {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Build 43 (owner, Nov 17, 2026): just
                        // "Available" — the "Spendable" qualifier
                        // added nothing the card does not already say.
                        FundsBreakdownRow(
                            "Available",
                            value: MoneyFormat.formatCents(summary.availableCents),
                            isNegative: summary.availableCents < 0
                        )
                        // Pending (build 42, owner Nov 17, 2026 —
                        // the $650 live bug): pending releases +
                        // held weeks PLUS pending top-ups
                        // (`savingsPendingCents`). Pending top-ups
                        // used to sit only on a separate
                        // "Pending Top-Ups" row, so Pending read
                        // $0.00 (and Total $0.00) while $650 was
                        // on its way in. The separate row is gone
                        // — it would double-present the same money.
                        FundsBreakdownRow("Pending", value: MoneyFormat.formatCents(viewModel.savingsPendingCents))
                        FundsBreakdownRow("Total", value: MoneyFormat.formatCents(viewModel.savingsTotalCents))
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
                    // Two buttons, full width, primary first,
                    // grey tertiary second (the two-button-row
                    // order, Nov 4, 2026 — no two adjacent share
                    // a colour). Owner, Nov 17, 2026 (build 42):
                    // the old Spend button + the old cash-spent
                    // section are ONE button now — "Take Money Out"
                    // (build 56, owner Nov 22, 2026: renamed from
                    // "Remove from Savings" — plain language,
                    // parallel to "Add Money").
                    // Both did the same thing (money out of the
                    // fund, no transaction row) and the pale middle
                    // button of a three-button row is gone with
                    // them. The button opens the remove sheet,
                    // which spends Available first, then Pending
                    // top-ups, then carried debt (the build-42
                    // waterfall) — it does NOT cap the amount at
                    // Available the way the old cash-spent sheet did.
                    if isAdmin {
                        VStack(alignment: .leading, spacing: 12) {
                            FundsPrimaryButton("Add Money") { openForm = .add }
                            FundsTertiaryButton("Take Money Out") { showRemoveFromSavings = true }
                                .accessibilityIdentifier("funds.removeFromSavings")
                                // Build 43 (owner, Nov 17, 2026 — item 17):
                                // full-screen cover, not a detent sheet.
                                .fullScreenCover(isPresented: $showRemoveFromSavings) {
                                    RemoveFromSavingsSheet(
                                        viewModel: viewModel,
                                        fundName: FundSectionID.fund.displayName(customNames: appState.fundNames),
                                        onClose: { showRemoveFromSavings = false }
                                    )
                                }
                        }
                    }
                    Divider()
                    fundActivitySection
                }
            } else {
                // Loading inside the expanded card: skeleton rows
                // shaped like the breakdown rows, no "Loading…"
                // text (owner loading language, Nov 12, 2026).
                FundsDetailSkeleton()
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
        let name = FundSectionID.fund.displayName(customNames: appState.fundNames)
        guard let summary = viewModel.fundSummary else {
            return "\(name), could not load balances, show breakdown"
        }
        let word = isAdmin ? "available to use" : "available to request"
        if viewModel.savingsPendingCents > 0 {
            return "\(name), \(MoneyFormat.formatCents(summary.availableCents)) \(word), \(MoneyFormat.formatCents(viewModel.savingsPendingCents)) pending, show breakdown"
        }
        return "\(name), \(MoneyFormat.formatCents(summary.availableCents)) \(word), show breakdown"
    }

    // MARK: - Charity card (§9.1)

    private var charityCard: some View {
        FundsExpandableCard(
            title: FundSectionID.charity.displayName(customNames: appState.fundNames),
            amountText: charityFaceText,
            isExpanded: appState.expandedCard == .charity,
            // Build 64 (F-16): the face is a status (static grey
            // block) when the transactions load failed too — the
            // charity summary's pending-gift figure derives from
            // `allTransactions`, so a failed transactions load
            // would leave Available overstated (pending gifts not
            // deducted). A failed load shows an error state, never
            // a wrong number.
            amountIsStatus: viewModel.charitySummary == nil || viewModel.transactionsError != nil,
            // Build 42 (owner, Nov 17, 2026): the ONE page-ready
            // gate — `!cardsReady` (see spendingCard).
            isLoading: !viewModel.cardsReady,
            theme: .charity,
            iconName: FundSectionID.charity.resolvedIconName(customIcons: appState.fundIcons),
            isReorderMode: isRearranging,
            accessibilityLabel: charityAccessibilityLabel,
            onToggle: { toggleCard(.charity) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .charity },
            fundDescription: FundSectionID.charity.fundDescription,
        ) {
            if !viewModel.cardsReady {
                // The page has not revealed yet: skeletons shaped
                // like the breakdown rows (see spendingCard).
                FundsDetailSkeleton()
            } else if let error = viewModel.charityError ?? viewModel.transactionsError {
                // Build 64 (F-16): a failed transactions load
                // fails this card too — its pending-gift figure
                // comes from that load, so the summary cannot be
                // trusted without it. Error state, never $0 and
                // never an overstated Available.
                FundsErrorBox(error)
            } else if let summary = viewModel.charitySummary {
                VStack(alignment: .leading, spacing: 20) {
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
                    // Build 56 (owner, Nov 22, 2026): the Default
                    // Tzedaka Rate sits ABOVE the buttons now —
                    // right after the breakdown, like the Spending
                    // and Overspent cards, where the fields already
                    // sit above the buttons.
                    Divider()
                    CharityRateSection(viewModel: viewModel, bare: true, fundNames: appState.fundNames)
                        // Walkthrough anchor (build 48): the rate
                        // editor — "change the rate — set it to 0%
                        // to pause giving" (build 74: no Off switch).
                        .tourAnchor(.charityRules, tour: appState.tour)
                        .id(TourAnchor.charityRules)
                    // Build 37 (owner, Nov 16, 2026): the grey
                    // "Close" button is gone — the card already
                    // collapses by tapping its header/chevron, so
                    // the button was redundant clutter.
                    // Build 64 (C-3 B3, owner Nov 23, 2026): ONE
                    // solid-blue primary full-width on top ("Add
                    // to Tzedaka"), then "Record a Donation" (ink
                    // outline) below it. Build 65 (owner, Nov 23,
                    // 2026 — item 8): "Record Income" is gone from
                    // this card — recording income is an income
                    // action, not a charity action — it lives in
                    // the "+ Add" flow now (AddTransactionView),
                    // which presents the same CharityIncomeForm.
                    // The correction flow is untouched: Correct in
                    // Activity still opens the form via .income.
                    // Build 66 (owner, Nov 23, 2026): "Record a
                    // Gift" is renamed "Record a Donation",
                    // cross app — same action, same sheet.
                    if isAdmin {
                        VStack(alignment: .leading, spacing: 12) {
                            AddToCharitySection(
                                viewModel: viewModel,
                                fundName: FundSectionID.charity.displayName(customNames: appState.fundNames)
                            )
                            // Owner, Nov 16, 2026 (build 40):
                            // record a cash donation given off-card
                            // — Available decreases, Given
                            // increases, Total unchanged, NO
                            // transaction row. The sheet still
                            // lives in CharityIncomeForm.swift
                            // (RecordCashGiftSheet); the button
                            // here is the B3 ink outline, and
                            // RecordCashGiftSection (pale) is no
                            // longer used on this card.
                            FundsInkOutlineButton("Record a Donation", isLarge: true) {
                                showRecordGift = true
                            }
                            .accessibilityIdentifier("funds.recordCashGift")
                            // Build 68 (item 30): RecordCashGiftSheet
                            // is now the single compact Tzedaka sheet
                            // (Add / Record a Donation choice), so it
                            // presents as a fitted sheet, not a
                            // full-screen cover.
                            .sheet(isPresented: $showRecordGift) {
                                RecordCashGiftSheet(
                                    viewModel: viewModel,
                                    fundName: FundSectionID.charity.displayName(customNames: appState.fundNames),
                                    onClose: { showRecordGift = false }
                                )
                            }
                        }
                    }
                    Divider()
                    charityActivitySection
                }
            } else {
                FundsDetailSkeleton()
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
        let name = FundSectionID.charity.displayName(customNames: appState.fundNames)
        guard let summary = viewModel.charitySummary else {
            return "\(name), could not load, show breakdown"
        }
        if summary.committedCents == 0 && summary.givenCents == 0 {
            return "\(name), no charity tracked yet, show breakdown"
        }
        if summary.remainingCents < 0 {
            return "\(name), ahead by \(MoneyFormat.formatCents(-summary.remainingCents)), show breakdown"
        }
        return "\(name), \(MoneyFormat.formatCents(summary.remainingCents)) remaining, \(MoneyFormat.formatCents(summary.givenCents)) given, \(MoneyFormat.formatCents(summary.committedCents)) committed, show breakdown"
    }

    // MARK: - Carried Debt card (§9.1, build 29)
    //
    // The third fund section (owner, Nov 15, 2026): the debt
    // balance, what it is from, the rule in effect, and its actions.
    // The face is the current balance D, in ink on the white card
    // (build 64, B2 — the black banner is gone).

    private var debtCard: some View {
        FundsExpandableCard(
            title: FundSectionID.debt.displayName(customNames: appState.fundNames),
            amountText: debtFaceText,
            isExpanded: appState.expandedCard == .debt,
            amountIsStatus: viewModel.debtWeek == nil,
            // Build 42 (owner, Nov 17, 2026): the ONE page-ready
            // gate — `!cardsReady` (see spendingCard).
            isLoading: !viewModel.cardsReady,
            theme: .debt,
            iconName: FundSectionID.debt.resolvedIconName(customIcons: appState.fundIcons),
            isReorderMode: isRearranging,
            accessibilityLabel: debtAccessibilityLabel,
            onToggle: { toggleCard(.debt) },
            // Pencil by the name (owner, Nov 16, 2026 — build 40):
            // admin-only, opens the rename sheet. The full-width
            // Rename button in the detail is gone.
            isAdmin: isAdmin,
            onRename: { renamingFund = .debt },
            fundDescription: FundSectionID.debt.fundDescription,
            // Build 68 (item 26): Show on Home lives INSIDE the
            // card (FundsExpandableCard), not in a floating row
            // below it.
            showHomeVisibility: FundSectionID.debt.canHideFromHome,
            isHiddenFromHome: FundSectionID.debt.isHidden(customHidden: appState.fundHidden),
            onSetHiddenFromHome: { hidden in
                Task {
                    if let map = await viewModel.setFundHidden(section: .debt, hidden: hidden) {
                        appState.fundHidden = map
                    }
                }
            },
        ) {
            if !viewModel.cardsReady {
                // The page has not revealed yet: skeletons shaped
                // like the breakdown rows (see spendingCard).
                FundsDetailSkeleton()
            } else if let error = viewModel.debtError {
                FundsErrorBox(error)
            } else if let week = viewModel.debtWeek {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Build 42 (owner, Nov 17, 2026): the
                        // "Money spent over past weekly
                        // allowances." description line is gone
                        // from here — it lives behind the ⓘ in
                        // the card header now.
                        if let payment = week.debtPaymentCents {
                            FundsBreakdownRow("This Week's Payment", value: MoneyFormat.formatCents(payment))
                            FundsBreakdownRow("Remaining After This Week", value: MoneyFormat.formatCents(max(0, week.carriedDebtCents - payment)))
                        } else {
                            // Old server: the payment is unknown, so only
                            // the balance shows — never a $0 that would be wrong.
                            FundsBreakdownRow(FundSectionID.debt.displayName(customNames: appState.fundNames), value: MoneyFormat.formatCents(week.carriedDebtCents))
                        }
                    }
                    // Build 42 (owner, Nov 17, 2026 — debt card
                    // section order): the Debt Repayment Rule
                    // comes BEFORE the action buttons — Balances
                    // → Rule → Actions → Activity & Transactions.
                    Divider()
                    DebtRuleSection(viewModel: viewModel, bare: true, fundNames: appState.fundNames)
                    Divider()
                    // Three actions cannot sit side by side on an
                    // iPhone — their labels wrap (owner button
                    // audit, build 33). A vertical stack, full
                    // width — build 64 (C-3 B3): one solid-blue
                    // primary first, then two OUTLINES in different
                    // colours (ink, then darker grey), so no group
                    // of three shares a colour. The pale middle
                    // tier is retired for three-button groups.
                    // Build 70 (owner, Nov 24, 2026): ONE Debt
                    // sheet — "Adjust Debt" and "Clear Debt" both
                    // open it, pre-set to that mode. The old "Edit
                    // Overspent (Past)" button is gone; the plain
                    // word is "Debt".
                    if isAdmin {
                        VStack(alignment: .leading, spacing: 12) {
                            // "Pay from <Fund>" — the full "Pay
                            // from Savings" wrapped to two lines
                            // on iPhone (owner, Nov 15, 2026 —
                            // build 33), so the label uses the
                            // fund's CURRENT display name
                            // (build 41) and stays short. Build 42
                            // (owner, Nov 17, 2026 — verified):
                            // the button no longer hides when the
                            // repayment rule failed to load — the
                            // `pay_debt_from_fund` RPC never reads
                            // the rule (it checks admin, a debt
                            // balance, and fund cover server-side),
                            // so a failed rule read must not block
                            // paying. It hides only when there is
                            // no debt: no button that cannot work
                            // (owner, Nov 13, 2026).
                            if week.carriedDebtCents > 0 {
                                FundsPrimaryButton("Pay from \(FundSectionID.fund.displayName(customNames: appState.fundNames))") { openForm = .payDebt }
                            }
                            FundsInkOutlineButton("Adjust Debt") { openForm = .manageDebt(.adjust) }
                            // No button that cannot work (owner, Nov 13):
                            // with no debt left there is nothing to clear.
                            if week.carriedDebtCents > 0 {
                                FundsSlateOutlineButton("Clear Debt") { openForm = .manageDebt(.clear) }
                            }
                            // Build 37 (owner, Nov 16, 2026): the
                            // grey "Close" button is gone — the card
                            // collapses by tapping its header/chevron.
                        }
                    }
                    Divider()
                    debtActivitySection
                }
            } else {
                FundsDetailSkeleton()
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
        let name = FundSectionID.debt.displayName(customNames: appState.fundNames)
        guard let week = viewModel.debtWeek else {
            return "\(name), could not load, show breakdown"
        }
        if week.carriedDebtCents == 0 {
            return "\(name), no debt, show breakdown"
        }
        return "\(name), \(MoneyFormat.formatCents(week.carriedDebtCents)) owed, show breakdown"
    }

    // MARK: - One container per fund (owner, Nov 15, 2026;
    // redesigned build 33)
    //
    // One fund IS one section: the fund's `FundsExpandableCard`
    // carries its coloured name, and the detail — breakdown,
    // actions, editor, Activity — sits below that header on plain
    // white, so the whole thing reads as one group. There is no outer
    // wrapper card any more (build 33): it was a plain white card
    // whose faint shadow was invisible against the page, so the
    // card and the sections below it read as loose rows instead
    // of one block. In reorder mode up/down arrows sit above
    // the card; tapping one moves the fund one step (build 34 —
    // the drag handle did not grab and drag easily).
    @ViewBuilder
    private func fundContainer(for id: FundSectionID) -> some View {
        // Owner, Nov 25, 2026: reorder is drag-only now — the
        // up/down arrows (build 34 fallback) are gone, and so are
        // moveFund / reorderArrows / reorderArrowButton (they had
        // no other caller). The drag grip in the card header
        // (FundsExpandableCard) is the only reorder affordance.
        // The drag itself (.onDrag/.onDrop below) is unchanged.
        VStack(alignment: .leading, spacing: 12) {
            switch id {
            case .spending:
                spendingCard
            case .fund:
                fundCard
                    // Walkthrough anchor (build 48): the Savings card.
                    .tourAnchor(.savingsCard, tour: appState.tour)
                    .id(TourAnchor.savingsCard)
            case .charity:
                charityCard
            case .debt:
                debtCard
                    // Walkthrough anchor (build 48): the Overspent card.
                    .tourAnchor(.debtCard, tour: appState.tour)
                    .id(TourAnchor.debtCard)
            }
            // Build 68 (item 26): the floating "Hidden from
            // Home." + "Show on Home" row below the card is gone
            // — the control lives INSIDE the fund card itself
            // (FundsExpandableCard's Show on Home toggle), so a
            // hidden fund says so where it belongs.
        }
        // Build 44 (owner, Nov 18, 2026): the long-press entry into
        // reorder mode and the jiggle wobble are removed — the cards
        // never shift or tilt. The ONLY way into reorder mode is the
        // Reorder button above the cards. A tap still expands the
        // card outside reorder mode; while reordering, the header
        // tap is a no-op (FundsExpandableCard), so nothing here
        // needs to guard the tap.
        // The card being dragged fades a little so the user can see
        // which one is in their hand.
        .opacity(isRearranging && draggingId == id ? 0.55 : 1)
        // Drag to move (owner, Nov 16, 2026 — build 41): only in
        // reorder mode, so a normal scroll never starts a drag. The
        // drop delegate moves the fund live as it is dragged over
        // another card, like the iOS Home Screen.
        .if(isRearranging) { view in
            view
                .onDrag {
                    draggingId = id
                    return NSItemProvider(object: id.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: FundReorderDropDelegate(
                    draggingId: $draggingId,
                    fundOrder: $fundOrder,
                    targetId: id
                ))
        }
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
        // label ("Past <fund>", muted — not a bold header).
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
                Text("Past \(FundSectionID.fund.displayName(customNames: appState.fundNames))")
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
        // payments + rule changes; nothing is fabricated to fill a
        // transactions slot. Build 69: the per-week overspend is
        // DERIVED from the closes (DebtLedger) and shown in the
        // ledger below — the old "week closes" list is gone.
        fundsSectionRow(
            title: "Activity & Transactions",
            section: .debtActivity,
            isAdminOnly: false,
            hPad: 0
        ) {
            VStack(alignment: .leading, spacing: 8) {
                DebtActivityView(
                    viewModel: viewModel,
                    fundName: FundSectionID.fund.displayName(customNames: appState.fundNames),
                    debtName: FundSectionID.debt.displayName(customNames: appState.fundNames)
                )
                Divider()
                // Build 69 (owner, Nov 24, 2026): the ledger
                // replaces "Where It Came From" — the old section
                // showed the debt balance at the end of each week,
                // cumulative balances that do not add up, so the
                // owner could not see where the debt came from.
                // The ledger shows what each week/event did to the
                // debt, with +/-, and the rows add up to the
                // current debt; every row is tappable.
                Text("How It Adds Up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                DebtLedgerView(
                    viewModel: viewModel,
                    fundName: FundSectionID.fund.displayName(customNames: appState.fundNames),
                    debtName: FundSectionID.debt.displayName(customNames: appState.fundNames)
                )
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
                // Build 68 (item 25b): the header is a proper
                // designed row, not a large outlined rectangle —
                // a soft #f8fafc fill with a hairline #e5e7eb
                // border, a brand-blue list icon and chevron, and
                // 14pt vertical padding, so it reads as part of
                // the card instead of a Word-document box.
                Button {
                    openMore = openMore == section ? nil : section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                        Text(TitleCase.apply(to: title))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .rotationEffect(.degrees(openMore == section ? 180 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: "#f8fafc"))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(DimOnPressButtonStyle())
                .accessibilityIdentifier(section.accessibilityID)
                if openMore == section {
                    // Build 55 (owner, Nov 22, 2026): clear space
                    // between the header button and the first row of
                    // the expanded content — the button and the top
                    // row read as touching with no gap. The 12pt top
                    // padding matches the 12pt bottom padding, so the
                    // content sits centred in the open space. This
                    // is the shared row, so every fund's Activity &
                    // Transactions section gets the same spacing.
                    content()
                        .padding(.horizontal, hPad)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

// MARK: - Remove from Savings sheet (build 42, owner Nov 17, 2026)
//
// The Savings card's single remove button opens this sheet: an
// amount field + a note + Record/Cancel, in the rename sheet's
// style (iPad 600pt centred, 17pt). It replaces the old Record
// Cash Spent sheet (deleted in build 42): that sheet's validation
// rejected any amount over Available, which would make the
// build-42 waterfall unreachable. This sheet validates only that
// the amount is above $0.00 — the waterfall spends Available
// first, then Pending top-ups, then carried debt — and the
// explainer line says so up front, with the live figures beside
// it. Validation lives here: empty / zero / negative shows a
// plain-language error INSIDE the sheet and the sheet stays open
// (the field keeps the typed input). On success the sheet closes,
// the field clears, and the balance updates everywhere. No
// transaction row is created: the spend is a fund_ledger
// 'allocation' (and, when it reaches debt, a debt adjustment),
// and both appear in the Savings / Debt Activity feeds.

public struct RemoveFromSavingsSheet: View {
    @ObservedObject public var viewModel: FundsViewModel
    public let fundName: String
    public var onClose: () -> Void
    @State private var amountText = ""
    @State private var noteText = ""
    @State private var removeError: String?
    /// The ⓘ beside the live figures opens the waterfall
    /// explanation (build 43, owner Nov 17, 2026 — long
    /// explanations live behind ⓘ, not inline).
    @State private var showWaterfallInfo = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: FundsViewModel, fundName: String, onClose: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.onClose = onClose
    }

    /// The live balances the waterfall splits on (client-side
    /// display only — the view model re-reads them server-side
    /// when it runs).
    private var availableCents: Int? { viewModel.fundSummary?.availableCents }
    private var pendingCents: Int { viewModel.savingsPendingCents }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: TitleCase.apply(to: "Remove from \(fundName)"), onClose: onClose)
            if let availableCents {
                // Build 43 (owner, Nov 17, 2026 — long explanations
                // behind ⓘ): the live figures stay visible; the
                // waterfall explanation lives behind the info icon.
                HStack(spacing: 8) {
                    FundsMuted("Available: \(MoneyFormat.formatCents(availableCents)) · Pending: \(MoneyFormat.formatCents(pendingCents)).")
                    Button {
                        showWaterfallInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How the amount is taken")
                }
            }
            DollarTextField(text: $amountText, maxWidth: .infinity, minHeight: 48)
            FundsTextField("Note", text: $noteText)
                .autocorrectionDisabled()
            if let removeError {
                FundsErrorBox(removeError)
            }
            // Build 70, item 5 (owner, Nov 24, 2026): the Cancel
            // button is gone — the SheetHeader X + swipe-right
            // dismiss without removing, so Cancel was a third
            // redundant way out.
            FundsPrimaryButton("Remove", isBusy: viewModel.busyAction == "remove-from-savings") {
                remove()
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
        // rename sheet.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 43 (owner, Nov 17, 2026): the waterfall explanation
        // behind the ⓘ above — how the amount is taken, in full.
        .alert(TitleCase.apply(to: "Remove from \(fundName)"), isPresented: $showWaterfallInfo) {
            Button("OK") {}
        } message: {
            Text("The amount comes off Available first, then Pending, then the rest adds to carried debt. No transaction row is created.")
        }
    }

    private func remove() {
        guard let cents = MoneyFormat.parseDollarsStrict(amountText), cents > 0 else {
            removeError = "Enter an amount above $0.00."
            return
        }
        removeError = nil
        Task {
            // Clear only on success — on failure the typed input
            // stays beside the error (F-P1-4).
            if await viewModel.removeFromSavings(amountCents: cents, note: noteText) {
                amountText = ""
                noteText = ""
                onClose()
            } else {
                // The view model's alert lives on the Funds page
                // BEHIND this sheet, so it would never surface —
                // show the failure inside the sheet instead (the
                // T-P2-1 lesson from the Actions sheet) and clear
                // it there so it cannot pop up later.
                removeError = viewModel.alertMessage ?? "Could not remove from \(fundName). Try again."
                viewModel.alertMessage = nil
                viewModel.alertTitle = nil
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
    /// interest are money in — deep blue with a "+" prefix under
    /// the shared kind rule; withdrawals and adjustments stay muted
    /// and plain. The recorded balance is a balance, never an inflow.
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
                // "Transferred In" is money in: deep blue with a "+"
                // prefix under the shared kind rule (build 64,
                // F-20 — the old green is retired). A zero sum
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
    /// The funds' CURRENT display names (build 43, owner Nov 17,
    /// 2026 — item 16): the payment / adjustment titles read
    /// them, never hardcoded "Extra Fund" / "Debt".
    public let fundName: String
    public let debtName: String

    public init(viewModel: FundsViewModel, fundName: String, debtName: String) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.debtName = debtName
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
            case "extra_fund": label = "Paid from \(fundName)"
            case "surplus": label = "Paid from Surplus"
            case "clear": label = "\(debtName) Cleared"
            default: label = "\(debtName) Payment"
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
        // Manual changes (build 41 — Add/Set debt): an Add shows
        // the amount added; a Set shows the total it was set to,
        // with the before → after in the detail.
        dated += viewModel.debtAdjustments.map { adj in
            let title: String
            if adj.kind == "set" {
                title = "\(debtName) Set to \(MoneyFormat.formatCents(adj.balanceAfterCents))"
            } else {
                title = "\(debtName) Added \(MoneyFormat.formatCents(adj.amountCents))"
            }
            let before = adj.balanceAfterCents - adj.amountCents
            let detail = "\(adj.createdAt.map { MoneyFormat.displayDay($0) } ?? "") · Week of \(MoneyFormat.fmtLong(adj.weekStart)) · \(MoneyFormat.formatCents(before)) → \(MoneyFormat.formatCents(adj.balanceAfterCents))\(adj.note.isEmpty ? "" : " · \(adj.note)")"
            return (Entry(
                id: "adjustment-\(adj.id.uuidString)",
                title: title,
                detail: detail
            ), adj.createdAt ?? "")
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
                // Build 68 (item 25b): the feed is a finished list
                // in a bordered card — a small blue icon, the title
                // in ink, the date/week/note below it in muted
                // grey, always visible — not bare plain-text rows
                // that expand on tap.
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(20).enumerated()), id: \.element.id) { index, entry in
                        debtEntryRow(entry)
                        if index < min(entries.count, 20) - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                if entries.count > 20 {
                    FundsMuted("Showing the latest 20 entries.")
                }
            }
        }
    }

    /// One payment / rule / adjustment row: icon + title + detail,
    /// the detail always visible.
    private func debtEntryRow(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entryIconName(entry))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.primary)
                .frame(width: 32, height: 32)
                .background(DesignTokens.softFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Text(entry.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func entryIconName(_ entry: Entry) -> String {
        if entry.id.hasPrefix("audit-") { return "slider.horizontal.3" }
        if entry.id.hasPrefix("adjustment-") { return "pencil" }
        return "checkmark.circle"
    }
}

// MARK: - Debt ledger (build 69, owner Nov 24, 2026)
//
// Replaces DebtHistoryView ("Where It Came From" — build 29/68):
// that showed the debt balance at the END of each closed week,
// cumulative balances that do NOT add up to the current total, so
// the owner could not see where the debt came from ("nothing
// tappable.. a bit unclear"). The ledger shows what each
// week/event DID to the debt, with +/-, so the rows add up exactly
// to the current debt (DebtLedger in OnBudgetKit — the derivation
// lives there, pinned by DebtLedgerTests against the live
// household's real figures). Every row is tappable: a week row
// opens that week's breakdown (spent, budget, refund, overspend /
// surplus); a payment/adjustment row opens the payment detail.

public struct DebtLedgerView: View {
    @ObservedObject public var viewModel: FundsViewModel
    /// The funds' CURRENT display names (build 43): the payment
    /// subtitles read them, never hardcoded names.
    public let fundName: String
    public let debtName: String
    @State private var selectedEntry: DebtLedgerEntry?

    public init(viewModel: FundsViewModel, fundName: String, debtName: String) {
        self.viewModel = viewModel
        self.fundName = fundName
        self.debtName = debtName
    }

    private var entries: [DebtLedgerEntry] {
        DebtLedger.build(
            closes: viewModel.debtHistory,
            payments: viewModel.debtPayments,
            adjustments: viewModel.debtAdjustments,
            debtName: debtName,
            extraFundName: fundName
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.debtError {
                FundsErrorBox(error)
            } else if entries.isEmpty {
                FundsMuted("No debt changes yet.")
            } else {
                // The ledger in the same bordered card as the
                // payments above — each row a whole-row tap target
                // (owner rule, Nov 11 2026) with a chevron, so it
                // reads as tappable; the total row closes it, so
                // the rows visibly add up to the current debt.
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        ledgerRow(entry)
                        Divider()
                    }
                    HStack(spacing: 6) {
                        Text("Total Now")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Spacer()
                        Text(MoneyFormat.formatCents(DebtLedger.totalCents(entries)))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
            }
        }
        .sheet(item: $selectedEntry) { entry in
            if entry.kind == .week {
                DebtLedgerWeekDetailSheet(entry: entry, transactions: viewModel.allTransactions, onClose: { selectedEntry = nil })
            } else {
                DebtLedgerPaymentDetailSheet(entry: entry, onClose: { selectedEntry = nil })
            }
        }
    }

    /// One ledger row: the title + what it did on the left, the
    /// signed amount + chevron on the right. + is debt added
    /// (overspent), - is debt paid down — the sign does the work,
    /// both in ink, so no colour has to be learned.
    private func ledgerRow(_ entry: DebtLedgerEntry) -> some View {
        Button {
            selectedEntry = entry
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    Text(entry.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                Spacer()
                Text(signedAmount(entry.amountCents))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title), \(entry.subtitle), \(signedAmount(entry.amountCents))")
    }

    private func signedAmount(_ cents: Int) -> String {
        cents >= 0 ? "+\(MoneyFormat.formatCents(cents))" : MoneyFormat.formatCents(cents)
    }
}

/// The week's breakdown behind a ledger week row: what was spent
/// (charges + fund charges, refunds), the weekly budget, and the
/// resulting overspend or surplus — the figures that make up the
/// row's +amount. The budget is derived so the detail always
/// reconciles to the ledger: overspend = net spending - budget,
/// so budget = net spending - overspend for an overspent week;
/// otherwise the close's stored allowance (base + temp increase)
/// is shown, and when even that is unknown the budget row is
/// omitted rather than guessed. (Only overspent weeks get a
/// ledger row, so the stored-allowance branch is a safety net,
/// not the common path.)
private struct DebtLedgerWeekDetailSheet: View {
    let entry: DebtLedgerEntry
    let transactions: [Transaction]
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var weekTransactions: [Transaction] {
        transactions.filter { tx in
            guard tx.state == .verified || tx.state == .provisional, !tx.excluded else { return false }
            guard let days = MoneyFormat.daysBetween(entry.weekStart, tx.date) else { return false }
            return days >= 0 && days < 7
        }
    }

    private var chargesCents: Int {
        weekTransactions
            .filter { $0.kind == .charge || $0.kind == .fundCharge }
            .reduce(0) { $0 + $1.amountCents }
    }

    private var refundsCents: Int {
        weekTransactions
            .filter { $0.kind == .refund }
            .reduce(0) { $0 + $1.amountCents }
    }

    private var netSpendingCents: Int { chargesCents + refundsCents }

    private var overspendCents: Int { entry.weekOverspendCents ?? 0 }

    private var budgetCents: Int? {
        if overspendCents > 0 {
            return netSpendingCents - overspendCents
        }
        if let close = entry.weekClose {
            // The stored allowance for the week (base + the
            // temporary increase, when one was in effect). The
            // late adjustment is NOT part of the allowance — it
            // is late-posting spending, not budget.
            let stored = (close.baseAllowanceCents ?? 0)
                + (close.tempIncreaseCents ?? 0)
            if stored > 0 { return stored }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: entry.title, onClose: onClose)
            VStack(spacing: 0) {
                FundsBreakdownRow("Spent", value: MoneyFormat.formatCents(chargesCents))
                    .padding(.vertical, 10)
                SheetActionDivider()
                FundsBreakdownRow("Refunds", value: MoneyFormat.formatCents(refundsCents))
                    .padding(.vertical, 10)
                SheetActionDivider()
                FundsBreakdownRow("Net Spending", value: MoneyFormat.formatCents(netSpendingCents))
                    .padding(.vertical, 10)
                if let budget = budgetCents {
                    SheetActionDivider()
                    FundsBreakdownRow("Weekly Budget", value: MoneyFormat.formatCents(budget))
                        .padding(.vertical, 10)
                    SheetActionDivider()
                    if overspendCents > 0 {
                        FundsBreakdownRow("Overspent", value: "+\(MoneyFormat.formatCents(overspendCents))")
                            .padding(.vertical, 10)
                    } else {
                        FundsBreakdownRow("Under Budget By", value: MoneyFormat.formatCents(budget - netSpendingCents))
                            .padding(.vertical, 10)
                    }
                } else if overspendCents > 0 {
                    SheetActionDivider()
                    FundsBreakdownRow("Overspent", value: "+\(MoneyFormat.formatCents(overspendCents))")
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 74 (owner, Nov 24, 2026 — popup sizing): a read-only detail sheet opens at its content size, not a 0.45 detent the 5-row card already fills.
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
    }
}

/// The payment / adjustment detail behind a ledger payment row:
/// the amount, what it was, when it happened and which week it
/// belongs to — the receipt for the row's -amount.
private struct DebtLedgerPaymentDetailSheet: View {
    let entry: DebtLedgerEntry
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: entry.title, onClose: onClose)
            VStack(spacing: 0) {
                FundsBreakdownRow("Amount", value: MoneyFormat.formatCents(entry.amountCents))
                    .padding(.vertical, 10)
                SheetActionDivider()
                FundsBreakdownRow("What", value: entry.subtitle)
                    .padding(.vertical, 10)
                SheetActionDivider()
                FundsBreakdownRow("Week", value: "Week of \(MoneyFormat.fmtLong(entry.weekStart))")
                    .padding(.vertical, 10)
                if let payment = entry.payment, !payment.note.isEmpty {
                    SheetActionDivider()
                    FundsBreakdownRow("Note", value: payment.note)
                        .padding(.vertical, 10)
                }
                if let adjustment = entry.adjustment {
                    SheetActionDivider()
                    FundsBreakdownRow("Balance After", value: MoneyFormat.formatCents(adjustment.balanceAfterCents))
                        .padding(.vertical, 10)
                    if !adjustment.note.isEmpty {
                        SheetActionDivider()
                        FundsBreakdownRow("Note", value: adjustment.note)
                            .padding(.vertical, 10)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 74 (owner, Nov 24, 2026 — popup sizing): a read-only detail sheet opens at its content size, not a 0.45 detent the 6-row card already fills.
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .presentationBackground(.white)
    }
}

/// Reorders the fund list as a card is dragged over it (owner, Nov
/// 16, 2026 — build 41: long-press enters reorder mode, drag moves).
/// A standard SwiftUI DropDelegate: hovering over another card moves
/// the dragged fund live to that spot, so the list follows the
/// finger like the iOS Home Screen. The order saves through the
/// existing fundOrder onChange → saveFundOrder.
private struct FundReorderDropDelegate: DropDelegate {
    @Binding var draggingId: FundSectionID?
    @Binding var fundOrder: [FundSectionID]
    let targetId: FundSectionID

    func dropEntered(info: DropInfo) {
        guard let draggingId, draggingId != targetId,
              let from = fundOrder.firstIndex(of: draggingId),
              let to = fundOrder.firstIndex(of: targetId) else { return }
        // The move arithmetic lives in the kit (FundOrderMove) so
        // the test suite pins the offset rule — see there for why
        // the target's index is the slot, with no +1 when moving
        // down.
        withAnimation(.easeInOut(duration: 0.2)) {
            fundOrder = FundOrderMove.moved(fundOrder, from: from, to: to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private extension View {
    /// Applies `transform` only when `condition` holds — used to
    /// attach the drag/drop modifiers in reorder mode only, so a
    /// normal scroll never starts a drag (build 41).
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Weekly Budget Calculator (build 43, owner Nov 17, 2026)
//
// From the V2 plan (Nov 15, 2026 — household-budget/
// V2_PLAN_DRAFT.md, "Weekly-budget formula"): expected monthly
// income, expected charity, and recurring charges feed a SUGGESTED
// weekly budget on the Funds page. The suggestion NEVER changes
// the weekly allowance — there is no button that applies or sets
// it; the user changes the allowance in the Spending card if they
// want to. Expected income and recurring charges are entered BY
// HAND here (name + amount + frequency), even before any
// transaction exists — the plan's manual-entry path. Everything
// is stored locally per household (UserDefaults, keyed by
// household id) — NO server migration, no Supabase changes — and
// entries save automatically as they change; there is no Save
// button. The formula explanation lives behind the ⓘ in the card
// header (build 43 — long explanations behind ⓘ).

/// How often a hand-entered calculator item repeats.
public enum CalculatorFrequency: String, Codable, CaseIterable {
    case weekly
    case monthly
    case quarterly
    case yearly

    public var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }

    /// Compact frequency suffix after an amount (build 68):
    /// $7,000/mo, $500/wk — replaces "· Monthly" and "a month".
    public var shortSuffix: String {
        switch self {
        case .weekly: return "/wk"
        case .monthly: return "/mo"
        case .quarterly: return "/qtr"
        case .yearly: return "/yr"
        }
    }

    /// How many of this frequency fit in one month. Weekly uses
    /// 4.33 — the plan's weeks-per-month, the same divisor as the
    /// formula below — so a weekly item and the weekly suggestion
    /// use one consistent month length.
    public var monthlyFactor: Double {
        switch self {
        case .weekly: return 4.33
        case .monthly: return 1
        case .quarterly: return 1.0 / 3.0
        case .yearly: return 1.0 / 12.0
        }
    }
}

/// One hand-entered expected item for the Weekly Budget
/// Calculator: a name, a dollar amount per occurrence, and how
/// often it repeats. Stored locally per household (UserDefaults,
/// JSON) — never on the server.
public struct CalculatorItem: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    /// The amount per occurrence, in cents.
    public var amountCents: Int
    public var frequency: CalculatorFrequency

    public init(id: UUID = UUID(), name: String, amountCents: Int, frequency: CalculatorFrequency) {
        self.id = id
        self.name = name
        self.amountCents = amountCents
        self.frequency = frequency
    }

    /// The item's monthly cost, in cents.
    public var monthlyCents: Int {
        Int((Double(amountCents) * frequency.monthlyFactor).rounded())
    }
}

/// The lifestyle holdback presets (V2 plan, owner Nov 15, 2026):
/// minimalist 10%, regular 5%, loose 0% are STANDARDS/defaults.
/// Build 68 (item 12): lifestyle + custom holdback are ONE
/// sliding bar with four stops — Min. / Reg. / Max. / Custom.
/// Min. is the tightest (Minimalist), Max. the loosest (Loose,
/// renamed by the owner), Custom takes its own % field. The
/// raw values stay, so a stored "loose" still loads as Max.
public enum LifestyleHoldback: String, Codable, CaseIterable {
    case minimalist
    case regular
    case loose
    case custom

    public var percent: Double {
        switch self {
        case .minimalist: return 10
        case .regular: return 5
        case .loose: return 0
        case .custom: return 0
        }
    }

    public var displayName: String {
        switch self {
        case .minimalist: return "Min."
        case .regular: return "Reg."
        case .loose: return "Max."
        case .custom: return "Custom"
        }
    }
}

/// The Weekly Budget Calculator as a full-screen popup (build
/// 44, owner Nov 18, 2026): opened by the "Calculate" button in
/// the expanded Spending card; the open section below the fund
/// cards is gone. Same content, same suggestion-only behaviour —
/// never setting the allowance (there is no apply button anywhere
/// in it). The content is a ScrollView, so it starts at the top
/// (the AddTransactionView forms' pattern); the X in the sheet
/// header dismisses it.
public struct WeeklyBudgetCalculatorSheet: View {
    public let householdId: UUID
    /// The charity fund's CURRENT display name (build 43, owner
    /// Nov 17, 2026 — item 16): the "Expected <fund>" section
    /// reads it, never a hardcoded "Charity".
    public let charityName: String
    /// The Funds view model (build 69 — the Calculator's "Add
    /// Recurring Expense" option and its shared income): the
    /// Calculator reads its expenses AND its income LIVE from it,
    /// so an expense or income added here shows at once, and tags
    /// through it. Non-optional: `@ObservedObject` cannot wrap an
    /// Optional (the build-69 item-4 form, `FundsViewModel?`,
    /// failed Archive — `ObservedObject` requires a type that
    /// conforms to `ObservableObject`, and an Optional does not),
    /// so both presenters guarantee a view model before presenting
    /// (HomeView unwraps `ensureFundsViewModel()` in its cover).
    @ObservedObject public var viewModel: FundsViewModel
    public var onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(householdId: UUID, charityName: String, viewModel: FundsViewModel, onClose: @escaping () -> Void = {}) {
        self.householdId = householdId
        self.charityName = charityName
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: TitleCase.apply(to: "Weekly Budget Calculator"), onClose: onClose)
                WeeklyBudgetCalculatorContent(householdId: householdId, charityName: charityName, viewModel: viewModel)
            }
            .padding()
        }
        .background(DesignTokens.background)
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // rename sheet and the Add to Charity popup.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 68 (item 9): fitted detents, not a full page —
        // the content is a ScrollView, so it works in a compact
        // popup on iPad.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

public struct WeeklyBudgetCalculatorContent: View {
    public let householdId: UUID
    /// The charity fund's CURRENT display name (build 43, owner
    /// Nov 17, 2026 — item 16): the "Expected <fund>" section
    /// reads it, never a hardcoded "Charity".
    public let charityName: String
    /// The Funds view model (build 69): the Calculator reads its
    /// expenses AND its income LIVE from it — so an expense or
    /// income added here shows at once — and the "Add Recurring
    /// Expense" option tags through it. Non-optional (see the
    /// Sheet above: `@ObservedObject` cannot wrap an Optional).
    @ObservedObject public var viewModel: FundsViewModel
    /// The expenses the Calculator reads: live from the view
    /// model. (Build 67's `expenses` snapshot parameter is gone —
    /// the view model is the single live source now.)
    private var liveExpenses: [RecurringExpense] {
        viewModel.liveExpenses
    }
    /// The tag picker + editor state (build 69): adding a
    /// recurring expense from the Calculator picks a charge to
    /// tag, then opens the editor for the new expense.
    @State private var showExpensePicker = false
    @State private var editorExpense: RecurringExpense?
    /// The blank expense being created from scratch (owner,
    /// Nov 26, 2026): the Calculator's manual "Create a New
    /// Expense" opens the same editor ExpensesListView uses.
    @State private var newExpense: RecurringExpense?
    /// The Add Income sheet (owner, Nov 25, 2026): the inline add
    /// form is gone — a single button opens it instead (see
    /// itemSection).
    @State private var showIncomeSheet = false
    /// The expense the Calculator's trash is about to remove
    /// (build 78, owner Nov 25, 2026): the delete confirm
    /// dialog binds to this. Nil until a trash is tapped.
    @State private var expenseToRemove: RecurringExpense?
    /// The expense tagged in the picker, waiting for the picker
    /// to finish dismissing (build 78): the editor opens from
    /// the picker's onDismiss, not from a sleep — presenting a
    /// sheet while another is still dismissing collides, so the
    /// editor waits until the picker is fully gone. A plain
    /// close (no tag) leaves this nil and opens nothing.
    @State private var pendingExpense: RecurringExpense?
    /// The income sources (build 69, owner Nov 24, 2026 —
    /// "Calculator should be per household"): the shared
    /// household store, owned by the view model — every member
    /// sees the same income and the same suggested budget on
    /// every device. The view model publishes it, so an add or
    /// remove on one device reads through to the others.
    private var incomeItems: [CalculatorItem] {
        viewModel.calculatorIncome
    }
    @State private var charityText = ""
    /// The Tzedaka Custom % field's text (owner, Nov 25, 2026):
    /// what the user typed while the % field is focused. When it
    /// is not focused the field shows the % the $ represents
    /// instead (see customCharityPercentBinding) — never stale.
    @State private var customCharityPercentText = ""
    /// True after tapping Custom until a preset is picked or the
    /// $ is typed to a preset value — keeps the % field visible
    /// when the $ happens to equal a preset (the derived
    /// selection alone would hide it).
    @State private var showingCustomCharityPercent = false
    @FocusState private var isCustomCharityPercentFocused: Bool
    @State private var lifestyle: LifestyleHoldback = .regular
    @State private var customHoldbackText = ""
    @State private var householdSize = 1
    @State private var incomeDraftName = ""
    @State private var incomeDraftAmount = ""
    @State private var incomeDraftFrequency: CalculatorFrequency = .monthly
    @State private var incomeError: String?
    /// The ⓘ in the card header opens the formula explanation.
    @State private var showFormulaInfo = false
    /// The ⓘ beside Recurring Expenses opens the tagged-expenses
    /// note (build 68, item 14): the line used to sit inline.
    @State private var showChargesInfo = false
    /// The ⓘ beside Lifestyle and Expected Income (owner,
    /// Nov 26, 2026): short alerts explaining each section.
    @State private var showLifestyleInfo = false
    @State private var showIncomeInfo = false
    /// True once the stored inputs have loaded — saves are
    /// suppressed until then, so loading never overwrites the
    /// stored values with the empty defaults.
    @State private var didLoad = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(householdId: UUID, charityName: String, viewModel: FundsViewModel) {
        self.householdId = householdId
        self.charityName = charityName
        self._viewModel = ObservedObject(wrappedValue: viewModel)
    }

    // MARK: - Local persistence (per household, no server)

    private func key(_ field: String) -> String {
        "hb-budget-calc-\(householdId.uuidString)-\(field)"
    }

    private func load() {
        guard !didLoad else { return }
        let defaults = UserDefaults.standard
        // Build 69 (owner, Nov 24, 2026 — "Calculator should be
        // per household"): income no longer loads from UserDefaults
        // — it is the shared household store, loaded by the view
        // model (`loadCalculatorIncome`, which also migrates any
        // old local entries once). Only the other inputs still
        // live per device (see the note in `save()`).
        charityText = defaults.string(forKey: key("charity")) ?? ""
        if let raw = defaults.string(forKey: key("lifestyle")),
           let saved = LifestyleHoldback(rawValue: raw) {
            lifestyle = saved
        }
        customHoldbackText = defaults.string(forKey: key("custom-holdback")) ?? ""
        let size = defaults.integer(forKey: key("household-size"))
        if size >= 1 { householdSize = size }
        didLoad = true
    }

    private func save() {
        guard didLoad else { return }
        let defaults = UserDefaults.standard
        // Build 69: income is NOT written here anymore — it lives
        // in the shared household store and each add/remove writes
        // through the view model at once. The other inputs (charity
        // %, lifestyle, holdback, household size) still save per
        // device — sharing them is a follow-up, not this build
        // (see supabase/calculator-income.sql).
        defaults.set(charityText, forKey: key("charity"))
        defaults.set(lifestyle.rawValue, forKey: key("lifestyle"))
        defaults.set(customHoldbackText, forKey: key("custom-holdback"))
        defaults.set(householdSize, forKey: key("household-size"))
    }

    // MARK: - Formula
    //
    // (monthly income − expected charity − recurring charges)
    // ÷ 4.33 weeks = weekly amount before lifestyle; the lifestyle
    // holdback is then kept back. Household-size scaling
    // (assumption, build 43 — the V2 plan says size scales "only
    // the variable week-to-week part" without giving the factor):
    // income and recurring charges are entered as HOUSEHOLD totals,
    // so the household weekly total does not multiply by size; size
    // scales the variable part in the per-person sense — the
    // per-person weekly figure is the suggested weekly amount
    // divided by the household size. If the owner wants size to
    // multiply a single-person baseline instead, that is a one-line
    // change to `suggestedWeeklyCents`.

    private var monthlyIncomeCents: Int {
        incomeItems.reduce(0) { $0 + $1.monthlyCents }
    }

    /// Build 67: the recurring costs come from the tagged
    /// Expenses list (single source of truth), not from
    /// hand-entered charges — the manual "Recurring Charges"
    /// section is gone, replaced by the expenses below.
    private var monthlyChargesCents: Int {
        liveExpenses.reduce(0) { $0 + $1.monthlyCents }
    }

    private var charityCents: Int {
        MoneyFormat.parseDollarsStrict(charityText) ?? 0
    }

    /// The holdback in effect (build 68, item 12): the picked
    /// stop's preset — except Custom, which reads its own %
    /// field and falls back to Regular 5% until a valid % is
    /// typed (the card says so under the field).
    private var holdbackPercent: Double {
        if lifestyle == .custom {
            if let bp = MoneyFormat.parseRatePercent(customHoldbackText) {
                return Double(bp) / 100.0
            }
            return LifestyleHoldback.regular.percent
        }
        return lifestyle.percent
    }

    private var monthlyRemainderCents: Int {
        monthlyIncomeCents - charityCents - monthlyChargesCents
    }

    private var weeklyBeforeHoldbackCents: Int {
        Int((Double(monthlyRemainderCents) / 4.33).rounded())
    }

    private var suggestedWeeklyCents: Int {
        Int((Double(weeklyBeforeHoldbackCents) * (1.0 - holdbackPercent / 100.0)).rounded())
    }

    private var perPersonCents: Int {
        householdSize > 0 ? suggestedWeeklyCents / householdSize : suggestedWeeklyCents
    }

    private var hasItems: Bool {
        !incomeItems.isEmpty || !liveExpenses.isEmpty
    }

    private var customHoldbackInvalid: Bool {
        !customHoldbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && MoneyFormat.parseRatePercent(customHoldbackText) == nil
    }

    // MARK: - Body
    //
    // Build 44 (owner, Nov 18, 2026): no FundsCard wrapper and no
    // header row any more — the sheet's SheetHeader supplies the
    // title and the X, and the ⓘ that explained the formula moved
    // to the suggestion block below. State, persistence, formula,
    // sections, and add/remove logic are unchanged from build 43.

    public var body: some View {
        // Build 78 (owner, Nov 25, 2026 — "the headers get
        // lost"): every Calculator section header is 17pt BOLD
        // ink (was 15pt semibold — the same size and weight as
        // the row labels, so the headers blended into the
        // content), and the sections have 20pt between them
        // (was 16) so each header stands apart from the previous
        // section's content. Row labels stay 15pt semibold.
        VStack(alignment: .leading, spacing: 20) {
            suggestionBlock
            Divider()
            // Build 77 (owner, Nov 25, 2026): Lifestyle +
            // Household Size sit at the TOP, above Expected
            // Income / Recurring Expenses — income and expenses
            // come later. Order only; values and behaviour
            // unchanged.
            lifestyleSection
            Divider()
            householdSizeSection
            Divider()
            incomeSection
            Divider()
            chargesSection
            Divider()
            charitySection
        }
        .accessibilityIdentifier("funds.weeklyBudgetCalculator")
        .onAppear {
            load()
            // Build 69: refresh the shared income on open (only
            // when stale — the view model throttles to 60s), so a
            // member always sees another member's latest entries.
            Task { await viewModel.ensureCalculatorIncomeLoaded() }
        }
        .onChange(of: charityText) { _, _ in save() }
        .onChange(of: lifestyle) { _, _ in save() }
        .onChange(of: customHoldbackText) { _, _ in save() }
        .onChange(of: householdSize) { _, _ in save() }
        .alert(TitleCase.apply(to: "Weekly Budget Calculator"), isPresented: $showFormulaInfo) {
            Button("OK") {}
        } message: {
            Text("Monthly income, minus expected charity, minus recurring charges, divided by 4.33 weeks — then the lifestyle holdback is kept back. Household size shows the suggestion per person. This only suggests a weekly budget — your weekly allowance does not change. Income is shared with your household; the other entries save on this device automatically.")
        }
    }

    /// The suggestion itself: the weekly figure, the per-person
    /// figure, the one-line basis, and the plain statement that
    /// the allowance does not change. Build 69 (owner, Nov 24,
    /// 2026 — the Calculator showed a Suggested Weekly Budget of
    /// -$35.10 with a red error when no income was entered):
    /// a non-positive suggestion is NEVER shown as a negative
    /// number — it reads $0.00 with a plain muted prompt to add
    /// income, not a negative figure with a red error. This
    /// reverses the V2 plan's "never silently clamped to $0"
    /// decision: the owner would rather see $0 and a prompt than
    /// a negative budget.
    private var suggestionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Suggested Weekly Budget")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Spacer()
                // Build 44 (owner, Nov 18, 2026): the ⓘ that
                // explained the formula lived in the old card
                // header — the sheet header holds the title now,
                // so it sits here, beside the suggestion it
                // explains. Same alert as before.
                Button {
                    showFormulaInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How the suggestion is worked out")
            }
            if hasItems {
                // Clamped at $0 — never a negative suggested
                // budget (build 69, owner Nov 24, 2026).
                Text(MoneyFormat.formatCents(max(0, suggestedWeeklyCents)))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                FundsMuted("About \(MoneyFormat.formatCents(max(0, perPersonCents))) per person each week, for a household of \(householdSize).")
                // Build 67 (owner, Nov 23, 2026 — "so many words,
                // so much clutter"): the two extra muted lines are
                // gone — the "suggestion only" line and the full
                // math breakdown. The ⓘ above already says both
                // (the formula + that the allowance does not
                // change), so repeating them here was clutter.
                if suggestedWeeklyCents <= 0 {
                    FundsMuted("That leaves nothing for the week — add your expected income below, or reduce the recurring expenses.")
                }
            } else {
                FundsMuted("Add your expected income below — the suggestion appears here once income and expenses are in.")
            }
        }
    }

    private var incomeSection: some View {
        itemSection(
            title: "Expected Income",
            items: incomeItems,
            draftTitle: "Add Income",
            draftName: $incomeDraftName,
            draftAmount: $incomeDraftAmount,
            draftFrequency: $incomeDraftFrequency,
            error: incomeError,
            monthlyTotalCents: monthlyIncomeCents,
            onAdd: addIncomeItem,
            onRemove: removeIncomeItem,
            infoMessage: "The monthly income the weekly budget is worked out from. Add each person's income here, and remove one with its trash.",
            showInfo: $showIncomeInfo
        )
    }

    /// Build 67 (owner, Nov 23, 2026): the "Recurring Charges"
    /// section is GONE as a hand-entered list — the recurring
    /// costs now come from the tagged Expenses list (single source
    /// of truth, derived from real transactions). This section
    /// only READS them: each expense with its frequency and
    /// monthly figure, and the monthly total that feeds the
    /// suggestion above. Nothing is typed here; expenses are
    /// tagged from a transaction's Actions sheet and managed
    /// from Recurring Expenses on the Weekly Budget sheet.
    /// Build 67 (owner, Nov 23, 2026): the manual "Recurring
    /// Charges" section is replaced by a read-only section
    /// driven by tagged expenses. Each row shows the expense
    /// name and the recurring amount with its frequency
    /// suffix ($160.00/mo).
    ///
    /// Build 69 (owner, Nov 24, 2026): an "Add Recurring
    /// Expense" option (admin only) — it opens a picker of
    /// taggable charges, tags the chosen one through the same
    /// tag_transaction_expense RPC the Actions sheet uses, and
    /// opens the editor for the new expense. The new expense is
    /// the SAME row the Recurring Expenses list and the
    /// Calculator read — never a second, disconnected store.
    private var chargesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Recurring Expenses")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                // Build 68 (item 14): the "From your tagged
                // expenses…" line lives behind this ⓘ now, not
                // inline under the rows.
                Button {
                    showChargesInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About recurring expenses")
            }
            if liveExpenses.isEmpty {
                FundsMuted("No expenses yet — create one below, or tag a transaction as an Expense.")
            } else {
                ForEach(liveExpenses) { expense in
                    HStack(spacing: 4) {
                        Text(expense.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                            .lineLimit(1)
                        Spacer()
                        Text("\(MoneyFormat.formatCents(expense.amountCents))\(expense.frequency.shortSuffix)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        // Build 78 (owner, Nov 25, 2026): delete
                        // from the Calculator — the red trash,
                        // mirroring the Expected Income rows'
                        // trash exactly (15pt semibold, #dc2626,
                        // padding 6, contentShape, plain style).
                        // Admin only (removal is admin-only
                        // server-side). Tapping asks first (the
                        // dialog below); the delete itself is the
                        // same removeExpense the editor's Remove
                        // uses, so a locked week's error surfaces
                        // through its guarded error path.
                        if viewModel.context.isAdmin {
                            Button {
                                expenseToRemove = expense
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color(hex: "#dc2626"))
                                    .padding(6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(expense.name)")
                        }
                    }
                }
            }
            // Owner, Nov 26, 2026: manually typing one in is the
            // MAIN way to add a recurring expense — so the manual
            // "Create a New Expense" is the solid-blue primary on
            // top here (the same blank editor ExpensesListView
            // opens), and "Add Recurring Expense" (tag a charge)
            // is the tertiary OUTLINE button below it. The two
            // never share a treatment (standing button rule).
            // Admin only — creating and tagging are admin-only
            // server-side.
            // Owner, Nov 26, 2026: a bit more air around the
            // buttons — the group carries 8pt extra vertical
            // padding, so the gaps above and below it are ~20pt
            // instead of the section's 12pt. The two buttons keep
            // the section's 12pt gap between them.
            if viewModel.context.isAdmin {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        newExpense = RecurringExpense(
                            id: UUID(),
                            householdId: householdId,
                            transactionId: nil,
                            name: "",
                            amountCents: 0,
                            frequency: .monthly
                        )
                    } label: {
                        Label("Create a New Expense", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityLabel("Create a new recurring expense")
                    Button {
                        showExpensePicker = true
                    } label: {
                        Label("Add Recurring Expense", systemImage: "plus.circle")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityLabel("Add recurring expense")
                }
                .padding(.vertical, 8)
            }
            calculatorTotalRow(value: MoneyFormat.formatCents(monthlyChargesCents))
        }
        .alert("Recurring Expenses", isPresented: $showChargesInfo) {
            Button("OK") {}
        } message: {
            // Build 78 (owner, Nov 25, 2026): removal is now
            // possible here too (the trash on each row), so the
            // old "Manage them from Recurring Expenses…" is
            // wrong.
            Text("From your tagged expenses. Remove one here with its trash, or manage them from Recurring Expenses on the Weekly Budget sheet.")
        }
        // Build 78 (owner, Nov 25, 2026): the delete confirm —
        // a destructive dialog (soft-red Remove Expense primary,
        // grey Keep It secondary — each button a different
        // colour), worded like the editor's Remove confirm.
        // The delete is the same removeExpense the editor uses;
        // a locked week's error surfaces through its guarded
        // error path, never swallowed.
        .appConfirmDialog(item: $expenseToRemove) { expense in
            AppConfirmDialog.Config(
                title: "Remove Expense",
                message: "Remove \(expense.name) (\(MoneyFormat.formatCents(expense.amountCents))\(expense.frequency.shortSuffix))? It counts as a purchase again.",
                primaryTitle: "Remove Expense",
                tone: .destructive,
                secondaryTitle: "Keep It",
                onPrimary: { Task { await viewModel.removeExpense(expense) } }
            )
        }
        .sheet(isPresented: $showExpensePicker, onDismiss: {
            // Build 78 (owner, Nov 25, 2026): the editor opens
            // from the picker's onDismiss — the picker is fully
            // gone by then, so there is no sheet-dismiss
            // collision and no 400ms sleep (see pendingExpense).
            if let pending = pendingExpense {
                pendingExpense = nil
                editorExpense = pending
            }
        }) {
            ExpenseTagPickerSheet(
                viewModel: viewModel,
                onTag: { transaction in
                    await viewModel.tagExpense(transaction, reason: "")
                },
                onTagged: { expense in
                    pendingExpense = expense
                },
                onClose: { showExpensePicker = false }
            )
        }
        .sheet(item: $editorExpense) { expense in
            ExpenseEditorSheet(
                expense: expense,
                onSave: { name, amountCents, frequency in
                    await viewModel.updateExpense(expense, name: name, amountCents: amountCents, frequency: frequency)
                },
                onRemove: {
                    await viewModel.removeExpense(expense)
                },
                onClose: { editorExpense = nil }
            )
        }
        // Owner, Nov 26, 2026: create an expense from scratch —
        // blank name, $0.00, monthly, NO Remove (nothing to remove
        // yet). Save creates it via the view model's createExpense
        // (the create_recurring_expense path) — the same blank
        // editor ExpensesListView opens.
        .sheet(item: $newExpense) { expense in
            ExpenseEditorSheet(
                expense: expense,
                onSave: { name, amountCents, frequency in
                    await viewModel.createExpense(name: name, amountCents: amountCents, frequency: frequency) != nil
                },
                onRemove: { false },
                onClose: { newExpense = nil },
                isNew: true
            )
        }
    }

    /// The Calculator's Monthly Total row (owner, Nov 25, 2026):
    /// a total, not a plain breakdown row — 17pt bold ink on both
    /// sides (the shared FundsBreakdownRow is 15pt with a grey
    /// label) with 8pt extra vertical padding, so it stands apart
    /// from the rows above it. The shared component is untouched.
    private func calculatorTotalRow(value: String) -> some View {
        HStack {
            Text("Monthly Total")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Spacer()
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
        }
        .padding(.vertical, 8)
    }

    /// One hand-entered list (income or charges): the saved rows
    /// with their monthly figure, the add button, and the monthly
    /// total. Rows are minimal — name + frequency + monthly
    /// amount — like the activity rows.
    ///
    /// Owner, Nov 25, 2026: the add form is NOT inline any more —
    /// the full form (name + amount + frequency + Add) sat on the
    /// page at all times and read cluttered. It is a single blue
    /// button now, matching Add Recurring Expense, and the same
    /// form opens in a sheet. `draftTitle` titles that sheet.
    private func itemSection(
        title: String,
        items: [CalculatorItem],
        draftTitle: String,
        draftName: Binding<String>,
        draftAmount: Binding<String>,
        draftFrequency: Binding<CalculatorFrequency>,
        error: String?,
        monthlyTotalCents: Int,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (CalculatorItem) -> Void,
        infoMessage: String? = nil,
        showInfo: Binding<Bool> = .constant(false)
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(TitleCase.apply(to: title))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                // Owner, Nov 26, 2026: the ⓘ beside the header —
                // same treatment as Recurring Expenses' ⓘ. Only
                // when the caller passes an info message.
                if infoMessage != nil {
                    Button {
                        showInfo.wrappedValue = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About \(title.lowercased())")
                }
            }
            if items.isEmpty {
                FundsMuted("Nothing added yet.")
            } else {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                            .lineLimit(1)
                        Spacer()
                        Text("\(MoneyFormat.formatCents(item.amountCents))\(item.frequency.shortSuffix)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Button {
                            onRemove(item)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(hex: "#dc2626"))
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                }
            }
            // Owner, Nov 25, 2026: one blue full-width button, the
            // same treatment as Add Recurring Expense — the inline
            // form is gone; tapping opens it in a sheet.
            Button {
                showIncomeSheet = true
            } label: {
                Label("Add Income", systemImage: "plus.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Add income")
            calculatorTotalRow(value: MoneyFormat.formatCents(monthlyTotalCents))
        }
        .alert(TitleCase.apply(to: title), isPresented: showInfo) {
            Button("OK") {}
        } message: {
            if let infoMessage {
                Text(infoMessage)
            }
        }
        .sheet(isPresented: $showIncomeSheet) {
            // The same add form as before — Name, $ amount,
            // frequency, Add — only the presentation changed
            // (inline → sheet). Validation errors show here,
            // where the form is; a successful add closes the
            // sheet (see addIncomeItem).
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: TitleCase.apply(to: draftTitle), onClose: { showIncomeSheet = false })
                FundsTextField("Name", text: draftName)
                    .autocorrectionDisabled()
                HStack(spacing: 8) {
                    DollarTextField(text: draftAmount, placeholder: "0.00", maxWidth: .infinity, minHeight: 48)
                    Picker("How Often", selection: draftFrequency) {
                        ForEach(CalculatorFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    .pickerStyle(.menu)
                    FundsSmallPrimaryButton("Add") { onAdd() }
                }
                if let error {
                    FundsErrorBox(error)
                }
                Spacer()
            }
            .padding()
            .frame(width: horizontalSizeClass == .regular ? 600 : nil)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.white)
        }
    }

    /// The Tzedaka % presets (owner, Nov 25, 2026): the % row
    /// above the $ field — 5% / 10% / 20% / Custom, the same
    /// SquarishPicker treatment as Lifestyle.
    private enum CharityPercentPreset: String, CaseIterable {
        case five, ten, twenty, custom

        var displayName: String {
            switch self {
            case .five: return "5%"
            case .ten: return "10%"
            case .twenty: return "20%"
            case .custom: return "Custom"
            }
        }

        /// The preset's percent, nil for Custom.
        var percent: Double? {
            switch self {
            case .five: return 5
            case .ten: return 10
            case .twenty: return 20
            case .custom: return nil
            }
        }
    }

    /// The $ amount, in cents, for a % of monthly income — the
    /// same math the old "Set to 10% of Income" button used
    /// (monthlyIncomeCents * pct / 100, rounded to the cent).
    private func charityCents(forPercent pct: Double) -> Int {
        Int((Double(monthlyIncomeCents) * pct / 100.0).rounded())
    }

    /// The $ field text for a % of monthly income.
    private func charityAmountText(forPercent pct: Double) -> String {
        String(format: "%.2f", Double(charityCents(forPercent: pct)) / 100.0)
    }

    /// The % the $ field's amount represents of monthly income,
    /// one decimal place (owner, Nov 26, 2026 — typing a $ shows
    /// the % it corresponds to; e.g. $800 of $7,800 is 10.3%).
    /// Empty when there is no income or no $ to reflect.
    private func derivedCharityPercentText() -> String {
        guard monthlyIncomeCents > 0,
              let cents = MoneyFormat.parseDollarsStrict(charityText),
              cents > 0 else { return "" }
        return String(format: "%.1f", Double(cents) / Double(monthlyIncomeCents) * 100.0)
    }

    /// The % row's highlight, DERIVED from the $ field (owner,
    /// Nov 26, 2026): when the $ equals exactly 5%, 10% or 20%
    /// of monthly income (integer-cents compare) that preset is
    /// highlighted, not Custom; anything else is Custom. Never
    /// stored, so it can never go stale when the income changes.
    private var charityPercentSelection: CharityPercentPreset {
        guard monthlyIncomeCents > 0,
              let cents = MoneyFormat.parseDollarsStrict(charityText) else { return .custom }
        if cents == charityCents(forPercent: 5) { return .five }
        if cents == charityCents(forPercent: 10) { return .ten }
        if cents == charityCents(forPercent: 20) { return .twenty }
        return .custom
    }

    /// The picker's binding: tapping a preset fills the $ and
    /// hides the Custom field; tapping Custom reveals the field
    /// showing the % the current $ represents.
    private var charityPercentBinding: Binding<CharityPercentPreset> {
        Binding(
            get: { self.charityPercentSelection },
            set: { preset in
                if let pct = preset.percent {
                    self.showingCustomCharityPercent = false
                    self.charityText = self.charityAmountText(forPercent: pct)
                } else {
                    self.customCharityPercentText = self.derivedCharityPercentText()
                    self.showingCustomCharityPercent = true
                }
            }
        )
    }

    /// The Custom % field's text: while the user types, the text
    /// is theirs; otherwise it is the % the $ represents (see
    /// derivedCharityPercentText), so typing a $ always shows the
    /// % it corresponds to. Typing a % fills the $ from it.
    private var customCharityPercentBinding: Binding<String> {
        Binding(
            get: {
                self.isCustomCharityPercentFocused
                    ? self.customCharityPercentText
                    : self.derivedCharityPercentText()
            },
            set: { newValue in
                self.customCharityPercentText = newValue
                if let pct = Double(newValue), pct >= 0, pct <= 100 {
                    self.charityText = self.charityAmountText(forPercent: pct)
                }
            }
        )
    }

    private var charitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Expected \(charityName)")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            // Owner, Nov 25, 2026: the % row ABOVE the $ field —
            // 5% / 10% / 20% / Custom, the same SquarishPicker
            // treatment as Lifestyle. It replaces the "Set to 10%
            // of Income" button (build 78). Picking a % fills the
            // $ from it; typing a $ highlights the % it is — or
            // Custom, with the % shown in the field below.
            SquarishPicker(
                CharityPercentPreset.allCases.map { ($0, $0.displayName) },
                selection: charityPercentBinding
            )
            DollarTextField(text: $charityText, placeholder: "0.00", maxWidth: .infinity, minHeight: 48)
            // The Custom % field (owner, Nov 25, 2026 — the same
            // "%" prefix + decimal-pad field Lifestyle's Custom
            // reveals): visible when Custom is the row's choice,
            // when the user tapped Custom, or while it is focused
            // (so typing exactly "10" does not hide it under the
            // user mid-typing). The text is the % the $ represents
            // unless the user is typing (see the binding).
            if showingCustomCharityPercent || charityPercentSelection == .custom || isCustomCharityPercentFocused {
                HStack(spacing: 2) {
                    Text("%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField("", text: customCharityPercentBinding)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17))
                        .focused($isCustomCharityPercentFocused)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            // Build 67 (owner, Nov 23, 2026 — "so many words"):
            // the "Expected charity each month…" explainer is
            // gone — the field + the row already say it.
        }
        .onChange(of: charityText) { _, _ in
            // The $ was typed to a preset value (or a preset was
            // tapped): the Custom field's reason to stay open is
            // gone — unless the user is typing in it.
            if !isCustomCharityPercentFocused && charityPercentSelection != .custom {
                showingCustomCharityPercent = false
            }
        }
        .onChange(of: isCustomCharityPercentFocused) { _, focused in
            // Entering the % field: start from the % the current
            // $ represents, so the user edits that, not stale text.
            if focused { customCharityPercentText = derivedCharityPercentText() }
        }
    }

    private var lifestyleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Lifestyle")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                // Owner, Nov 26, 2026: the ⓘ beside the header —
                // same treatment as Recurring Expenses' ⓘ.
                Button {
                    showLifestyleInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About lifestyle")
            }
            // Build 68 (item 12): ONE sliding bar for lifestyle +
            // custom holdback — Min. / Reg. / Max. / Custom — the
            // same squarish pattern as the debt rule. Min. is the
            // tightest (Minimalist 10%), Max. the loosest (Loose
            // 0%, renamed by the owner). Custom shows its own %
            // field below; the other stops need no field.
            SquarishPicker(
                LifestyleHoldback.allCases.map { ($0, $0.displayName) },
                selection: $lifestyle
            )
            if lifestyle == .custom {
                HStack(spacing: 2) {
                    Text("%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    TextField("", text: $customHoldbackText)
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
            }
            // Build 67 (owner, Nov 23, 2026 — "so many words"):
            // the "Holdback in effect…" line is gone — the preset
            // + the field already show the holdback in effect.
            if lifestyle == .custom, customHoldbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FundsMuted("Enter your holdback percent — using Regular 5% until then.")
            }
            if customHoldbackInvalid {
                FundsMuted("That holdback did not parse — using Regular 5% instead. Enter a percent between 0 and 100.")
            }
        }
        .alert("Lifestyle", isPresented: $showLifestyleInfo) {
            Button("OK") {}
        } message: {
            Text("How much of your income is held back before working out the weekly budget. Min. holds back 10%, Regular 5%, Max. holds back nothing, and Custom is your own percent.")
        }
    }

    private var householdSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper("Household Size: \(householdSize)", value: $householdSize, in: 1...20)
                .font(.system(size: 17, weight: .bold))
            // Build 67 (owner, Nov 23, 2026 — "so many words"):
            // the "Shown per person…" line is gone — the
            // per-person figure sits right above in the suggestion.
        }
    }

    // MARK: - Add / remove

    /// Validates one add-row (name + amount). Returns the item, or
    /// sets `error` to a plain-language reason and returns nil —
    /// the typed input stays so the user can fix it (the Add
    /// button is never greyed out; a bad tap explains itself).
    private func validatedDraftItem(
        name: String,
        amountText: String,
        frequency: CalculatorFrequency,
        error: inout String?
    ) -> CalculatorItem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Enter a name for this item."
            return nil
        }
        guard let cents = MoneyFormat.parseDollarsStrict(amountText), cents > 0 else {
            error = "Enter an amount above $0.00."
            return nil
        }
        error = nil
        return CalculatorItem(name: trimmed, amountCents: cents, frequency: frequency)
    }

    private func addIncomeItem() {
        guard let item = validatedDraftItem(
            name: incomeDraftName,
            amountText: incomeDraftAmount,
            frequency: incomeDraftFrequency,
            error: &incomeError
        ) else { return }
        // Build 69 (owner, Nov 24, 2026 — "Calculator should be
        // per household"): the add writes to the shared household
        // store through the view model (any member may add), so
        // every device reads the same income at once. The draft
        // fields clear only on success — a failed write keeps the
        // typed input so the user can retry.
        Task {
            if await viewModel.addCalculatorIncome(name: item.name, amountCents: item.amountCents, frequency: item.frequency) != nil {
                incomeDraftName = ""
                incomeDraftAmount = ""
                // Owner, Nov 25, 2026: the add form lives in a
                // sheet now — a successful add closes it. A failed
                // write keeps the sheet open with the typed input
                // and the error, so the user can retry.
                showIncomeSheet = false
            }
        }
    }

    private func removeIncomeItem(_ item: CalculatorItem) {
        // Build 69: the remove deletes from the shared household
        // store through the view model (any member may remove).
        Task { await viewModel.removeCalculatorIncome(item) }
    }
}
