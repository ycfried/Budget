import SwiftUI
import OnBudgetKit

/// Transactions screen (CLONE_SPEC §7).
///
/// - Heading "Transactions". Header actions (right): "+ Add
///   Transaction" (primary) → the Add popup; "Filters" (tertiary) →
///   the filter sheet.
/// - Page links under the header: "Past Weeks" · "Activity" (quiet
///   links). The app shell supplies both handlers, so the links
///   push PastWeeksView / ActivityView as subpages on the
///   Transactions NavigationStack — the native equivalent of the
///   web's full pages. The links are hidden until a handler is
///   supplied, so they never lead nowhere.
/// - Search box + note "Searches loaded transactions." (loaded
///   transactions only; merchant / date / amount; 250ms debounce;
///   a new search resets the page to 100).
/// - Active-filter chips: one removable chip per applied filter.
/// - Count line: "`N` transactions · Total shown `$X`" (+ the
///   older-rows suffix when the probe row came back).
/// - Trash link row (above the list, admin-only, only when trashed
///   rows exist): "Trash (N)".
/// - List: pages of 100. Fetch asks for `txLimit + 1`; the probe row
///   decides whether Load More shows — a page of exactly 100 with no
///   probe row does NOT show the button. Load More raises the limit
///   by 100 and refreshes. Every filter/search/sort change is a new
///   list: the page resets to 100.
/// - Pull-to-refresh + manual sync button (admin only; primary blue
///   when an allowance has been set, grey tertiary while unset).
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
                    trashLink
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
        .alert(
            viewModel.alertTitle ?? "Something Went Wrong",
            isPresented: $viewModel.showAlert,
            presenting: viewModel.alertMessage
        ) { _ in
            Button("Close", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onChange(of: searchText) { _, new in
            viewModel.applySearch(new)
        }
    }

    // MARK: - Handoffs from the app shell

    /// Past Weeks / Weekly sheet (`pendingWeekFilter`) and Home
    /// recent-row tap (`pendingTransactionJump`): apply to the list,
    /// then clear the flag so a later tab switch does not re-apply.
    private func consumeHandoffs() {
        if let week = appState.pendingWeekFilter {
            appState.pendingWeekFilter = nil
            viewModel.applyWeekFilter(weekStart: week)
        }
        if let jump = appState.pendingTransactionJump {
            appState.pendingTransactionJump = nil
            viewModel.applyTransactionJump(jump)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transactions")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Spacer()
                Button("+ Add Transaction") { showingAdd = true }
                    .buttonStyle(SmallPrimaryButtonStyle())
                Button("Filters") { showingFilters = true }
                    .buttonStyle(SmallTertiaryButtonStyle())
            }
            if viewModel.isAdmin {
                HStack {
                    Button(viewModel.isSyncing ? "Syncing…" : "Sync Transactions") {
                        Task { await viewModel.runSync() }
                    }
                    .buttonStyle(viewModel.allowanceSet ? AnyButtonStyle(SmallPrimaryButtonStyle()) : AnyButtonStyle(SmallTertiaryButtonStyle()))
                    .disabled(viewModel.isSyncing)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var pageLinks: some View {
        HStack(spacing: 16) {
            if let onShowPastWeeks {
                Button("Past Weeks", action: onShowPastWeeks)
                    .buttonStyle(QuietButtonStyle())
            }
            if let onShowActivity {
                Button("Activity", action: onShowActivity)
                    .buttonStyle(QuietButtonStyle())
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
                            .background(DesignTokens.pale)
                            .clipShape(Capsule())
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

    @ViewBuilder
    private var trashLink: some View {
        if viewModel.isAdmin, !viewModel.trashTransactions.isEmpty {
            Button("Trash (\(viewModel.trashTransactions.count))") {
                showingTrash = true
            }
            .buttonStyle(QuietButtonStyle())
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView("Loading…")
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
                VStack(spacing: 12) {
                    ForEach(shown) { transaction in
                        TransactionRowView(
                            transaction: transaction,
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
                    }
                }
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

/// Bottom sheet: handle bar, heading "Filters".
/// Status select: All transactions / Charity gifts / Pending / Posted / Refunds.
/// When group: Month select (months present in loaded transactions,
/// newest first, "All months" default); This week checkbox (current
/// Sun–Sat, NY); From / To date fields side by side, compact
/// (labels shortened to "From"/"To" — never "From date"/"To date",
/// never massive full-width fields).
/// Card / Account select ("All cards" default; options `••suffix`).
/// Amount group: Min / Max side by side (placeholders `$0.00`;
/// "Blank = no limit. Refunds count as negative amounts."). Bounds
/// compare to the SIGNED amount; either end alone works; blank /
/// unparseable = no limit; min > max is a validation state, not an
/// empty result. Bounds apply live (debounced 250ms, not persisted).
/// Sort by select (Date / Amount) + direction button showing arrow
/// AND words. Amount sort is by absolute value. Sort persists
/// (`hb-tx-sort`); month/card persist (`hb-tx-month`, `hb-tx-card`).
/// Button row (three-button rule): Apply (primary) / Reset (pale) /
/// Cancel (tertiary). Apply commits the sheet-held status/week/date
/// values (month, card, bounds, sort already apply live) and closes;
/// Reset clears everything to defaults; Cancel restores the snapshot
/// taken on open and leaves the list unchanged.
public struct TransactionsFilterSheet: View {
    @Bindable var viewModel: TransactionsViewModel
    let onDismiss: () -> Void

    /// Snapshot taken on open; Cancel restores it.
    @State private var snapshot: TransactionFilters
    /// Sheet-held values: status / week / dates commit on Apply only.
    @State private var draftStatus: TransactionStatusFilter
    @State private var draftWeekOnly: Bool
    @State private var draftFromDate: Date?
    @State private var draftToDate: Date?
    @State private var minText: String = ""
    @State private var maxText: String = ""

    public init(viewModel: TransactionsViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        _snapshot = State(initialValue: viewModel.filters)
        _draftStatus = State(initialValue: viewModel.filters.status)
        _draftWeekOnly = State(initialValue: viewModel.filters.weekOnly)
        _draftFromDate = State(initialValue: TransactionFormatting.dateFromString(viewModel.filters.fromDate))
        _draftToDate = State(initialValue: TransactionFormatting.dateFromString(viewModel.filters.toDate))
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(DesignTokens.pale)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // When: month + this week + from/to
                    VStack(alignment: .leading, spacing: 10) {
                        Text("When")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Picker("Month", selection: Binding(
                            get: { viewModel.filters.month },
                            set: { new in
                                viewModel.filters.month = new
                                viewModel.filterChanged()
                            }
                        )) {
                            Text("All months").tag("all")
                            ForEach(viewModel.monthsPresent, id: \.self) { month in
                                Text(TransactionFormatting.monthLabel(month)).tag(month)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(DesignTokens.pale)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Toggle("This week", isOn: $draftWeekOnly)
                            .font(.system(size: 15))

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("From")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                DatePicker("", selection: Binding(
                                    get: { draftFromDate ?? Date() },
                                    set: { draftFromDate = $0 }
                                ), displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("To")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DesignTokens.ink)
                                DatePicker("", selection: Binding(
                                    get: { draftToDate ?? Date() },
                                    set: { draftToDate = $0 }
                                ), displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            if draftFromDate != nil {
                                Button("Clear From") { draftFromDate = nil }
                                    .buttonStyle(QuietButtonStyle())
                            }
                            if draftToDate != nil {
                                Button("Clear To") { draftToDate = nil }
                                    .buttonStyle(QuietButtonStyle())
                            }
                        }
                    }

                    // Card / Account
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Card / Account")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        Picker("Card", selection: Binding(
                            get: { viewModel.filters.card },
                            set: { new in
                                viewModel.filters.card = new
                                viewModel.filterChanged()
                            }
                        )) {
                            Text("All cards").tag("all")
                            ForEach(viewModel.cardsPresent, id: \.self) { card in
                                Text("••\(card)").tag(card)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(DesignTokens.pale)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Amount
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Amount")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        HStack(spacing: 12) {
                            TextField("$0.00", text: $minText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 140)
                                .onChange(of: minText) { _, _ in applyBounds() }
                            TextField("$0.00", text: $maxText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 140)
                                .onChange(of: maxText) { _, _ in applyBounds() }
                        }
                        Text("Blank = no limit. Refunds count as negative amounts.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#6b7280"))
                        if viewModel.filters.amountRangeInvalid {
                            SoftErrorBox("Minimum amount is above the maximum amount — change one of them to see transactions.")
                        }
                    }

                    // Sort
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sort by")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.ink)
                        HStack(spacing: 12) {
                            Picker("Sort by", selection: Binding(
                                get: { viewModel.filters.sort.field },
                                set: { field in
                                    viewModel.filters.sort = viewModel.filters.sort.withField(field)
                                    viewModel.filterChanged()
                                }
                            )) {
                                Text("Date").tag("date")
                                Text("Amount").tag("amount")
                            }
                            .pickerStyle(.menu)
                            .padding(8)
                            .background(DesignTokens.pale)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button(viewModel.filters.sort.directionLabel) {
                                viewModel.filters.sort = viewModel.filters.sort.toggledDirection()
                                viewModel.filterChanged()
                            }
                            .buttonStyle(SmallTertiaryButtonStyle())
                        }
                    }

                    ThreeButtonRow {
                        Button("Apply") { apply() }
                            .buttonStyle(PrimaryButtonStyle())
                    } middle: {
                        Button("Reset") { reset() }
                            .buttonStyle(PaleButtonStyle())
                    } last: {
                        Button("Cancel") { cancel() }
                            .buttonStyle(TertiaryButtonStyle())
                    }
                }
                .padding()
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Bounds apply live (debounced by the view model's search-style
    /// path — here applied directly; the list re-renders on change).
    private func applyBounds() {
        viewModel.filters.minCents = TransactionFormatting.parseDollarsStrict(minText)
        viewModel.filters.maxCents = TransactionFormatting.parseDollarsStrict(maxText)
        viewModel.filterChanged()
    }

    /// Apply commits the sheet-held status/week/date values and closes.
    private func apply() {
        viewModel.filters.status = draftStatus
        viewModel.filters.weekOnly = draftWeekOnly
        viewModel.filters.fromDate = draftFromDate.map(TransactionFormatting.string(from:)) ?? ""
        viewModel.filters.toDate = draftToDate.map(TransactionFormatting.string(from:)) ?? ""
        viewModel.filterChanged()
        onDismiss()
    }

    /// Reset clears everything to defaults.
    private func reset() {
        viewModel.filters = TransactionFilters()
        viewModel.persistFilters()
        draftStatus = .all
        draftWeekOnly = false
        draftFromDate = nil
        draftToDate = nil
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
