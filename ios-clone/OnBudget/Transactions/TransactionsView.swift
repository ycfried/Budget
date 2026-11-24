import SwiftUI
import OnBudgetKit

/// Transactions screen (CLONE_SPEC §7).
///
/// - Heading "Transactions". Header actions (right, in order):
///   "+ Add" (primary, solid blue) → the Add popup · "Filters"
///   (grey fill) → the filter sheet · "⋯" (grey outline) → a
///   menu holding the secondary actions: Sync Now, Review,
///   Weeks, Export (plus Activity / Trash / Merchants, which
///   used to live behind the old "More" menu). Three distinct
///   treatments, so no two share a colour or look very similar
///   (owner button rule, strengthened Nov 23, 2026). Build 65,
///   item 12: the old page-links row (Review / Weeks / Export /
///   More pills + the circular sync icon) is gone — its actions
///   live only in the ⋯ menu now.
/// - Search box (owner, Nov 12, 2026): standard iOS search look —
///   system-grey filled field, magnifier inside on the left, short
///   "Search transactions" placeholder, no explainer underneath.
///   LIVE: typing filters as you go (250ms debounce) — there is
///   no Search button any more (build 65, item 12). Searches
///   loaded transactions only (merchant / date / amount).
///   Filters apply client-side to the rows already loaded, so a
///   search or filter change needs no refetch.
/// - Active-filter chips: one removable chip per applied filter.
/// - Count line: "`N` transactions · Total `$X`" — one quiet
///   muted line, CENTERED (owner, Nov 16, 2026 — build 40: the
///   older-rows tail is gone and the line is centered).
/// - List: pages of 25 (owner, Nov 15, 2026 — the list loaded
///   everything at once and felt slow). Fetch asks for `pageSize +
///   1`; the probe row decides whether Load More shows — a page of
///   exactly 25 with no probe row does NOT show the button. Load
///   More appends the next 25 (offset) and never refetches what is
///   already loaded; the existing rows stay visible while it
///   appends. Filters, search, and sort apply client-side to
///   everything loaded so far.
/// - Pull-to-refresh + the ⋯ menu's Sync Now: the same manual
///   sync (`viewModel.runSync`, Plaid bank + Gmail email halves),
///   throttled to one sync at a time (`isSyncing`). Build 69
///   (owner, Nov 24, 2026 — auto-sync on open): the page also
///   syncs itself on appear (`autoSyncIfNeeded`, once per 5
///   minutes, quiet) so family members see the latest
///   transactions without tapping Sync.
/// - Empty / loading / error states per §2.4 — a real error state,
///   never an endless spinner. Auth failure: "Your sign-in expired —
///   sign in again to see transactions." + "Sign In Again" (calls
///   `onSignInAgain`, which the shell wires to sign-out + sign-in
///   panel). Server failure: "Could not load transactions — the
///   server did not answer. Nothing here is a complete list." +
///   "Try Again".
public struct TransactionsView: View {
    @Bindable var viewModel: TransactionsViewModel
    /// The app shell, for the handoffs it owns: `pendingWeekFilter`
    /// (Past Weeks / Weekly sheet) and `pendingTransactionJump`
    /// (Home recent-row tap). Consumed on appear and on change.
    @ObservedObject var appState: AppViewModel
    /// The shell-owned Review view model (build 30): the Review
    /// button's count badge reads `reviewCount` live from it, and
    /// the Review page shares the same instance.
    @ObservedObject var reviewViewModel: FundsViewModel

    /// Wired by the app shell: both handlers push the matching
    /// subpage onto the Transactions NavigationStack. The links are
    /// hidden until a handler is supplied, so they never lead nowhere.
    var onShowPastWeeks: (() -> Void)?
    var onShowActivity: (() -> Void)?
    var onShowReview: (() -> Void)?
    var onShowMerchantNames: (() -> Void)?

    @State private var searchText: String = ""
    /// The search field's keyboard focus (build 41, owner Nov 17,
    /// 2026): the keyboard's Return key dismisses it. Search is
    /// live-as-you-type — there is no Search button any more
    /// (build 65, item 12).
    @FocusState private var searchFocused: Bool
    @State private var showingFilters: Bool = false
    @State private var showingAdd: Bool = false
    @State private var showingTrash: Bool = false
    /// Build 45: the export popup (full-screen cover, like the
    /// other popups on this page).
    @State private var showingExport: Bool = false
    @State private var actionsTransaction: Transaction?
    /// iPad content width (build 36): the tab reads as a centered
    /// 900pt column on the regular size class.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        viewModel: TransactionsViewModel,
        appState: AppViewModel,
        reviewViewModel: FundsViewModel,
        onShowPastWeeks: (() -> Void)? = nil,
        onShowActivity: (() -> Void)? = nil,
        onShowReview: (() -> Void)? = nil,
        onShowMerchantNames: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.appState = appState
        self.reviewViewModel = reviewViewModel
        self.onShowPastWeeks = onShowPastWeeks
        self.onShowActivity = onShowActivity
        self.onShowReview = onShowReview
        self.onShowMerchantNames = onShowMerchantNames
        // Build 64 (C-5): the view model's confirmations go
        // through the app-shell toast (`AppViewModel.showToast`),
        // so they render ABOVE a presented sheet instead of
        // underneath it. The weak capture is safe: the app state
        // outlives the view model.
        viewModel.appToast = { [weak appState] message, kind in
            appState?.showToast(message, kind: kind)
        }
    }

    public var body: some View {
        scrollContent
            .task { await boot() }
            // Build 69 (owner, Nov 24, 2026 — auto-sync on open):
            // the page syncs itself when it appears (Plaid +
            // Gmail, all roles), so family members see the latest
            // transactions without tapping Sync. Throttled to once
            // per 5 minutes inside `autoSyncIfNeeded` (a manual
            // sync counts too) and quiet — the list just updates.
            // `.onAppear` (not `boot`'s `.task`) so it also fires
            // on a tab switch back, not only the first open.
            .onAppear {
                Task { await viewModel.autoSyncIfNeeded() }
            }
            .onChange(of: appState.pendingWeekFilter) { _, _ in consumeHandoffs() }
            .onChange(of: appState.pendingTzedakaFilter) { _, _ in consumeHandoffs() }
            .onChange(of: appState.fundNames) { _, names in viewModel.fundNames = names }
            .onChange(of: appState.pendingTransactionJump) { _, _ in consumeHandoffs() }
            .onChange(of: appState.pendingClearTransactionFilters) { _, _ in consumeHandoffs() }
            // NOTE (T-P2-1): no `.alert` here — the failure alert lives
            // on the Actions and Trash sheets themselves, because an
            // alert attached to this parent never surfaces above a
            // presented sheet. Every `showAlert` call site originates
            // from one of those sheets.
            .onChange(of: searchText) { _, new in
                viewModel.applySearch(new)
            }
            // T-P1-1: the box is local state, so a filter clear from the
            // view model (empty-state button, Past Weeks / Home-row jump)
            // must clear it too — otherwise the box shows a search the
            // list no longer applies.
            .onChange(of: viewModel.searchResetNonce) { _, _ in
                searchText = ""
            }
            .modifier(TransactionCovers(
                viewModel: viewModel,
                appState: appState,
                showingFilters: $showingFilters,
                showingAdd: $showingAdd,
                showingTrash: $showingTrash,
                showingExport: $showingExport,
                actionsTransaction: $actionsTransaction,
                taggedExpense: $viewModel.taggedExpense
            ))
    }

    /// The scrollable list (build 64): extracted from `body` so the
    /// compiler can type-check `body` in reasonable time — the single
    /// chained expression (ScrollView + task + onChanges + five
    /// covers) hit the Swift 6 type-check timeout.
    private var scrollContent: some View {
        // Build 64 (F-8): the toast is the shared TOP popup
        // (.toastOverlay, SharedViews) — the centered ZStack
        // popup (build 38) was "horrendous" (owner, Nov 20,
        // 2026 — build 50) and covered the list mid-screen.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                searchBox
                activeChips
                countLine
                listContent
                loadMoreButton
            }
            .padding()
        }
        .refreshable {
            await viewModel.load()
        }
        .toastOverlay(Binding(
            get: { viewModel.toastManager.toast },
            set: { viewModel.toastManager.toast = $0 }
        ))
        // Build 36 (owner, Nov 16, 2026 — iPad): the tab reads as a
        // centered 900pt column on the regular size class (see
        // mainContentWidth), never stretched edge-to-edge.
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
    }

    /// The on-appear work (build 64): extracted from `body`'s `.task`
    /// for the same type-check reason as `scrollContent`.
    private func boot() async {
        // Build 43 (owner, Nov 17, 2026 — item 16): the view
        // model composes alerts/toasts with the funds' CURRENT
        // display names, so it reads the same `appState.fundNames`
        // source as the views — synced here and on every rename
        // below.
        viewModel.fundNames = appState.fundNames
        // Build 52: when a week filter is pending (Spending
        // card / Weekly sheet), skip the page-1 load — the
        // week handoff below fetches the whole history
        // instead. Loading page 1 first would flash the
        // paged list, then replace it with the week list.
        if case .idle = viewModel.loadState, appState.pendingWeekFilter == nil {
            await viewModel.load()
        }
        // Build 30: the Review badge count loads with the tab.
        // The Review page refreshes the same instance on open,
        // and every review action reloads it, so the badge
        // stays live without a second load here.
        await reviewViewModel.refreshReview()
        consumeHandoffs()
    }

    /// The five presented covers/sheets (build 64): extracted from
    /// `body` into a ViewModifier so the compiler can type-check
    /// `body` in reasonable time.
    private struct TransactionCovers: ViewModifier {
        var viewModel: TransactionsViewModel
        @ObservedObject var appState: AppViewModel
        @Binding var showingFilters: Bool
        @Binding var showingAdd: Bool
        @Binding var showingTrash: Bool
        @Binding var showingExport: Bool
        @Binding var actionsTransaction: Transaction?
        /// Build 67: the expense just tagged from the Actions sheet
        /// — passed as a binding (like `actionsTransaction`) because
        /// this modifier holds the view model as a plain property,
        /// so `$viewModel.taggedExpense` does not exist here.
        @Binding var taggedExpense: RecurringExpense?

        func body(content: Content) -> some View {
            content
                // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
                // cover, not a detent sheet — popups are always full size.
                // The Filters content is a ScrollView in a NavigationStack,
                // so it fills the full screen and starts at the top;
                // Apply / Cancel at the bottom dismiss it. Width stays
                // 600pt (regular) via the frame inside the sheet content.
                .fullScreenCover(isPresented: $showingFilters) {
                    TransactionsFilterSheet(viewModel: viewModel, fundNames: appState.fundNames, onDismiss: { showingFilters = false })
                        // Build 64 (C-5, follow-up): the shell-root popup
                        // sits UNDERNEATH a fullScreenCover, so a
                        // confirmation fired while this cover is open
                        // needs the overlay inside the cover's content.
                        // The Filters sheet fires no toast of its own;
                        // the binding is the app-shell toast state, so
                        // any confirmation fired while it is open shows.
                        .confirmationPopupOverlay($appState.toast)
                }
                // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
                // cover, not a detent sheet. AddTransactionView sets no
                // sizing itself any more — the cover is full-screen on
                // both steps; the forms are ScrollViews, so they start at
                // the top, and the options step top-anchors with its own
                // trailing Spacer (build 43, item 18).
                .fullScreenCover(isPresented: $showingAdd) {
                    AddTransactionView(viewModel: viewModel, onDismiss: { showingAdd = false })
                        // Build 64 (C-5, follow-up): overlay inside the
                        // cover — the Add save confirmation fires through
                        // the view model into the app-shell toast
                        // (`AppViewModel.showToast`), which the shell-root
                        // popup cannot show from underneath this cover.
                        .confirmationPopupOverlay($appState.toast)
                }
                // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
                // cover, not a detent sheet. The Trash content is a
                // ScrollView in a NavigationStack, so it fills the full
                // screen and starts at the top; Back dismisses it.
                .fullScreenCover(isPresented: $showingTrash) {
                    TrashView(viewModel: viewModel, onBack: { showingTrash = false })
                        // Build 64 (C-5, follow-up): overlay inside the
                        // cover — the restore confirmations fire through
                        // the view model into the app-shell toast, which
                        // the shell-root popup cannot show from
                        // underneath this cover.
                        .confirmationPopupOverlay($appState.toast)
                }
                // Build 45 (Nov 18, 2026): full-screen cover, not a detent
                // sheet — popups are always full size. The export popup
                // fetches the whole history on open and opens the system
                // share sheet on top of itself after generating.
                .fullScreenCover(isPresented: $showingExport) {
                    TransactionExportView(
                        viewModel: viewModel,
                        appState: appState,
                        householdName: appState.householdName,
                        onDismiss: { showingExport = false }
                    )
                    // Build 64 (C-5, follow-up): overlay inside the
                    // cover — the export's "List now shows…" and
                    // no-match toasts fire via `AppViewModel.showToast`,
                    // which the shell-root popup cannot show from
                    // underneath this cover.
                    .confirmationPopupOverlay($appState.toast)
                }
                // Build 64 (C-4, owner Nov 23, 2026): fitted detents,
                // NOT a full-screen cover — this reverses the Nov 17
                // full-screen rule (build 43, item 17). The sheet sizes
                // itself: .medium for the Actions list, small for the
                // confirm flows (the detents live in the sheet itself,
                // which knows its flow). iPad width stays 600pt
                // (regular) via the frame inside the sheet content, so
                // the sheet is a centred card on iPad, never full-width.
                .sheet(item: $actionsTransaction) { transaction in
                    TransactionActionsSheet(
                        transaction: transaction,
                        isAdmin: viewModel.isAdmin,
                        viewModel: viewModel,
                        fundNames: appState.fundNames,
                        onDismiss: { actionsTransaction = nil }
                    )
                    // Build 64 (C-5, follow-up): overlay inside the
                    // sheet — a sheet presents above the shell root too,
                    // so the action confirmations (which fire through
                    // the view model into the app-shell toast) need the
                    // popup attached here to be seen.
                    .confirmationPopupOverlay($appState.toast)
                }
                // Build 67 (owner, Nov 23, 2026): the expense editor,
                // opened right after tagging from the Actions sheet —
                // the tag sets `viewModel.taggedExpense` once the
                // Actions sheet has dismissed, and this sheet opens
                // for it. Save / Remove go through the Transactions
                // view model; the list reloads behind the editor, so
                // the week figures drop the expense at once.
                .sheet(item: $taggedExpense) { expense in
                    ExpenseEditorSheet(
                        expense: expense,
                        onSave: { name, amountCents, frequency in
                            await viewModel.updateExpense(expense, name: name, amountCents: amountCents, frequency: frequency)
                        },
                        onRemove: {
                            await viewModel.removeExpense(expense)
                        },
                        onClose: { taggedExpense = nil }
                    )
                    .confirmationPopupOverlay($appState.toast)
                }
        }
    }

    // MARK: - Handoffs from the app shell

    /// Past Weeks / Weekly sheet (`pendingWeekFilter`) and Home
    /// recent-row tap (`pendingTransactionJump`): apply to the list,
    /// then clear the flag so a later tab switch does not re-apply.
    /// Home "See All" (`pendingClearTransactionFilters`) clears
    /// search/filters first, same as the jump (audit H-P2-8).
    /// Home Tzedaka sheet (`pendingTzedakaFilter`, build 65):
    /// pre-filter to the Tzedaka rows (gifts + income that accrued).
    private func consumeHandoffs() {
        if let week = appState.pendingWeekFilter {
            appState.pendingWeekFilter = nil
            // Build 52: the week filter fetches the whole history,
            // so it is async — the list fills in when it lands.
            Task { await viewModel.applyWeekFilter(weekStart: week) }
        }
        if appState.pendingTzedakaFilter {
            appState.pendingTzedakaFilter = false
            Task { await viewModel.applyTzedakaFilter() }
        }
        if let jump = appState.pendingTransactionJump {
            appState.pendingTransactionJump = nil
            viewModel.applyTransactionJump(jump)
        }
        if appState.pendingClearTransactionFilters {
            appState.pendingClearTransactionFilters = false
            viewModel.clearSearchAndFilters()
            // The search box is local state: clear it too, or it
            // would keep showing text the list no longer filters by.
            searchText = ""
        }
    }

    // MARK: - Header

    private var header: some View {
        // Build 65 (item 12): three buttons only, three distinct
        // treatments — "+ Add" solid blue (the one coloured
        // button, the primary action), "Filters" grey fill, "⋯"
        // grey outline — so no two share a colour or look very
        // similar (owner button rule, strengthened Nov 23, 2026).
        // The old page-links row (Review / Weeks / Export / More
        // pills + circular sync icon) is gone; its actions live
        // only in the ⋯ menu. Narrow-phone fit (375pt, default
        // type size): the row's content is 375 − 2×16 page
        // padding = 343pt wide. Title "Transactions" at 28pt
        // bold ≈ 168pt, "+ Add" ≈ 62pt, "Filters" ≈ 64pt,
        // "⋯" ≈ 44pt — intrinsic ≈ 338pt, inside 343pt.
        HStack(spacing: 8) {
            Text("Transactions")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("+ Add") { showingAdd = true }
                .buttonStyle(SmallPrimaryButtonStyle())
                // Walkthrough anchor (build 48): the + Add button.
                .tourAnchor(.addButton, tour: appState.tour)
            Button("Filters") { showingFilters = true }
                .buttonStyle(SmallTertiaryButtonStyle())
            Menu {
                // Sync Now: the SAME manual sync the circular
                // icon ran — `viewModel.runSync()` (Plaid bank +
                // Gmail email halves, toast confirms the result).
                // Shown for members too (build 64, F-19 — the
                // old admin-only gate is gone); disabled while
                // a sync is already running.
                Button {
                    Task { await viewModel.runSync() }
                } label: {
                    Label(viewModel.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isSyncing)
                // Review: admin-only, same gate and same handler
                // as the old pill — pushes the Review page via
                // the shell. The waiting count rides in the
                // label (the pill's badge has nowhere to sit in
                // a menu row).
                if viewModel.isAdmin, let onShowReview {
                    Button(action: onShowReview) {
                        Label(
                            reviewViewModel.reviewCount > 0
                                ? "Review (\(reviewViewModel.reviewCount))"
                                : "Review",
                            systemImage: "checkmark.circle"
                        )
                    }
                }
                // Weeks: same handler as the old pill — pushes
                // Past Weeks via the shell. Hidden until a
                // handler is supplied, so it never leads nowhere.
                if let onShowPastWeeks {
                    Button(action: onShowPastWeeks) {
                        Label("Weeks", systemImage: "calendar")
                    }
                    .accessibilityLabel("Past Weeks")
                }
                // Export: same as the old pill — opens the
                // full-screen export popup (PDF / CSV, filtered
                // scope or all).
                Button {
                    showingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export.open")
                Divider()
                // The rest of the old "More" menu, unchanged —
                // kept here so no destination is lost when the
                // pills row goes away.
                if let onShowActivity {
                    Button(action: onShowActivity) {
                        Label("Activity", systemImage: "list.bullet")
                    }
                }
                if viewModel.isAdmin, !viewModel.trashTransactions.isEmpty {
                    Button { showingTrash = true } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
                if viewModel.isAdmin, let onShowMerchantNames {
                    Button(action: onShowMerchantNames) {
                        Label("Merchants", systemImage: "tag")
                    }
                }
            } label: {
                Text("⋯")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
            }
            .buttonStyle(SmallGreyOutlineButtonStyle())
            .accessibilityLabel("More")
            .accessibilityIdentifier("header.more")
        }
    }

    // MARK: - Search + chips + count

    private var searchBox: some View {
        // Owner, Nov 12, 2026: standard modern iOS search look —
        // light grey filled field (system grey, no hard border),
        // magnifier inside on the left, short placeholder. The old
        // `.roundedBorder` field with its "(merchant, amount, date)"
        // placeholder read as ugly and wordy, and the "Searches
        // loaded transactions." explainer underneath it is deleted
        // outright (owner: unnecessary; standing declutter rule).
        // The × clear button is the standard search affordance:
        // clearing the box flows through the existing `onChange`
        // → `applySearch("")` path, and T-P1-1 (searchResetNonce)
        // still clears the box when filters clear.
        // Build 65 (item 12): the blue "Search" button is gone —
        // search is LIVE, no button tap needed. Typing already
        // filters through the `onChange(of: searchText)` →
        // `applySearch` path (250ms debounce, client-side over
        // the loaded rows), so the button only ever re-applied
        // what typing had already applied, plus dismissed the
        // keyboard. The keyboard's Return key now just dismisses
        // the keyboard.
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "#6b7280"))
            TextField("Search transactions", text: $searchText)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.done)
                .onSubmit { searchFocused = false }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "#9ca3af"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Build 68 (item 7/13): the search field is 48pt+ like every
        // other text field — 14pt horizontal, 14pt vertical padding.
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        // Search fill is systemGray6 (#f2f2f7, owner Nov 12 2026):
        // lighter than systemGray5 so the field sits quietly on
        // the white page, still reading as a field — no border.
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Walkthrough anchor (build 48): the search field.
        .tourAnchor(.searchBar, tour: appState.tour)
    }

    @ViewBuilder
    private var activeChips: some View {
        let chips = viewModel.filters.activeChips(customNames: appState.fundNames)
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.key) { chip in
                        Button {
                            // Clearing the search chip clears the
                            // visible box too (T-P1-1) — same rule as
                            // "Clear Search and Filters".
                            if chip.key == "search" { searchText = "" }
                            viewModel.filters.clearChip(chip.key)
                            viewModel.filterChanged()
                        } label: {
                            HStack(spacing: 4) {
                                Text(chip.label)
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            // Neutral grey, not pale (audit SH-P2-2,
                            // Nov 12 2026): pale #bfdbfe is ONLY the
                            // middle tier of a three-button row, and
                            // this is a tappable filter chip. Same
                            // fill as the grey tertiary buttons.
                            .background(Color(hex: "#e5e7eb"))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter \(chip.label)")
                    }
                }
            }
        }
    }

    private var countLine: some View {
        // Owner, Nov 12, 2026: one quiet muted line, tighter wording
        // ("Total", not "Total shown"), smaller than before; the
        // VStack's 14pt spacing gives it air from the field above
        // and the list below. Owner, Nov 16, 2026 (build 40): the
        // older-rows tail is gone from the text, and the line is
        // CENTERED (it was left-aligned) — same quiet muted style
        // and size, just centered on the page.
        Text(viewModel.countLine)
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: "#6b7280"))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("transactions.countLine")
    }

    /// Skeleton rows while the list loads (build 47 — owner, Nov
    /// 19, 2026: three rows left a large empty white area below
    /// while loading). A FULL page: ten fills the viewport on
    /// iPhone, sixteen on iPad — the same fix as Home's Recent
    /// list (owner, Nov 15, 2026 — ten rows there).
    private var loadingSkeletonCount: Int {
        horizontalSizeClass == .regular ? 16 : 10
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            // Shimmer skeletons shaped like the loaded list — one
            // white card with skeleton rows and dividers, no
            // spinner (owner loading language, Nov 12, 2026).
            VStack(spacing: 0) {
                ForEach(0..<loadingSkeletonCount, id: \.self) { index in
                    TransactionRowSkeleton()
                        .padding(14)
                    if index < loadingSkeletonCount - 1 {
                        Divider()
                            .padding(.leading, 64)
                    }
                }
            }
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityLabel("Loading transactions")
        case .failed(let error):
            VStack(alignment: .leading, spacing: 12) {
                if error == .sessionExpired {
                    Text("Your sign-in expired — sign in again to see transactions.")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.errorText)
                    Button("Sign In Again") {
                        viewModel.onSignInAgain?()
                    }
                    .buttonStyle(SmallPrimaryButtonStyle())
                } else {
                    Text("Could not load transactions — the server did not answer. Nothing here is a complete list.")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignTokens.errorText)
                    Button("Try Again") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(SmallPrimaryButtonStyle())
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.errorBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(DesignTokens.errorBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
        case .loaded:
            let shown = viewModel.shownTransactions
            if shown.isEmpty {
                emptyState
            } else {
                // ONE continuous list (owner, Nov 11, 2026): a single
                // white card with a divider between rows — not a
                // separate card per transaction. The divider insets to
                // the text column (row padding 14 + icon 40 + gap 10).
                VStack(spacing: 0) {
                    ForEach(shown) { transaction in
                        TransactionRowView(
                            transaction: transaction,
                            institutionName: transaction.cardSuffix == "0000"
                                ? nil : viewModel.institutionBySuffix[transaction.cardSuffix],
                            isExpanded: viewModel.expandedTransactionId == transaction.id,
                            hasActions: viewModel.hasActions(for: transaction),
                            searchQuery: viewModel.filters.search,
                            // Build 52 (week mode): a charge with a
                            // linked refund shows a "Refunded" mark
                            // — its amount nets to $0 in the header
                            // total, and the row keeps its original
                            // amount. Only in week mode, where the
                            // week's rows plus the refunds from the
                            // week start onward are loaded, so the
                            // mark is exact (build 53: the fetch is
                            // date-range filtered, not whole-history).
                            isRefunded: viewModel.isWeekMode && viewModel.refundedChargeIds.contains(transaction.id),
                            onToggle: {
                                if viewModel.expandedTransactionId == transaction.id {
                                    viewModel.expandedTransactionId = nil
                                } else {
                                    viewModel.expandedTransactionId = transaction.id
                                }
                            },
                            onActions: { actionsTransaction = transaction }
                        )
                        // Walkthrough anchor (build 48): the first
                        // row — the tour points at it and expands it
                        // for the "open a row" step.
                        .tourAnchor(
                            shown.first?.id == transaction.id ? .firstRow : nil,
                            tour: appState.tour
                        )
                        if transaction.id != shown.last?.id {
                            Divider()
                                .padding(.leading, 64)
                        }
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                // Walkthrough anchor (build 48): the list itself.
                .tourAnchor(.transactionsList, tour: appState.tour)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(emptyStateText)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
            if viewModel.filters.isSearchOrFilterActive {
                Button("Clear Search and Filters") {
                    viewModel.clearSearchAndFilters()
                }
                .buttonStyle(SmallTertiaryButtonStyle())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    private var emptyStateText: String {
        if viewModel.filters.amountRangeInvalid {
            return "Minimum amount is above the maximum amount — change one of them to see transactions."
        }
        if viewModel.filters.status == .refunds, viewModel.filters.isSearchOrFilterActive {
            return "No refunds in this list yet."
        }
        if viewModel.filters.status == .charity, viewModel.filters.isSearchOrFilterActive {
            return "No charity gifts in this list yet — record one from Add, or mark a posted donation as a gift."
        }
        if viewModel.filters.isSearchOrFilterActive {
            return "No matching transactions. Try a different search, or clear the search and filters."
        }
        return "No transactions here yet — add one by hand above, or connect a bank account and sync."
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        if case .loaded = viewModel.loadState, viewModel.hasMore {
            Button("Load More") {
                Task { await viewModel.loadMore() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isLoadingMore)
            .accessibilityLabel("Load more transactions")
        }
    }
}

/// Small grey-outline style for the Transactions header "⋯" menu
/// button (build 65, item 12): white background, 1pt grey #6b7280
/// border, ink text — the third treatment in the header trio
/// (solid blue "+ Add" / grey-fill "Filters" / grey outline "⋯"),
/// so no two header buttons share a colour or look very similar.
/// Same sizing as `SmallTertiaryButtonStyle` (14pt semibold,
/// 8pt vertical / 12pt horizontal, 8pt radius). Deliberately NOT
/// the shared `OutlineButtonStyle` — that one is brand-blue
/// border + text, which would read as a second blue button next
/// to "+ Add".
public struct SmallGreyOutlineButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DesignTokens.ink)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "#6b7280"), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Filters sheet (§7.3)

/// Bottom sheet: handle bar, heading "Filters" (RETHOUGHT, Nov 11,
/// 2026 — owner: "this page needs to be rethought"). One clear
/// control per question, nothing fighting anything else:
/// - When: ONE button ("Choose Dates" / "This Week" / "This Month" /
///   "Nov 8 – Nov 14") that opens ONE calendar — tap a start date,
///   then an end date. Quick picks (This Week / This Month) sit at
///   the top of the calendar; Clear lives in the calendar toolbar
///   (owner, Nov 12, 2026 — All Time is gone, Clear does that job).
///   No month dropdown, no "This week" toggle, no From/To fields on
///   this page.
/// - Status select: All transactions / Charity gifts / Spending /
///   Extra Fund / Pending / Posted / Refunds. Card / Account select ("All cards" default).
/// - Amount: Min / Max side by side (placeholders `$0.00`). Bounds
///   compare to the SIGNED amount; either end alone works; blank /
///   unparseable = no limit; min > max is a validation state, not an
///   empty result.
/// - Sort by: ONE picker with all four options (Newest / Oldest /
///   High to low / Low to high). Amount sort
///   is by absolute value. Sort persists (`hb-tx-sort`); month/card
///   persist (`hb-tx-month`, `hb-tx-card`).
/// - Fields: clean neutral — white with a light border, dark ink
///   lettering (the pale blue fill + blue lettering the owner called
///   ugly is gone; the dark-ink lettering is his narrower fix, kept).
///   Every control shares the same height (40pt minimum), squarish
///   with rounded edges (cornerRadius 10) — no round pills.
/// - Everything is draft-held: nothing applies until Apply. Apply
///   commits the whole draft and closes; Cancel restores the snapshot
///   taken on open and leaves the list unchanged; Reset (a small plain
///   link under the buttons, not a third button) clears everything to
///   defaults and closes.
/// - Bottom row: Apply (primary) / Cancel (tertiary) only.
public struct TransactionsFilterSheet: View {
    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void
    /// Custom fund names (build 37 — fund rename, owner Nov 16,
    /// 2026): the household's `fund_names` map, so the Status
    /// picker shows a renamed fund's name. [:] means the defaults.
    let fundNames: [String: String]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Snapshot taken on open; Cancel restores it.
    @State private var snapshot: TransactionFilters
    /// Sheet-held values: nothing commits until Apply.
    @State private var draftStatus: TransactionStatusFilter
    @State private var draftWhen: WhenSelection
    @State private var draftCard: String
    @State private var draftSort: TransactionSort
    @State private var minText: String = ""
    @State private var maxText: String = ""
    /// Which amount field holds the keyboard — the decimal pad
    /// has no return key, so the keyboard toolbar's Done button
    /// is the only way out (owner, Nov 13, 2026).
    @FocusState private var focusedField: AmountField?

    private enum AmountField: Hashable { case min, max }

    public init(viewModel: TransactionsViewModel, fundNames: [String: String] = [:], onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.fundNames = fundNames
        self.onDismiss = onDismiss
        _snapshot = State(initialValue: viewModel.filters)
        _draftStatus = State(initialValue: viewModel.filters.status)
        _draftWhen = State(initialValue: viewModel.filters.whenSelection)
        _draftCard = State(initialValue: viewModel.filters.card)
        _draftSort = State(initialValue: viewModel.filters.sort)
        _minText = State(initialValue: viewModel.filters.minCents.map { String(format: "%.2f", Double($0) / 100.0) } ?? "")
        _maxText = State(initialValue: viewModel.filters.maxCents.map { String(format: "%.2f", Double($0) / 100.0) } ?? "")
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                // Compact (owner, Nov 14, 2026): the section
                // headers are gone — each field's own value says
                // what it is ("All transactions", "Choose Dates",
                // "All cards", "Newest") — and the fields
                // are shorter (40pt, was 44pt), so the whole sheet
                // fits on one screen without scrolling. Only the
                // Min / Max labels stay: two side-by-side amount
                // fields need them to tell the ends apart.
                VStack(alignment: .leading, spacing: 12) {
                    // Status — the picker value says it.
                    // Build 65: `.tzedaka` is NOT offered here — it
                    // needs the accrual id set, which only the
                    // Tzedaka sheet handoff supplies. A list that
                    // arrived pre-filtered to Tzedaka keeps its
                    // status (the picker just shows "Status" until
                    // another pick is made).
                    Picker("Status", selection: $draftStatus) {
                        ForEach(TransactionStatusFilter.allCases.filter { $0 != .tzedaka }, id: \.self) { status in
                            Text(status.label(customNames: fundNames)).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    // Owner, Nov 13, 2026: the picked value
                    // reads black, not blue — the menu label
                    // follows the tint.
                    .tint(DesignTokens.ink)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 14)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // When — ONE button + ONE calendar (owner, Nov 11,
                    // 2026). The button shows the range; the calendar
                    // picks a start date, then an end date.
                    NavigationLink {
                        DateRangeCalendarView(selection: $draftWhen)
                    } label: {
                        HStack {
                            Text(draftWhen.label)
                                .font(.system(size: 15))
                                .foregroundStyle(DesignTokens.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: "#6b7280"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Card / Account — the picker value says it.
                    Picker("Card", selection: $draftCard) {
                        Text("All cards").tag("all")
                        ForEach(viewModel.cardsPresent, id: \.self) { card in
                            Text("••\(card)").tag(card)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DesignTokens.ink)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 14)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Amount + Sort on one row on iPad (regular size
                    // class, owner Nov 15, 2026): the sheet is 600pt
                    // wide there, so the shrunk sort box fits beside
                    // the Min/Max fields. On iPhone the row would not
                    // fit (343pt), so it stays stacked. The "Sort"
                    // label only appears on the shared row — stacked,
                    // the picker's own value says what it is, like
                    // the other fields (owner, Nov 14, 2026).
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 12) {
                            amountBlock
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sort")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                sortPicker
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        amountBlock
                        sortPicker
                    }

                    TwoButtonRow {
                        Button("Apply") { apply() }
                            .buttonStyle(PrimaryButtonStyle())
                            // T-P2-2: Apply stays disabled while the
                            // amount range is invalid — the error box
                            // above already says why.
                            .disabled(draftAmountInvalid)
                    } secondary: {
                        Button("Cancel") { cancel() }
                            .buttonStyle(TertiaryButtonStyle())
                    }

                    // Reset is a real button (owner, Nov 14, 2026):
                    // as a plain grey link under Apply / Cancel it
                    // did not read as tappable. Full-width outline,
                    // below the Apply / Cancel row — a third button
                    // in a different treatment, so no two adjacent
                    // buttons share a colour.
                    Button("Reset Filters") { reset() }
                        .buttonStyle(OutlineButtonStyle())
                }
                .padding()
            }
            // Dragging the sheet dismisses the keyboard too — the
            // number pad has no return key, so Done + drag are
            // the two ways out (owner, Nov 13, 2026).
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
            // Keyboard Done (owner, Nov 13, 2026): the decimal
            // pad has no return key and no other way to dismiss
            // it — this button resigns the amount field.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
        }
        // iPad width (owner, Nov 12, 2026): 600pt in the regular
        // size class, full-width on iPhone — same treatment as the
        // Weekly Budget sheet. The calendar pushed from here also
        // gets the extra width for its month grid.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    /// Draft amount bounds are invalid when both ends parse and
    /// min > max — a validation state, not an empty result.
    private var draftAmountInvalid: Bool {
        guard let min = TransactionFormatting.parseDollarsStrict(minText),
              let max = TransactionFormatting.parseDollarsStrict(maxText) else { return false }
        return min > max
    }

    /// Amount — draft-held like the rest; the validation reads the
    /// draft text, not the live filter. Min / Max carry visible
    /// labels above the fields (T-P1-4), and the fields share the
    /// sheet's white-bg + 1pt #e5e7eb border + cornerRadius 10
    /// treatment (T-P2-4). The $ is a fixed prefix inside the field
    /// (owner, Nov 13, 2026) — display only, never part of the typed
    /// text, so parsing is unchanged. No "Amount" header (owner,
    /// Nov 14, 2026): the Min / Max labels say what the fields are.
    private var amountBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Min")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    HStack(spacing: 2) {
                        Text("$")
                            .font(.system(size: 17))
                            .foregroundStyle(DesignTokens.ink)
                        TextField("0.00", text: $minText)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .min)
                    }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: 140, minHeight: 48, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Max")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    HStack(spacing: 2) {
                        Text("$")
                            .font(.system(size: 17))
                            .foregroundStyle(DesignTokens.ink)
                        TextField("0.00", text: $maxText)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .max)
                    }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: 140, minHeight: 48, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            if draftAmountInvalid {
                SoftErrorBox("Minimum amount is above the maximum amount — change one of them to see transactions.")
            }
        }
    }

    /// Sort — one picker with all four options (was a "Date" /
    /// "Amount" dropdown plus a separate direction button). The
    /// picker value says it.
    private var sortPicker: some View {
        Picker("Sort by", selection: $draftSort) {
            ForEach(TransactionSort.allCases, id: \.self) { sort in
                Text(sort.label).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .tint(DesignTokens.ink)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 14)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Apply commits the whole draft (status, when, card, sort,
    /// amount bounds) and closes. The when choice goes through
    /// `setWhenSelection`, so the applied filter holds exactly one
    /// date choice — never This week ON with dates set.
    private func apply() {
        viewModel.filters.status = draftStatus
        viewModel.filters.setWhenSelection(draftWhen)
        viewModel.filters.card = draftCard
        viewModel.filters.sort = draftSort
        viewModel.filters.minCents = TransactionFormatting.parseDollarsStrict(minText)
        viewModel.filters.maxCents = TransactionFormatting.parseDollarsStrict(maxText)
        viewModel.filterChanged()
        onDismiss()
    }

    /// Reset clears everything to defaults — including the search
    /// box, via `clearSearchAndFilters` (T-P1-1).
    private func reset() {
        viewModel.clearSearchAndFilters()
        let defaults = TransactionFilters()
        draftStatus = defaults.status
        draftWhen = defaults.whenSelection
        draftCard = defaults.card
        draftSort = defaults.sort
        minText = ""
        maxText = ""
        viewModel.filterChanged()
        onDismiss()
    }

    /// Cancel restores the snapshot taken on open and leaves the list
    /// unchanged. Build 53 (audit C7): filterChanged() now exits
    /// week mode, so Cancel must NOT call it — it restores the
    /// snapshot and persists only, and the list (including week
    /// mode) stays exactly as it was.
    private func cancel() {
        viewModel.filters = snapshot
        viewModel.persistFilters()
        onDismiss()
    }
}

/// ONE date control (owner, Nov 11, 2026): one button opens one
/// calendar; tap a start date, then an end date. Quick picks (This
/// Week / This Month) sit at the top; a third tap restarts the
/// range. The chosen range feeds the one date-range chip on the
/// Transactions page ("Nov 8 – Nov 14").
///
/// Shared (owner, Nov 12, 2026): the History date filter
/// (`HistoryDateFilterCard`, Past Weeks + Activity) presents this
/// same calendar in a sheet, bound to a `WhenSelection` it commits
/// into From/To drafts — there is exactly one range calendar.
/// Not private: SettingsShared.swift uses it; its internals stay
/// private to the struct.
///
/// Reworked Nov 12, 2026 (owner): the system graphical DatePicker
/// cannot render a range fill, so this is a custom month grid —
/// start and end are solid blue circles, the days between carry a
/// light-blue band, hotel-style. All Time is gone (Clear does that
/// job); Clear lives in the toolbar top-right, by the back arrow,
/// so Done is full-width and centered at the bottom.
struct DateRangeCalendarView: View {
    @Binding var selection: WhenSelection
    @Environment(\.dismiss) private var dismiss

    /// The range being built: first tap = start, second tap = end.
    @State private var pendingStart: Date?
    @State private var pendingEnd: Date?
    /// First day of the month currently shown.
    @State private var visibleMonth: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Picks")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DesignTokens.ink)
                    HStack(spacing: 10) {
                        // Build 64 (F-23): the quick picks were two
                        // adjacent identical outline buttons — the
                        // exact shape the no-adjacent-same-treatment
                        // rule forbids. Now one is primary blue and
                        // the other a quiet text link. The primary
                        // is compact (same padding as the soft
                        // button), not the full-width PrimaryButton
                        // treatment — the two picks share one row.
                        Button("This Week") { choose(.thisWeek) }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(DesignTokens.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("This Month") { choose(.thisMonth) }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.primary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    pendingLabel
                    monthHeader
                    weekdayHeader
                    monthGrid
                }

                Button("Done") { done() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
        }
        .navigationTitle("Choose Dates")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // T-P2-10: the owner Back treatment (light blue #3b82f6,
            // bold 700, 15px), not the system back button. Bare
            // chevron, no text (owner, Nov 15, 2026): "← Back"
            // truncated to "←…" here — the centred title + trailing
            // Clear squeeze the leading item — and a truncated
            // button must never ship. A symbol cannot truncate.
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(BackButtonStyle())
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") { choose(.allTime) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
        }
        .onAppear {
            // Seed the pending range from the current selection
            // (stored as YYYY-MM-DD strings) — for This Week /
            // This Month too (T-P2-9), so the calendar opens with
            // the range highlighted and the label showing it,
            // instead of opening blank.
            switch selection {
            case .custom(let from, let to):
                pendingStart = TransactionFormatting.dateFromString(from)
                pendingEnd = TransactionFormatting.dateFromString(to)
            case .thisWeek:
                let bounds = TransactionFormatting.currentWeekBounds()
                pendingStart = TransactionFormatting.dateFromString(bounds.start)
                pendingEnd = TransactionFormatting.dateFromString(bounds.end)
            case .thisMonth:
                let bounds = TransactionFormatting.currentMonthBounds()
                pendingStart = TransactionFormatting.dateFromString(bounds.start)
                pendingEnd = TransactionFormatting.dateFromString(bounds.end)
            case .allTime:
                break
            }
            if let start = pendingStart,
               let firstOfMonth = Calendar.current.date(
                from: Calendar.current.dateComponents([.year, .month], from: start)) {
                visibleMonth = firstOfMonth
            }
        }
    }

    // MARK: - Range label

    /// Start-only reads "Nov 19 – Pick end date" with the start
    /// date in blue until the end is picked (owner, Nov 12, 2026).
    @ViewBuilder
    private var pendingLabel: some View {
        switch (pendingStart, pendingEnd) {
        case (nil, _):
            Text("Tap a start date")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
        case (let start?, nil):
            Text(TransactionFormatting.displayDay(TransactionFormatting.string(from: start)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.primary)
            + Text(" – Pick end date")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
        case (let start?, let end?):
            let from = TransactionFormatting.string(from: start)
            let to = TransactionFormatting.string(from: end)
            if start == end {
                Text(TransactionFormatting.displayDay(from))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
            } else {
                Text("\(TransactionFormatting.displayDay(from)) – \(TransactionFormatting.displayDay(to))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
            }
        }
    }

    // MARK: - Custom calendar grid

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(Self.monthFormatter.string(from: visibleMonth))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
            Spacer()
            Button { shiftMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next month")
        }
    }

    /// SUN–SAT headers, rotated to the device calendar's first
    /// weekday so they line up with the grid below.
    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.shortWeekdaySymbols.map { $0.uppercased() }
        let start = Calendar.current.firstWeekday - 1
        guard start > 0 else { return symbols }
        return Array(symbols[start...] + symbols[..<start])
    }

    private var monthGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
            spacing: 4
        ) {
            // Enumerated by position: the leading blanks are all nil
            // and would collide as ForEach ids.
            ForEach(Array(daysInVisibleMonth().enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    /// The visible month's days as [Date?], with nil leading blanks
    /// so the 1st lands under the right weekday header.
    private func daysInVisibleMonth() -> [Date?] {
        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: visibleMonth)
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in dayRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: monthInterval.start) {
                days.append(date)
            }
        }
        return days
    }

    /// Start / end: solid blue circle, white number. Days strictly
    /// between: light-blue fill band across the whole cell, so the
    /// picked range reads as one hotel-style span.
    private func dayCell(_ date: Date) -> some View {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let isStart = pendingStart.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isEnd = pendingEnd.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let inRange: Bool = {
            guard let start = pendingStart, let end = pendingEnd else { return false }
            return day >= start && day <= end
        }()
        return Button { pick(day) } label: {
            ZStack {
                if inRange {
                    Rectangle().fill(Color(hex: "#dbeafe"))
                }
                if isStart || isEnd {
                    Circle()
                        .fill(DesignTokens.primary)
                        .frame(width: 36, height: 36)
                }
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 16, weight: (isStart || isEnd) ? .semibold : .regular))
                    .foregroundStyle((isStart || isEnd) ? .white : DesignTokens.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            // Whole-cell tap target (owner, Nov 15, 2026 app-wide
            // pass): an ordinary day is just a number with no
            // background, so without this only the digits respond.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(TransactionFormatting.displayDay(TransactionFormatting.string(from: day)))\(isStart ? ", range start" : "")\(isEnd ? ", range end" : "")")
    }

    private func shiftMonth(by months: Int) {
        if let shifted = Calendar.current.date(byAdding: .month, value: months, to: visibleMonth) {
            visibleMonth = shifted
        }
    }

    private func pick(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if pendingStart == nil || pendingEnd != nil {
            // First tap, or a third tap restarts the range.
            pendingStart = day
            pendingEnd = nil
        } else if let start = pendingStart {
            if day < start {
                // Tapped earlier than the start: the range is day–start.
                pendingEnd = start
                pendingStart = day
            } else {
                pendingEnd = day
            }
        }
    }

    private func choose(_ when: WhenSelection) {
        selection = when
        dismiss()
    }

    private func done() {
        if let start = pendingStart, let end = pendingEnd {
            selection = .custom(
                from: TransactionFormatting.string(from: start),
                to: TransactionFormatting.string(from: end)
            )
        } else if let start = pendingStart {
            // One date only: a single-day range.
            let day = TransactionFormatting.string(from: start)
            selection = .custom(from: day, to: day)
        }
        dismiss()
    }
}
