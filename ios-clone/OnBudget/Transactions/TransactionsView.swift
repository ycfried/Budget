import SwiftUI
import OnBudgetKit

/// Transactions screen (CLONE_SPEC §7).
///
/// - Heading "Transactions". Header actions (right, in order):
///   "+ Add" (primary) → the Add popup · "Filters" (tertiary) →
///   the filter sheet. The Add label stays compact so the 28pt
///   title fits on one line at iPhone width. The sync icon used to
///   sit here too (owner, Nov 12, 2026) but it read as a second
///   blue button next to "+ Add" (owner, Nov 12 ~10:29 PM), so it
///   now lives at the right end of the page-links row below, in
///   the lighter blue #3b82f6.
/// - Page links under the header: "Trash" · "Activity" · "Past Weeks"
///   on ONE line, as proper small low-key outline buttons (owner, Nov
///   11, 2026 — the quiet grey text read as labels, not as something
///   tappable; but not big or bulky — kinda low key). Trash shows no
///   count. The app shell supplies the
///   Activity / Past Weeks handlers, so the links push PastWeeksView /
///   ActivityView as subpages on the Transactions NavigationStack — the
///   native equivalent of the web's full pages. The links are hidden
///   until a handler is supplied, so they never lead nowhere. Trash is
///   admin-only, only when trashed rows exist. The manual sync icon
///   (admin only, 44pt circle, lighter blue) sits right-aligned at
///   the end of this row.
/// - Search box (owner, Nov 12, 2026): standard iOS search look —
///   system-grey filled field, magnifier inside on the left, short
///   "Search transactions" placeholder, no explainer underneath.
///   Searches loaded transactions only (merchant / date / amount;
///   250ms debounce). Filters apply client-side to the rows already
///   loaded, so a search or filter change needs no refetch.
/// - Active-filter chips: one removable chip per applied filter.
/// - Count line: "`N` transactions · Total `$X`" (+ the
///   older-rows suffix when the probe row came back) — one quiet
///   muted line.
/// - List: pages of 25 (owner, Nov 15, 2026 — the list loaded
///   everything at once and felt slow). Fetch asks for `pageSize +
///   1`; the probe row decides whether Load More shows — a page of
///   exactly 25 with no probe row does NOT show the button. Load
///   More appends the next 25 (offset) and never refetches what is
///   already loaded; the existing rows stay visible while it
///   appends. Filters, search, and sort apply client-side to
///   everything loaded so far.
/// - Pull-to-refresh + manual sync icon (admin only), at the right
///   end of the Trash / Activity / Past Weeks row: the same
///   `arrow.clockwise` symbol as the Home Weekly Budget card, in a
///   44pt circle — lighter blue #3b82f6 (DesignTokens.mid) when an
///   allowance has been set, grey while unset; it spins while
///   syncing. It used to sit in the title row before "+ Add", but
///   next to the blue "+ Add" it read as a second blue button
///   (owner, Nov 12 ~10:29 PM — option 2, lighter blue).
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
    @State private var showingFilters: Bool = false
    @State private var showingAdd: Bool = false
    @State private var showingTrash: Bool = false
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
    }

    public var body: some View {
        // Centered toast popup (owner, Nov 16, 2026 — build 38):
        // the ZStack alignment centers the popup; the ScrollView
        // fills the stack regardless of alignment.
        ZStack(alignment: .center) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    pageLinks
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

            if let toast = viewModel.toastManager.toast {
                ToastBanner(toast: toast) {
                    viewModel.toastManager.dismiss()
                }
            }
        }
        // Build 36 (owner, Nov 16, 2026 — iPad): the tab reads as a
        // centered 900pt column on the regular size class (see
        // mainContentWidth), never stretched edge-to-edge.
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
        .task {
            if case .idle = viewModel.loadState {
                await viewModel.load()
            }
            // Build 30: the Review badge count loads with the tab.
            // The Review page refreshes the same instance on open,
            // and every review action reloads it, so the badge
            // stays live without a second load here.
            await reviewViewModel.refreshReview()
            consumeHandoffs()
        }
        .onChange(of: appState.pendingWeekFilter) { _, _ in consumeHandoffs() }
        .onChange(of: appState.pendingTransactionJump) { _, _ in consumeHandoffs() }
        .onChange(of: appState.pendingClearTransactionFilters) { _, _ in consumeHandoffs() }
        .sheet(isPresented: $showingFilters) {
            TransactionsFilterSheet(viewModel: viewModel, fundNames: appState.fundNames, onDismiss: { showingFilters = false })
                // iPad sheet height (owner, Nov 13, 2026): the
                // Filters content is a ScrollView, and
                // .presentationSizing(.fitted) sizes a sheet to
                // its content's ideal height — a ScrollView has
                // no ideal height, so the sheet collapsed to a
                // sliver and clipped the rows (build 23). Detents
                // give it a real height on iPhone; on iPad they
                // are ignored and the sheet takes the default
                // form-sheet height. Width stays 600pt (regular)
                // via the frame inside the sheet content. Opens
                // at the LARGE detent only (owner, Nov 14, 2026):
                // at [.medium, .large] it opened half-height and
                // cut "Sort by" off at the bottom edge.
                .presentationDetents([.large])
                // White sheet background (owner, Nov 15, 2026): the
                // default sheet grey is off brand for form sheets.
                .presentationBackground(.white)
        }
        .sheet(isPresented: $showingAdd) {
            AddTransactionView(viewModel: viewModel, onDismiss: { showingAdd = false })
                .presentationBackground(.white)
                // No sizing here (owner, Nov 14, 2026): the size
                // depends on the step, so AddTransactionView sets
                // it itself — fitted on the options step, detents
                // [.medium, .large] on the purchase / donation
                // forms (ScrollViews — .fitted collapsed them in
                // build 23).
        }
        .sheet(isPresented: $showingTrash) {
            TrashView(viewModel: viewModel, onBack: { showingTrash = false })
                // iPad sheet height (owner, Nov 13, 2026): the
                // Trash content is a ScrollView — see the Filters
                // note above. .fitted collapsed it in build 23;
                // detents give a real height.
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $actionsTransaction) { transaction in
            TransactionActionsSheet(
                transaction: transaction,
                isAdmin: viewModel.isAdmin,
                viewModel: viewModel,
                fundNames: appState.fundNames,
                onDismiss: { actionsTransaction = nil }
            )
                // Size (owner, Nov 15, 2026 — build 34): the Actions
                // list flow and the Reclassify flow are one sheet —
                // fitted sizing rendered it nearly full-screen on
                // the phone with empty space above and below the
                // short content. Detents open it at a compact
                // medium height that fits the content, draggable to
                // large when needed. iPad width stays 600pt
                // (regular) via the frame inside the sheet content
                // — detents are ignored on iPad, same as the
                // Filters sheet.
                .presentationDetents([.medium, .large])
                .presentationBackground(.white)
        }
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
    }

    // MARK: - Handoffs from the app shell

    /// Past Weeks / Weekly sheet (`pendingWeekFilter`) and Home
    /// recent-row tap (`pendingTransactionJump`): apply to the list,
    /// then clear the flag so a later tab switch does not re-apply.
    /// Home "See All" (`pendingClearTransactionFilters`) clears
    /// search/filters first, same as the jump (audit H-P2-8).
    private func consumeHandoffs() {
        if let week = appState.pendingWeekFilter {
            appState.pendingWeekFilter = nil
            viewModel.applyWeekFilter(weekStart: week)
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
        // Title row, one line: "+ Add" (primary) then "Filters"
        // (tertiary) on the right, under which the Trash /
        // Activity / Past Weeks row moves up directly. The sync
        // button used to sit here before "+ Add" (owner, Nov 12,
        // 2026) but two blue buttons side by side read wrong, so
        // it moved to the right end of the page-links row below,
        // in the lighter blue (owner, Nov 12 ~10:29 PM — option 2).
        // Narrow-phone fit (375pt, default type size): the row's
        // content is 375 − 2×16 page padding = 343pt wide. Title
        // "Transactions" at 28pt bold ≈ 168pt, "+ Add" ≈ 62pt,
        // "Filters" ≈ 64pt — intrinsic ≈ 294pt, leaving room for
        // comfortable gaps.
        HStack(spacing: 8) {
            Text("Transactions")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("+ Add") { showingAdd = true }
                .buttonStyle(SmallPrimaryButtonStyle())
            Button("Filters") { showingFilters = true }
                .buttonStyle(SmallTertiaryButtonStyle())
        }
    }

    /// The manual sync button — same refresh symbol as the Home
    /// Weekly Budget card, same 44pt circle, same lighter-blue-
    /// when-set / grey-when-unset rule, same repeating spin while
    /// syncing (audit H-P1-1/H-P1-2). Placement: right-aligned at
    /// the end of the Trash / Activity / Past Weeks row (owner,
    /// Nov 12 ~10:29 PM — option 2); it used to sit in the title
    /// row before "+ Add", where it read as a second blue button.
    /// The fill is the lighter blue #3b82f6 (DesignTokens.mid),
    /// not the primary #2f6bff — same condition, same owner call.
    private var syncButton: some View {
        Button { Task { await viewModel.runSync() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .semibold))
                // White icon on the blue state; dark ink on the
                // grey state — white-on-grey was ~1.1:1 and
                // effectively invisible (audit H-P1-1).
                .foregroundStyle(viewModel.allowanceSet ? .white : DesignTokens.ink)
                .frame(width: 44, height: 44)
                .background(
                    viewModel.allowanceSet
                        ? DesignTokens.mid : Color(hex: "#e5e7eb"))
                .clipShape(Circle())
                // Repeating linear spin while syncing: a plain
                // 0°→360° rotation with no animation renders
                // identically at both ends, so it never
                // visibly spun (audit H-P1-2).
                .rotationEffect(.degrees(viewModel.isSyncing ? 360 : 0))
                .animation(
                    viewModel.isSyncing
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .default,
                    value: viewModel.isSyncing)
        }
        .disabled(viewModel.isSyncing)
        .accessibilityLabel(viewModel.isSyncing ? "Syncing Bank" : "Sync Bank")
    }

    @ViewBuilder
    private var pageLinks: some View {
        // Horizontally scrollable chip row (owner, Nov 15, 2026 —
        // build 34): Activity, Review, Trash, Past Weeks and
        // Merchants live in one row that swipes sideways — Activity
        // and Review first, so they are visible without scrolling;
        // swiping left reveals Trash, Past Weeks and Merchants. The
        // chips keep their natural width inside the ScrollView, so
        // no label wraps and none gets crushed (the old fixed HStack
        // squeezed Review to "Revi" / "ew" and Past Weeks to two
        // lines). A partially cut-off next chip at the right edge
        // shows the row scrolls. The chips are small outline
        // buttons (owner, Nov 11, 2026 — the quiet grey text read
        // as labels, not as something tappable). The manual sync
        // icon stays FIXED at the right end, outside the scrollable
        // area (owner, Nov 12 ~10:29 PM — option 2, lighter blue).
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let onShowActivity {
                        Button("Activity", action: onShowActivity)
                            .buttonStyle(SmallOutlineButtonStyle())
                    }
                    // Build 30: Review moved off the Funds page — an
                    // admin-only button here opens the dedicated Review
                    // page, with a count badge while anything is waiting
                    // (held refunds + possible duplicates + refund links).
                    // The badge is a small squarish count chip, not a pill.
                    if viewModel.isAdmin, let onShowReview {
                        Button(action: onShowReview) {
                            HStack(spacing: 6) {
                                Text("Review")
                                if reviewViewModel.reviewCount > 0 {
                                    Text("\(reviewViewModel.reviewCount)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DesignTokens.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        .buttonStyle(SmallOutlineButtonStyle())
                    }
                    if viewModel.isAdmin, !viewModel.trashTransactions.isEmpty {
                        Button("Trash") { showingTrash = true }
                            .buttonStyle(SmallOutlineButtonStyle())
                    }
                    if let onShowPastWeeks {
                        Button("Past Weeks", action: onShowPastWeeks)
                            .buttonStyle(SmallOutlineButtonStyle())
                    }
                    // Merchants (owner, Nov 15, 2026 — build 34):
                    // the Merchant Names editor moved out of
                    // Settings — it lives here now, as the last chip
                    // in this row. Admin-only, like Review.
                    if viewModel.isAdmin, let onShowMerchantNames {
                        Button("Merchants", action: onShowMerchantNames)
                            .buttonStyle(SmallOutlineButtonStyle())
                    }
                }
            }
            if viewModel.isAdmin {
                syncButton
            }
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "#6b7280"))
            TextField("Search transactions", text: $searchText)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Search fill is systemGray6 (#f2f2f7, owner Nov 12 2026):
        // lighter than systemGray5 so the field sits quietly on
        // the white page, still reading as a field — no border.
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        // and the list below.
        Text(viewModel.countLine)
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: "#6b7280"))
            .accessibilityIdentifier("transactions.countLine")
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            // Shimmer skeletons shaped like the loaded list — one
            // white card with three skeleton rows and dividers, no
            // spinner (owner loading language, Nov 12, 2026).
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    TransactionRowSkeleton()
                        .padding(14)
                    if index < 2 {
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
                            onToggle: {
                                if viewModel.expandedTransactionId == transaction.id {
                                    viewModel.expandedTransactionId = nil
                                } else {
                                    viewModel.expandedTransactionId = transaction.id
                                }
                            },
                            onActions: { actionsTransaction = transaction }
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
                    Picker("Status", selection: $draftStatus) {
                        ForEach(TransactionStatusFilter.allCases, id: \.self) { status in
                            Text(status.label(customNames: fundNames)).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    // Owner, Nov 13, 2026: the picked value
                    // reads black, not blue — the menu label
                    // follows the tint.
                    .tint(DesignTokens.ink)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

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
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

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
                        .padding(.horizontal, 10)
                        .frame(maxWidth: 140, minHeight: 40, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                        .padding(.horizontal, 10)
                        .frame(maxWidth: 140, minHeight: 40, alignment: .leading)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
    /// unchanged.
    private func cancel() {
        viewModel.filters = snapshot
        viewModel.persistFilters()
        viewModel.filterChanged()
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
                        Button("This Week") { choose(.thisWeek) }
                            .buttonStyle(SmallOutlineButtonStyle())
                        Button("This Month") { choose(.thisMonth) }
                            .buttonStyle(SmallOutlineButtonStyle())
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
