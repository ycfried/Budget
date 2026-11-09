// OnBudget — HomeView.swift
//
// Home screen (CLONE_SPEC §6, live.html:103-141,
// live.js:594-730, 1040-1110, 3457-3650) + Weekly sheet (§14).
//
// Owner's priority order (Nov 3): (1) what's left for budget,
// (2) what's left for charity, (3) what's left in Extra Fund,
// (4) what was spent. DOM order is hero → Charity → Extra Fund →
// Recent; do not reorder. All figures come from `compute-week` /
// server state — the client NEVER recomputes week math locally.
// The only client-side derivations are the display splits the web
// itself does: effective allowance = base room + temp (both server
// fields), and the Fund/Charity display aggregations in
// OnBudgetKit's FundSummary / CharitySummary.
//
// Hero: white card, 1.5px #2f6bff outline, no shadow. Sync button
// is primary blue when allowance set, grey tertiary until set;
// "Set Your Weekly Allowance" (admin only) when none set. Purchases
// shows "N/A" — never a bare dash — when transactions fail to load.
// Fund + Charity cards: stacked, Charity above Extra Fund, both
// full-width, expand downward IN PLACE, one-open-at-a-time, with
// the expand detail (Available / Pending / Total) and NO action
// buttons on Home (actions belong on the Funds page).
// "Last synced" is shown once, quietly, under Automatic Sync in
// Settings; Home carries the same value in the footer
// ("OnBudget · Last bank sync …", live.html:560-562).
//
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

// MARK: - Section load state

/// Loading, then data or a REAL error — never an endless spinner
/// (the web app has a live "Loading…" hang; the clone must not
/// copy it).
public enum HomeSectionState<Value> {
    case loading
    case loaded(Value)
    case failed(OnBudgetError)
}

// MARK: - View model

@MainActor
public final class HomeViewModel: ObservableObject {

    private let client: SupabaseClient
    private let appState: AppViewModel
    private let householdId: UUID

    @Published public var week: HomeSectionState<WeekResult> = .loading
    @Published public var allowanceSet: Bool?
    @Published public var fund: HomeSectionState<FundSummary> = .loading
    @Published public var charity: HomeSectionState<CharitySummary> = .loading
    @Published public var recent: HomeSectionState<[Transaction]> = .loading
    /// Purchases this week; nil when transactions failed to load,
    /// so the hero shows "N/A" (never a bare dash).
    @Published public var purchasesThisWeek: Int?
    /// Week-counted charges, for the empty-week hint.
    @Published public var hasWeekTransactions = false
    @Published public var lastSyncText: String?
    @Published public var isSyncing = false
    /// Card suffix → institution name (best-effort, for bank icons).
    @Published public var institutionBySuffix: [String: String] = [:]

    public init(client: SupabaseClient, appState: AppViewModel, householdId: UUID) {
        self.client = client
        self.appState = appState
        self.householdId = householdId
    }

    public var isAdmin: Bool { appState.isAdmin }

    /// The single data load (live.js refresh() order, Home subset):
    /// compute-week (+ admin week-close once per session), allowance
    /// flag, transactions page, fund ledger + releases, charity
    /// income + settings, Plaid items for the last-sync stamp.
    /// Each section fails independently with a real error state.
    public func refresh() async {
        week = .loading
        fund = .loading
        charity = .loading
        recent = .loading

        // Week numbers first — everything else keys off the week.
        do {
            var result = try await client.functions.computeWeek(householdId: householdId)
            if await appState.runWeekCloseIfDue() {
                result = try await client.functions.computeWeek(householdId: householdId)
            }
            week = .loaded(result)
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            week = .failed(error)
        } catch {
            week = .failed(.unknown("Could not load this week's numbers."))
        }

        // Allowance-set flag ($375 is the schema default, not a
        // choice — allowanceSetAt == nil means never set).
        do {
            let allowance = try await client.postgrest.householdAllowance(householdId: householdId)
            allowanceSet = allowance.allowanceExplicitlySet
        } catch {
            allowanceSet = nil
        }

        // Transactions page (100 + probe row): recent 6, purchases
        // count, charity gifts. A failure here is an error state,
        // never a silent empty list.
        var weekStart: String?
        if case .loaded(let result) = week { weekStart = result.weekStart }
        do {
            let (rows, _) = try await client.postgrest.transactionsPage(householdId: householdId)
            let visible = rows.filter { !$0.isInTrash }
            recent = .loaded(Array(visible.prefix(6)))
            if let weekStart {
                let weekRows = visible.filter { AppDates.isInWeek($0.date, weekStart: weekStart) }
                purchasesThisWeek = weekRows.filter {
                    $0.kind == .charge && $0.state != .reversed
                }.count
                hasWeekTransactions = !weekRows.isEmpty
            } else {
                purchasesThisWeek = nil
            }
            // Charity summary needs the charity rows + income.
            await loadCharity(charityRows: visible.filter { $0.kind == .charity })
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            recent = .failed(error)
            purchasesThisWeek = nil
            charity = .failed(error)
        } catch {
            recent = .failed(.unknown("Could not load recent transactions."))
            purchasesThisWeek = nil
            charity = .failed(.unknown("Could not load charity."))
        }

        // Extra Fund display aggregation (sums over server rows).
        do {
            async let ledger = client.postgrest.fundLedger(householdId: householdId)
            async let releases = client.postgrest.surplusReleases(householdId: householdId)
            async let shortfall = client.postgrest.fundShortfallCents(householdId: householdId)
            let summary = FundSummary.compute(
                ledger: try await ledger, releases: try await releases,
                shortfallCents: try await shortfall)
            fund = .loaded(summary)
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            fund = .failed(error)
        } catch {
            fund = .failed(.unknown("Could not load Extra Fund balances."))
        }

        // Last-sync stamp: freshest plaid_items.last_sync_at
        // (live.js:560-562, 1348). Best-effort — never blocks Home.
        do {
            let items = try await client.postgrest.plaidItems(householdId: householdId)
            let stamps = items.compactMap(\.lastSyncAt).sorted()
            lastSyncText = AppDates.lastSyncLabel(isoTimestamp: stamps.last)
            // Suffix → institution map for bank icons (best-effort).
            let pairs = try await client.postgrest.plaidItemInstitutions(householdId: householdId)
            let masks = try await client.postgrest.plaidAccountMasks(
                itemIds: pairs.map(\.itemId))
            var map: [String: String] = [:]
            for (itemId, mask) in masks {
                guard let mask,
                      let pair = pairs.first(where: { $0.itemId == itemId }),
                      let name = pair.institutionName else { continue }
                map[mask] = name
            }
            institutionBySuffix = map
        } catch {
            lastSyncText = nil
        }
    }

    private func loadCharity(charityRows: [Transaction]) async {
        do {
            async let income = client.postgrest.activeCharityIncome(householdId: householdId)
            async let settings = client.postgrest.charitySettings(householdId: householdId)
            let summary = CharitySummary.compute(
                activeIncome: try await income,
                charityTransactions: charityRows,
                defaultRateBp: try await settings?.defaultRateBp ?? 1000)
            charity = .loaded(summary)
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            charity = .failed(error)
        } catch {
            charity = .failed(.unknown("Could not load charity."))
        }
    }

    // MARK: - Bank sync

    /// Home sync button (live.js:2842-2876, runBankSync): admin
    /// only, one sync at a time, spins while running. The toast
    /// text is bankSyncToast (filterState.mjs:449-463).
    public func syncBank() async {
        guard isAdmin, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let outcome = try await client.functions.plaidSyncAllowingPartialFailure(householdId: householdId)
            switch outcome {
            case .success(let result):
                appState.showToast(Self.syncToastText(result), kind: .success)
            case .partial(let partial):
                appState.showToast(
                    "Sync done: \(partial.result.added) added, \(partial.result.updated) updated, \(partial.result.skipped) skipped across \(partial.result.items) connected account(s). — \(partial.failedInstitutions.joined(separator: ", "))",
                    kind: .error)
            }
            await refresh()
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            appState.showToast("Sync failed: \(error.userMessage)", kind: .error)
        } catch {
            appState.showToast("Sync failed: the server did not answer.", kind: .error)
        }
    }

    /// bankSyncToast (filterState.mjs:449-463).
    static func syncToastText(_ out: PlaidSyncResult) -> String {
        var text = "Sync done: \(out.added) added, \(out.updated) updated, \(out.skipped) skipped across \(out.items) connected account(s)."
        if let removed = out.duplicateRemoved, !removed.isEmpty {
            text += " A duplicate bank connection was removed because those accounts are already connected on another connection. Past transactions stay."
        }
        if out.stale == true {
            let mins = out.minutesSincePreviousSync
            text += " Scheduled sync hadn't run in a while before this sync\(mins.map { " (\($0) minutes since the last one)" } ?? "")."
        }
        return text
    }

    // MARK: - Derived hero figures (display splits only)

    /// Effective weekly allowance = base room + temp (both server
    /// fields from compute-week).
    public var effectiveAllowanceCents: Int? {
        guard case .loaded(let result) = week else { return nil }
        return result.baseAvailableCents + result.tempCents
    }
}

// MARK: - Home view

public struct HomeView: View {
    @ObservedObject var appState: AppViewModel
    @StateObject private var viewModel: HomeViewModel
    @State private var showWeeklySheet = false
    @State private var showNotLoadedAlert = false
    @State private var notLoadedAlertTitle = "Weekly Budget"

    public init(appState: AppViewModel, householdId: UUID) {
        self.appState = appState
        self._viewModel = StateObject(wrappedValue: HomeViewModel(
            client: appState.client, appState: appState, householdId: householdId))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                charityCard
                fundCard
                recentSection
                footer
            }
            .padding(16)
        }
        .background(DesignTokens.background)
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
        .sheet(isPresented: $showWeeklySheet) {
            if case .loaded(let result) = viewModel.week {
                WeeklySheet(week: result, appState: appState)
            }
        }
        .alert(notLoadedAlertTitle, isPresented: $showNotLoadedAlert) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("\(notLoadedAlertTitle == "Weekly Budget" ? "Weekly numbers" : "\(notLoadedAlertTitle) balances") are not loaded yet. Try again in a moment.")
        }
    }

    // MARK: Hero — Weekly Budget

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weekly Budget")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            switch viewModel.week {
            case .loading:
                Text("Loading…")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#6b7280"))
                ProgressView()
            case .failed(let error):
                Text("Week numbers unavailable")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#6b7280"))
                ErrorBox(weekErrorText(error))
                Button("Try Again") { Task { await viewModel.refresh() } }
                    .buttonStyle(TertiaryButtonStyle())
            case .loaded(let result):
                heroLoaded(result)
            }
        }
        .padding(16)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(DesignTokens.primary, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // Hero exception: outline, NO shadow (styles.css:1127).
    }

    private func weekErrorText(_ error: OnBudgetError) -> String {
        switch error {
        case .networkOffline, .timedOut, .networkError:
            return "Couldn't update this week's numbers — check your connection and try again."
        default:
            return "Couldn't update this week's numbers — switch tabs or reopen the app to try again."
        }
    }

    @ViewBuilder
    private func heroLoaded(_ result: WeekResult) -> some View {
        Text(AppDates.weekLabel(weekStart: result.weekStart))
            .font(.system(size: 15))
            .foregroundStyle(Color(hex: "#6b7280"))

        // Big figure (tap target — opens the Weekly sheet).
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { showWeeklySheet = true } label: {
                heroFigure(cents: result.availableCents)
            }
            .accessibilityLabel(
                result.availableCents < 0
                    ? "Weekly Budget, over budget by \(MoneyFormat.string(cents: -result.availableCents)), show breakdown"
                    : "Weekly Budget, \(MoneyFormat.string(cents: result.availableCents)) left this week, show breakdown"
            )
            Spacer()
            // Sync button: admin-only; grey tertiary while no
            // allowance is set, so "Set Your Weekly Allowance" is
            // the hero's only primary control.
            if viewModel.isAdmin {
                Button { Task { await viewModel.syncBank() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            viewModel.allowanceSet == true
                                ? DesignTokens.primary : Color(hex: "#e5e7eb"))
                        .clipShape(Circle())
                        .rotationEffect(.degrees(viewModel.isSyncing ? 360 : 0))
                }
                .disabled(viewModel.isSyncing)
                .accessibilityLabel(viewModel.isSyncing ? "Syncing Bank" : "Sync Bank")
            }
        }

        // Progress bar: charges / capacity, capped at 100%; red
        // when charges exceed capacity.
        let capacity = result.baseAvailableCents + result.tempCents
        let fraction = capacity > 0 ? min(1, Double(result.chargesCents) / Double(capacity)) : 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: "#ececf1"))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(result.chargesCents > capacity ? DesignTokens.errorText : DesignTokens.primary)
                    .frame(width: geometry.size.width * fraction, height: 8)
            }
        }
        .frame(height: 8)

        // Spent line + % used. While no allowance is set both read —.
        HStack(spacing: 8) {
            if viewModel.allowanceSet == true {
                Text("\(MoneyFormat.string(cents: result.chargesCents)) spent")
                Text("·")
                Text(usedPercentText(result: result, capacity: capacity))
            } else {
                Text("— spent")
                Text("·")
                Text("—")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color(hex: "#6b7280"))

        // Hero stats row: Weekly allowance (effective) + Purchases.
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly Allowance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(viewModel.allowanceSet == true
                     ? MoneyFormat.string(cents: capacity)
                     : "—")
                    .font(.system(size: 17, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Purchases")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(viewModel.purchasesThisWeek.map(String.init) ?? "N/A")
                    .font(.system(size: 17, weight: .bold))
            }
        }

        // Set Your Weekly Allowance: admin only, never-set state.
        if viewModel.isAdmin, viewModel.allowanceSet == false {
            Button("Set Your Weekly Allowance") {
                appState.openSettings()
            }
            .buttonStyle(PrimaryButtonStyle())
        }

        // Empty hint: only once a load has actually returned empty,
        // never while loading or on failure.
        if viewModel.allowanceSet == true,
           (viewModel.purchasesThisWeek ?? 1) == 0, result.chargesCents == 0 {
            Text("No transactions this week yet — the full allowance is still available. Add one by hand, or connect a bank account in Settings.")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
        }
    }

    private func usedPercentText(result: WeekResult, capacity: Int) -> String {
        if result.chargesCents == 0 { return "0% used" }
        if capacity <= 0 { return "Over budget" }
        let percent = Int((Double(result.chargesCents) / Double(capacity) * 100).rounded())
        return percent > 100 ? "Over budget" : "\(percent)% used"
    }

    /// Hero big figure: dollars large, cents smaller
    /// (formatCentsHtml, live.js:3651-3659). Negative → red.
    private func heroFigure(cents: Int) -> some View {
        let parts = MoneyFormat.parts(cents: cents)
        return (Text(parts.sign + "$" + parts.dollars)
            .font(.system(size: 36, weight: .heavy))
            + Text("." + parts.cents)
            .font(.system(size: 20, weight: .heavy)))
            .foregroundStyle(cents < 0 ? DesignTokens.errorText : DesignTokens.ink)
    }

    // MARK: Stat cards — Charity above Extra Fund

    private var charityCard: some View {
        statCard(
            title: "Charity",
            face: charityFaceText,
            isExpanded: appState.expandedCard == .charity,
            ariaLabel: charityAriaLabel,
            onTap: {
                guard case .loaded = viewModel.charity else {
                    notLoadedAlertTitle = "Charity"
                    showNotLoadedAlert = true
                    return
                }
                withAnimation {
                    appState.expandedCard = appState.expandedCard == .charity ? nil : .charity
                }
            }
        ) {
            if case .loaded(let summary) = viewModel.charity {
                statRow(label: "Available", value: MoneyFormat.signedString(cents: summary.remainingCents))
                statRow(label: "Given", value: MoneyFormat.string(cents: summary.givenCents))
                statRow(label: "Total", value: MoneyFormat.string(cents: summary.committedCents))
                Text("November 2026 onward")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
    }

    private var fundCard: some View {
        statCard(
            title: "Extra Fund",
            face: fundFaceText,
            isExpanded: appState.expandedCard == .fund,
            ariaLabel: fundAriaLabel,
            onTap: {
                guard case .loaded = viewModel.fund else {
                    notLoadedAlertTitle = "Extra Fund"
                    showNotLoadedAlert = true
                    return
                }
                withAnimation {
                    appState.expandedCard = appState.expandedCard == .fund ? nil : .fund
                }
            }
        ) {
            if case .loaded(let summary) = viewModel.fund {
                // Home expansions show rows only, no action buttons.
                // Row labels are the web's exact wording
                // (live.js:3604): "Spendable available" (admin) /
                // "Available to request" (member).
                statRow(
                    label: viewModel.isAdmin ? "Spendable available" : "Available to request",
                    value: MoneyFormat.signedString(cents: summary.availableCents))
                statRow(label: "Pending", value: MoneyFormat.string(cents: summary.pendingIncludingHeldCents))
                statRow(label: "Total", value: MoneyFormat.string(cents: summary.totalCents))
            }
        }
    }

    /// A stat card face is Title + signed number only, chevron ⌄
    /// bottom-right (flips to ⌃ when expanded). Tap anywhere
    /// expands it in place; tap again, or the other card, collapses.
    private func statCard<Rows: View>(
        title: String,
        face: String,
        isExpanded: Bool,
        ariaLabel: String,
        onTap: @escaping () -> Void,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(DesignTokens.ink)
                        Text(face)
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(DesignTokens.ink)
                    }
                    Spacer()
                }
                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) { rows() }
                        .padding(.top, 4)
                }
                HStack {
                    Spacer()
                    Text(isExpanded ? "⌃" : "⌄")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DesignTokens.primary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                    radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ariaLabel)
    }

    /// Row labels are the web's exact wording (live.js:3560-3600),
    /// not Title Case — Title Case applies to headings and button
    /// labels, not these rows.
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
        }
    }

    private var charityFaceText: String {
        switch viewModel.charity {
        case .loaded(let summary): return MoneyFormat.signedString(cents: summary.remainingCents)
        case .failed: return "—"
        case .loading: return "—"
        }
    }

    private var fundFaceText: String {
        switch viewModel.fund {
        case .loaded(let summary): return MoneyFormat.signedString(cents: summary.availableCents)
        case .failed: return "—"
        case .loading: return "—"
        }
    }

    private var charityAriaLabel: String {
        switch viewModel.charity {
        case .loaded(let summary):
            if summary.committedCents == 0 && summary.givenCents == 0 {
                return "Charity, no charity tracked yet, show breakdown"
            }
            if summary.remainingCents < 0 {
                return "Charity, ahead by \(MoneyFormat.string(cents: -summary.remainingCents)), show breakdown"
            }
            return "Charity, \(MoneyFormat.string(cents: summary.remainingCents)) remaining, \(MoneyFormat.string(cents: summary.givenCents)) given, \(MoneyFormat.string(cents: summary.committedCents)) committed, show breakdown"
        case .failed:
            return "Charity, could not load, show breakdown"
        case .loading:
            return "Charity, loading, show breakdown"
        }
    }

    private var fundAriaLabel: String {
        switch viewModel.fund {
        case .loaded(let summary):
            if summary.pendingIncludingHeldCents > 0 {
                return "Extra Fund, \(MoneyFormat.string(cents: summary.availableCents)) available, \(MoneyFormat.string(cents: summary.pendingIncludingHeldCents)) pending, show breakdown"
            }
            return "Extra Fund, \(MoneyFormat.string(cents: summary.availableCents)) available, show breakdown"
        case .failed:
            return "Extra Fund, could not load balances, show breakdown"
        case .loading:
            return "Extra Fund, loading, show breakdown"
        }
    }

    // MARK: Recent transactions

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Transactions")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Button("See All") { appState.selectedTab = .transactions }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
            switch viewModel.recent {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            case .failed(let error):
                if error == .sessionExpired {
                    ErrorBox("Your sign-in expired — sign in again to see transactions.")
                    Button("Sign In Again") { appState.showSessionExpired() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    ErrorBox("Could not load recent transactions.")
                    Button("Try Again") { Task { await viewModel.refresh() } }
                        .buttonStyle(TertiaryButtonStyle())
                }
            case .loaded(let rows):
                if rows.isEmpty {
                    Text("No transactions yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "#6b7280"))
                } else {
                    ForEach(rows) { row in
                        recentRow(row)
                    }
                }
            }
        }
    }

    private func recentRow(_ row: Transaction) -> some View {
        Button {
            // Tapping a row jumps to Transactions and expands that
            // row's detail (filters/search cleared first, by the
            // Transactions screen when it consumes the jump). If the
            // row is not in the loaded page, that screen toasts:
            // "That transaction is not in the loaded list — tap Load
            // more for older ones."
            appState.jumpToTransaction(row.id)
        } label: {
            HStack(spacing: 12) {
                TransactionIconView(
                    merchant: row.merchant,
                    institutionName: row.cardSuffix == "0000"
                        ? nil : viewModel.institutionBySuffix[row.cardSuffix])
                VStack(alignment: .leading, spacing: 2) {
                    Text(TitleCase.apply(to: row.merchant.lowercased()))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DesignTokens.ink)
                    HStack(spacing: 6) {
                        StatePill(label: stateLabel(row))
                        Text("\(AppDates.relativeDay(row.date)) · \(cardLabel(row))")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                }
                Spacer()
                Text(MoneyFormat.signedString(cents: row.amountCents))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(row.amountCents < 0 ? DesignTokens.errorText : DesignTokens.ink)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func stateLabel(_ row: Transaction) -> String {
        if row.isInTrash { return "Excluded" }
        switch row.state {
        case .provisional: return "Pending"
        case .verified: return "Posted"
        case .reversed: return "Reversed"
        case .excluded: return "Excluded"
        }
    }

    private func cardLabel(_ row: Transaction) -> String {
        row.cardSuffix == "0000" ? "Cash / no card" : "••\(row.cardSuffix)"
    }

    // MARK: Footer

    /// "OnBudget · Last bank sync …" sits directly under the last
    /// card (live.html:560-562). "Last synced" itself is shown once,
    /// quietly, under Automatic Sync in Settings; Home carries the
    /// same stamp here.
    private var footer: some View {
        Text("OnBudget · Last bank sync \(viewModel.lastSyncText.map { $0.replacingOccurrences(of: "Last synced ", with: "") } ?? "—")")
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: "#6b7280"))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }
}

// MARK: - Weekly sheet

/// Weekly sheet (CLONE_SPEC §14, live.js:3457-3500). Opened by
/// tapping the hero number. Rows, exactly three, in order:
/// Allowance (= base room + temp) / Spent (server charges_cents) /
/// Balance (available_cents). Fourth row only when non-zero:
/// Unlinked refunds. Message: "Pending transactions are included
/// and marked." (+ the unlinked sentence when the 4th row is
/// present). Show Transactions (primary) + Close (tertiary) —
/// two-button sheet rule.
public struct WeeklySheet: View {
    let week: WeekResult
    @ObservedObject var appState: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init(week: WeekResult, appState: AppViewModel) {
        self.week = week
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
                Spacer()
                Text("Weekly Budget")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Color.clear.frame(width: 50)
            }
            Text("Pending transactions are included and marked.\(week.unlinkedExcessCents != 0 ? " Unlinked refunds above this week's spending are not counted here." : "")")
                .font(.system(size: 15))
            sheetRow(label: "Allowance", value: MoneyFormat.string(cents: week.baseAvailableCents + week.tempCents))
            sheetRow(label: "Spent", value: MoneyFormat.string(cents: week.chargesCents))
            sheetRow(label: "Balance", value: MoneyFormat.string(cents: week.availableCents))
            if week.unlinkedExcessCents != 0 {
                sheetRow(label: "Unlinked refunds", value: MoneyFormat.string(cents: week.unlinkedExcessCents))
            }
            HStack(spacing: 12) {
                Button("Show Transactions") {
                    dismiss()
                    appState.showTransactionsForWeek(week.weekStart)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Close") { dismiss() }
                    .buttonStyle(TertiaryButtonStyle())
            }
            Spacer()
        }
        .padding(20)
    }

    private func sheetRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
    }
}
