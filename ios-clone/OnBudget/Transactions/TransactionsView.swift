import SwiftUI
import OnBudgetKit

/// Transactions screen (CLONE_SPEC §7).
///
/// - Heading "Transactions". Header actions (right): "+ Add"
///   (primary) → the Add popup; "Filters" (tertiary) → the filter
///   sheet. The Add label stays compact so the 28pt title fits on
///   one line at iPhone width.
/// - Page links under the header: "Trash" · "Activity" · "Past Weeks"
///   on ONE line, as proper small low-key outline buttons (owner, Nov
///   11, 2026 — the quiet grey text read as labels, not as something
///   tappable; but not big or bulky — kinda low key). Trash shows no
///   count. The app shell supplies the
///   Activity / Past Weeks handlers, so the links push PastWeeksView /
///   ActivityView as subpages on the Transactions NavigationStack — the
///   native equivalent of the web's full pages. The links are hidden
///   until a handler is supplied, so they never lead nowhere. Trash is
///   admin-only, only when trashed rows exist.
/// - Search box + note "Searches loaded transactions." (loaded
///   transactions only; merchant / date / amount; 250ms debounce;
///   a new search resets the page to 100).
/// - Active-filter chips: one removable chip per applied filter.
/// - Count line: "`N` transactions · Total shown `$X`" (+ the
///   older-rows suffix when the probe row came back).
/// - List: pages of 100. Fetch asks for `txLimit + 1`; the probe row
///   decides whether Load More shows — a page of exactly 100 with no
///   probe row does NOT show the button. Load More raises the limit
///   by 100 and refreshes. Every filter/search/sort change is a new
///   list: the page resets to 100.
/// - Pull-to-refresh + manual sync icon (admin only): the same
///   `arrow.clockwise` symbol as the Home Weekly Budget card, in a
///   44pt circle — primary blue when an allowance has been set, grey
///   while unset; it spins while syncing.
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

    /// Wired by the app shell: both handlers push the matching
    /// subpage onto the Transactions NavigationStack. The links are
    /// hidden until a handler is supplied, so they never lead nowhere.
    var onShowPastWeeks: (() -> Void)?
    var onShowActivity: (() -> Void)?

    @State private var searchText: String = ""
    @State private var showingFilters: Bool = false
    @State private var showingAdd: Bool = false
    @State private var showingTrash: Bool = false
    @State private var actionsTransaction: Transaction?

    public init(
        viewModel: TransactionsViewModel,
        appState: AppViewModel,
        onShowPastWeeks: (() -> Void)? = nil,
        onShowActivity: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.appState = appState
        self.onShowPastWeeks = onShowPastWeeks
        self.onShowActivity = onShowActivity
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
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
        .task {
            if case .idle = viewModel.loadState {
                await viewModel.load()
            }
            consumeHandoffs()
        }
        .onChange(of: appState.pendingWeekFilter) { _, _ in consumeHandoffs() }
        .onChange(of: appState.pendingTransactionJump) { _, _ in consumeHandoffs() }
        .onChange(of: appState.pendingClearTransactionFilters) { _, _ in consumeHandoffs() }
        .sheet(isPresented: $showingFilters) {
            TransactionsFilterSheet(viewModel: viewModel, onDismiss: { showingFilters = false })
        }
        .sheet(isPresented: $showingAdd) {
            AddTransactionView(viewModel: viewModel, onDismiss: { showingAdd = false })
        }
        .sheet(isPresented: $showingTrash) {
            TrashView(viewModel: viewModel, onBack: { showingTrash = false })
        }
        .sheet(item: $actionsTransaction) { transaction in
            TransactionActionsSheet(
                transaction: transaction,
                isAdmin: viewModel.isAdmin,
                viewModel: viewModel,
                onDismiss: { actionsTransaction = nil }
            )
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transactions")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Spacer()
                Button("+ Add") { showingAdd = true }
                    .buttonStyle(SmallPrimaryButtonStyle())
                Button("Filters") { showingFilters = true }
                    .buttonStyle(SmallTertiaryButtonStyle())
            }
            if viewModel.isAdmin {
                HStack {
                    // Sync: the same refresh symbol as the Home Weekly
                    // Budget card (owner, Nov 11, 2026) — an icon, no
                    // text pill. Primary blue once an allowance is set,
                    // grey before that (same rule as Home); it spins
                    // while syncing.
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
                                    ? DesignTokens.primary : Color(hex: "#e5e7eb"))
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
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var pageLinks: some View {
        // Trash, Activity and Past Weeks on ONE line, as proper
        // buttons (owner, Nov 11, 2026 — the quiet grey text read as
        // labels, not as something tappable, so the row now has a
        // clear button affordance — but low-key: small outline
        // buttons, not big bulky filled ones). Trash shows no count.
        // Three peer navigation buttons share the one treatment by
        // design — the no-duplicates button rule governs action rows
        // where one action must stand out, not peers.
        HStack(spacing: 12) {
            if viewModel.isAdmin, !viewModel.trashTransactions.isEmpty {
                Button("Trash") { showingTrash = true }
                    .buttonStyle(SmallOutlineButtonStyle())
            }
            if let onShowActivity {
                Button("Activity", action: onShowActivity)
                    .buttonStyle(SmallOutlineButtonStyle())
            }
            if let onShowPastWeeks {
                Button("Past Weeks", action: onShowPastWeeks)
                    .buttonStyle(SmallOutlineButtonStyle())
            }
        }
    }

    // MARK: - Search + chips + count

    private var searchBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search transactions (merchant, amount, date)", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Searches loaded transactions.")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    @ViewBuilder
    private var activeChips: some View {
        let chips = viewModel.filters.activeChips
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
        Text(viewModel.countLine)
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: "#6b7280"))
            .accessibilityIdentifier("transactions.countLine")
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(hex: "#f1f5f9"))
                        .frame(height: 76)
                }
            }
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
/// - Status select: All transactions / Charity gifts / Pending /
///   Posted / Refunds. Card / Account select ("All cards" default).
/// - Amount: Min / Max side by side (placeholders `$0.00`). Bounds
///   compare to the SIGNED amount; either end alone works; blank /
///   unparseable = no limit; min > max is a validation state, not an
///   empty result.
/// - Sort by: ONE picker with all four options (Newest first / Oldest
///   first / Amount: high to low / Amount: low to high). Amount sort
///   is by absolute value. Sort persists (`hb-tx-sort`); month/card
///   persist (`hb-tx-month`, `hb-tx-card`).
/// - Fields: clean neutral — white with a light border, dark ink
///   lettering (the pale blue fill + blue lettering the owner called
///   ugly is gone; the dark-ink lettering is his narrower fix, kept).
///   Every control shares the same height (44pt minimum), squarish
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

    /// Snapshot taken on open; Cancel restores it.
    @State private var snapshot: TransactionFilters
    /// Sheet-held values: nothing commits until Apply.
    @State private var draftStatus: TransactionStatusFilter
    @State private var draftWhen: WhenSelection
    @State private var draftCard: String
    @State private var draftSort: TransactionSort
    @State private var minText: String = ""
    @State private var maxText: String = ""

    public init(viewModel: TransactionsViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
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
                VStack(alignment: .leading, spacing: 18) {
                    // Status
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Picker("Status", selection: $draftStatus) {
                            ForEach(TransactionStatusFilter.allCases, id: \.self) { status in
                                Text(status.label).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // When — ONE button + ONE calendar (owner, Nov 11,
                    // 2026). The button shows the range; the calendar
                    // picks a start date, then an end date.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
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
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // Card / Account
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Card / Account")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Picker("Card", selection: $draftCard) {
                            Text("All cards").tag("all")
                            ForEach(viewModel.cardsPresent, id: \.self) { card in
                                Text("••\(card)").tag(card)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Amount — draft-held like the rest; the
                    // validation reads the draft text, not the live
                    // filter. Min / Max carry visible labels above
                    // the fields (T-P1-4), and the fields share the
                    // sheet's white-bg + 1pt #e5e7eb border +
                    // cornerRadius 10 treatment (T-P2-4).
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Amount")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Min")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                TextField("$0.00", text: $minText)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: 140, minHeight: 44, alignment: .leading)
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
                                TextField("$0.00", text: $maxText)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: 140, minHeight: 44, alignment: .leading)
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

                    // Sort — one picker with all four options (was a
                    // "Date"/"Amount" dropdown plus a separate
                    // direction button).
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sort by")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Picker("Sort by", selection: $draftSort) {
                            ForEach(TransactionSort.allCases, id: \.self) { sort in
                                Text(sort.label).tag(sort)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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

                    // Reset is a small plain link, not a third button.
                    HStack {
                        Spacer()
                        Button("Reset Filters") { reset() }
                            .buttonStyle(QuietButtonStyle())
                        Spacer()
                    }
                }
                .padding()
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Draft amount bounds are invalid when both ends parse and
    /// min > max — a validation state, not an empty result.
    private var draftAmountInvalid: Bool {
        guard let min = TransactionFormatting.parseDollarsStrict(minText),
              let max = TransactionFormatting.parseDollarsStrict(maxText) else { return false }
        return min > max
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
/// Reworked Nov 12, 2026 (owner): the system graphical DatePicker
/// cannot render a range fill, so this is a custom month grid —
/// start and end are solid blue circles, the days between carry a
/// light-blue band, hotel-style. All Time is gone (Clear does that
/// job); Clear lives in the toolbar top-right, by the back arrow,
/// so Done is full-width and centered at the bottom.
private struct DateRangeCalendarView: View {
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
            // bold 700, 15px), not the system back button.
            ToolbarItem(placement: .topBarLeading) {
                Button("← Back") { dismiss() }
                    .buttonStyle(BackButtonStyle())
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
