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
// Hero: white card, 3px #2f6bff outline, no shadow. Sync button
// is primary blue when allowance set, grey tertiary until set;
// "Set Your Weekly Allowance" (admin only) when none set. Purchases
// shows "N/A" — never a bare dash — when transactions fail to load.
// Fund + Charity cards: stacked, Charity above Extra Fund, both
// full-width, expand downward IN PLACE, one-open-at-a-time, with
// the expand detail (Available / Pending / Total) and NO action
// buttons on Home (actions belong on the Funds page). Both cards
// are BIGGER and outlined (owner, Nov 12, 2026, corrected ~2:02 PM
// the same day — NOT a wash: Charity green #16a34a outline, Extra
// Fund amber #d97706 outline, both 2px, white inside like the
// hero, shared StatCardTheme with the Funds page); the Weekly
// Budget hero above them keeps its thicker 3px outline.
// "Last synced" is shown once, quietly, under Automatic Sync in
// Settings (ConnectedAccountsView); Home carries NO sync line
// (owner, Nov 11, 2026 — removed from Home entirely).
//
// Clone basis: live web v66.

import SwiftUI
import WidgetKit
import OnBudgetKit

// MARK: - Section load state

/// Loading, then data or a REAL error — never an endless spinner
/// (the web app has a live "Loading…" hang; the clone must not
/// copy it).
public enum HomeSectionState<Value> {
    case loading
    case loaded(Value)
    case failed(OnBudgetError)

    /// True only for the failed state (used for the red "could not
    /// load" status line on the stat cards).
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// True only while loading (the card shows its shimmer skeleton).
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - View model

@MainActor
public final class HomeViewModel: ObservableObject {

    private let client: SupabaseClient
    private let appState: AppViewModel
    private let householdId: UUID

    @Published public var week: HomeSectionState<WeekResult> = .loading
    @Published public var allowanceSet: Bool?
    /// The stored base allowance in cents (from the household row) —
    /// the Weekly sheet needs it to explain an override week (the
    /// temporary increase/decrease is override minus base, live.js
    /// v69). Nil when the household read failed, so the sheet shows
    /// no Base row and no override line, exactly as the web.
    @Published public var allowanceCents: Int?
    /// The household-read failure, when that read failed (audit
    /// H-P1-4): the hero shows this with a retry instead of silently
    /// blanking numbers compute-week already returned. Nil on a
    /// successful read.
    @Published public var allowanceError: OnBudgetError?
    @Published public var fund: HomeSectionState<FundSummary> = .loading
    @Published public var charity: HomeSectionState<CharitySummary> = .loading
    @Published public var recent: HomeSectionState<[Transaction]> = .loading
    /// Purchases this week; nil when transactions failed to load,
    /// so the hero shows "N/A" (never a bare dash).
    @Published public var purchasesThisWeek: Int?
    /// Week-counted charges, for the empty-week hint.
    @Published public var hasWeekTransactions = false
    @Published public var isSyncing = false
    /// Card suffix → institution name (best-effort, for bank icons).
    @Published public var institutionBySuffix: [String: String] = [:]

    /// The in-flight refresh, if any — so a second caller (Home
    /// appearing while the boot preload is still running) awaits
    /// the same load instead of starting a second one. Cleared
    /// when the load finishes.
    private var refreshTask: Task<Void, Never>?

    /// True once the dashboard has loaded (or failed) — every
    /// section has left the initial `.loading` state. The boot
    /// preload uses it to know when Home is ready to show.
    public var isLoaded: Bool {
        !week.isLoading && !recent.isLoading && !fund.isLoading && !charity.isLoading
    }

    public init(client: SupabaseClient, appState: AppViewModel, householdId: UUID) {
        self.client = client
        self.appState = appState
        self.householdId = householdId
    }

    public var isAdmin: Bool { appState.isAdmin }

    /// Force a refresh (pull-to-refresh, retry, sync,
    /// Settings-close, boot preload). Coalesces: if a refresh is
    /// already running, awaits it instead of starting a second one.
    public func refresh() async {
        if let task = refreshTask {
            await task.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Load only if the dashboard is not already loaded (and not
    /// already loading). The boot preload starts the load while the
    /// loading screen shows; Home appearing later reuses it instead
    /// of re-fetching and re-showing skeletons. A failed load stays
    /// failed until an explicit refresh.
    public func refreshIfNeeded() async {
        if refreshTask != nil {
            await refresh()
            return
        }
        guard !isLoaded else { return }
        await refresh()
    }

    /// The actual load (live.js refresh() order, Home subset):
    /// compute-week (+ admin week-close once per session), allowance
    /// flag, transactions page, fund ledger + releases, charity
    /// income + settings, Plaid institutions + masks for the
    /// last-sync stamp. Called by `refresh()` (which coalesces
    /// concurrent callers onto one in-flight load).
    ///
    /// SPEED (owner, Nov 15, 2026): the sections used to await one
    /// after another — ~8–9 sequential round trips, so Home took
    /// seconds to load. The fetches are independent (only the
    /// client-side derivations need each other's results), so they
    /// now all start together and the load takes roughly the
    /// slowest single call. Each fetch is its own Task so one
    /// failure never cancels the others; every section still fails
    /// independently with its own error state. The redundant
    /// `plaidItems` fetch is gone — its result was never used (the
    /// icon map only needs institutions + masks).
    private func performRefresh() async {
        week = .loading
        fund = .loading
        charity = .loading
        recent = .loading

        // Kick off every independent fetch at once. The tasks only
        // fetch and return; the section assignments below are the
        // only writes to this view model.
        let weekTask = Task<WeekResult, Error> {
            var result = try await client.functions.computeWeek(householdId: householdId)
            if await appState.runWeekCloseIfDue() {
                result = try await client.functions.computeWeek(householdId: householdId)
            }
            return result
        }
        let allowanceTask = Task<(baseAllowanceCents: Int?, allowanceExplicitlySet: Bool), Error> {
            try await client.postgrest.householdAllowance(householdId: householdId)
        }
        let txTask = Task<([Transaction], Bool), Error> {
            try await client.postgrest.transactionsPage(householdId: householdId)
        }
        let charityIncomeTask = Task<[CharityIncome], Error> {
            try await client.postgrest.activeCharityIncome(householdId: householdId)
        }
        let charitySettingsTask = Task<CharitySettings?, Error> {
            try await client.postgrest.charitySettings(householdId: householdId)
        }
        let fundLedgerTask = Task<[FundLedgerEntry], Error> {
            try await client.postgrest.fundLedger(householdId: householdId)
        }
        let fundReleasesTask = Task<[SurplusRelease], Error> {
            try await client.postgrest.surplusReleases(householdId: householdId)
        }
        let fundShortfallTask = Task<Int, Error> {
            try await client.postgrest.fundShortfallCents(householdId: householdId)
        }
        let plaidTask = Task<[String: String], Error> {
            // Suffix → institution map for bank icons (best-effort).
            // Masks need the item ids, so institutions then masks
            // stay sequential inside this one task.
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
            return map
        }

        // Week numbers — everything else keys off the week.
        var weekStart: String?
        do {
            let result = try await weekTask.value
            week = .loaded(result)
            weekStart = result.weekStart
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            week = .failed(error)
        } catch {
            week = .failed(.unknown("Could not load this week's numbers."))
        }

        // Allowance-set flag ($375 is the schema default, not a
        // choice — allowanceSetAt == nil means never set). The stored
        // base travels with it for the Weekly sheet's reconciliation
        // rows; both clear together when the household read fails so
        // a stale base can never explain a fresh week.
        do {
            let allowance = try await allowanceTask.value
            allowanceSet = allowance.allowanceExplicitlySet
            allowanceCents = allowance.baseAllowanceCents
            allowanceError = nil
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            allowanceSet = nil
            allowanceCents = nil
            allowanceError = error
        } catch {
            allowanceSet = nil
            allowanceCents = nil
            allowanceError = .unknown("Could not load your allowance setting.")
        }

        // Transactions page: recent 6, purchases count, charity
        // gifts. A failure here is an error state, never a silent
        // empty list. The charity summary is derived from the same
        // rows + the concurrently fetched income and settings.
        var charityRows: [Transaction] = []
        do {
            let (rows, _) = try await txTask.value
            let visible = rows.filter { !$0.isInTrash }
            recent = .loaded(Array(visible.prefix(6)))
            if let weekStart {
                let weekRows = visible.filter { AppDates.isInWeek($0.date, weekStart: weekStart) }
                // Transfers never count as purchases (owner, Nov 14,
                // 2026): countsAsPurchase is kind-based — only a
                // charge that is not reversed. The hero's spent
                // figure comes from compute-week, which excludes
                // kind='transfer' the same way (engine.mjs
                // isExcludedFromMath), so the two numbers agree.
                purchasesThisWeek = weekRows.filter(\.countsAsPurchase).count
                hasWeekTransactions = !weekRows.isEmpty
            } else {
                purchasesThisWeek = nil
            }
            charityRows = visible.filter { $0.kind == .charity }
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

        // Charity summary (only when the transactions load above
        // succeeded — a failed transactions load already failed the
        // charity section with it, as before).
        if case .loaded = recent {
            do {
                let income = try await charityIncomeTask.value
                let settings = try await charitySettingsTask.value
                let summary = CharitySummary.compute(
                    activeIncome: income,
                    charityTransactions: charityRows,
                    defaultRateBp: settings?.defaultRateBp ?? 1000)
                charity = .loaded(summary)
            } catch let error as OnBudgetError {
                if error == .sessionExpired { appState.showSessionExpired(); return }
                charity = .failed(error)
            } catch {
                charity = .failed(.unknown("Could not load charity."))
            }
        }

        // Extra Fund display aggregation (sums over server rows).
        do {
            let summary = FundSummary.compute(
                ledger: try await fundLedgerTask.value,
                releases: try await fundReleasesTask.value,
                shortfallCents: try await fundShortfallTask.value)
            fund = .loaded(summary)
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            fund = .failed(error)
        } catch {
            fund = .failed(.unknown("Could not load Extra Fund balances."))
        }

        // Plaid suffix → institution map (bank icons). Best-effort —
        // never blocks Home. No sync stamp is kept here: the sync
        // line lives in Settings only.
        do {
            institutionBySuffix = try await plaidTask.value
        } catch {
            // Best-effort only: no stamp, no error state.
        }

        // Widget snapshot (build 17): the two numbers the Home-screen
        // widget shows — the same figures as the hero and Charity
        // cards. Written only when BOTH loads succeeded; a failed load
        // writes nothing, so the previous snapshot goes stale instead
        // of being overwritten with a partial one. The widget reloads
        // its timeline from this write; a bank sync refreshes Home
        // too, so a sync updates the widget as well.
        if case .loaded(let result) = week,
           case .loaded(let summary) = charity {
            WidgetSnapshotStore.write(WidgetSnapshot(
                weekStart: result.weekStart,
                availableCents: result.availableCents,
                charityRemainingCents: summary.remainingCents,
                spentCents: result.chargesCents,
                charityGivenCents: summary.givenCents,
                charityCommittedCents: summary.committedCents,
                computedAt: Date()))
            WidgetCenter.shared.reloadAllTimelines()
        }
    }


    // MARK: - Bank sync

    /// Home sync button (live.js:2842-2876, runBankSync): admin
    /// only, one sync at a time, spins while syncing. The toast
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
                // Lead with the failure (audit H-P2-7): the old text
                // opened "Sync done:" and never said what failed.
                // The counts still follow, so the partial progress
                // is not lost.
                appState.showToast(
                    "Couldn't sync \(partial.failedInstitutions.joined(separator: ", ")): \(partial.result.added) added, \(partial.result.updated) updated, \(partial.result.skipped) skipped across \(partial.result.items) connected account(s).",
                    kind: .error)
            }
            await refresh()
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            appState.showToast("Sync failed: \(error.displayMessage)", kind: .error)
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
    /// Owned by AppState (created at boot so the dashboard can be
    /// preloaded behind the loading screen); Home only observes
    /// it. Falls back to a fresh one if AppState has none yet.
    @ObservedObject var viewModel: HomeViewModel
    @State private var showWeeklySheet = false
    @State private var showNotLoadedAlert = false
    @State private var notLoadedAlertTitle = "Weekly Budget"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// iPad (regular size class): the Home figures scale up
    /// (owner, Nov 15, 2026 — the hero and stat-card amounts +
    /// icons were still too small on iPad). iPhone is untouched.
    private var isIPad: Bool { horizontalSizeClass == .regular }

    public init(appState: AppViewModel, householdId: UUID) {
        self.appState = appState
        self.viewModel = appState.homeViewModel ?? HomeViewModel(
            client: appState.client, appState: appState, householdId: householdId)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                // Charity + Extra Fund share one row, half-width
                // each (owner, Nov 14, 2026 — supersedes the Nov 12
                // bigger full-width stacked cards). The expanded
                // detail drops below the row, full width; one card
                // open at a time (accordion rule unchanged).
                HStack(alignment: .top, spacing: 12) {
                    charityCard
                    fundCard
                }
                if appState.expandedCard == .charity {
                    statDetailCard(theme: .charity, onTap: {
                        appState.expandedCard = nil
                    }) { charityRows }
                }
                if appState.expandedCard == .fund {
                    statDetailCard(theme: .fund, onTap: {
                        appState.expandedCard = nil
                    }) { fundRows }
                }
                recentSection
                    // Breathing room (owner, Nov 12 2026): the section
                    // sat too tight under the Extra Fund card — 8pt
                    // extra on top of the 16pt stack gap.
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(DesignTokens.background)
        .task { await viewModel.refreshIfNeeded() }
        .refreshable { await viewModel.refresh() }
        // Settings dismiss (audit H-P1-5): the Settings cover sits
        // over this tab and never re-ran the load, so a just-set
        // allowance still showed the old state. Refresh when the
        // cover closes; opening it changes nothing.
        .onChange(of: appState.showSettings) { _, isShowing in
            if !isShowing { Task { await viewModel.refresh() } }
        }
        .sheet(isPresented: $showWeeklySheet) {
            if case .loaded(let result) = viewModel.week {
                WeeklySheet(week: result, baseAllowanceCents: viewModel.allowanceCents, purchasesThisWeek: viewModel.purchasesThisWeek, appState: appState)
                    // iPad width (owner, Nov 12 2026): a plain .sheet
                    // is a ~540pt form sheet on iPad — narrow and
                    // cramped for this content. .fitted sizes the
                    // sheet to the content, and WeeklySheet fixes its
                    // width to 600pt in the regular size class, so the
                    // sheet opens 600pt wide and centred; on iPhone
                    // (compact) the width stays full-screen and only
                    // the height hugs the content.
                    .presentationSizing(.fitted)
                    .presentationBackground(.white)
            }
        }
        .alert(notLoadedAlertTitle, isPresented: $showNotLoadedAlert) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("\(notLoadedAlertTitle == "Weekly Budget" ? "Weekly numbers" : "\(notLoadedAlertTitle) balances") are not loaded yet. Try again in a moment.")
        }
    }

    // MARK: Hero — Weekly Budget

    // Hero — Weekly Budget. Bigger and more prominent than the
    // other cards (owner, Nov 11, 2026: it is the most important
    // number on the page). The loading state renders at the same
    // full hero size (shimmer skeleton blocks, no spinner), so the
    // layout never jumps when the number arrives. The hero outline
    // is the thickest on the page (3px, owner Nov 14, 2026 — was
    // 2.5px since Nov 12, 2026, 1.5px before that), so it stays the
    // anchor card above the 2px-outlined Charity / Extra Fund cards
    // below it.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroHeaderRow
            switch viewModel.week {
            case .loading:
                heroSkeleton
            case .failed(let error):
                // One failure message only: the ErrorBox. The grey
                // "Could not load…" line above it said the same
                // thing twice (audit H-P2-4).
                ErrorBox(weekErrorText(error))
                Button("Try Again") { Task { await viewModel.refresh() } }
                    .buttonStyle(TertiaryButtonStyle())
            case .loaded(let result):
                heroLoaded(result)
            }
        }
        .padding(20)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(DesignTokens.primary, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
        // Whole-card tap target (owner, Nov 15, 2026 app-wide
        // pass): the whole hero opens the Weekly sheet, not just
        // the figure row — the header and the empty space respond
        // too. The sync button (and Try Again while failed) still
        // win: a Button inside beats the parent tap gesture.
        // Loading or failed weeks open nothing — the sheet needs a
        // loaded week.
        .onTapGesture {
            if case .loaded = viewModel.week {
                showWeeklySheet = true
            }
        }
        .accessibilityIdentifier("home.weeklyBudget")
        // Hero exception: outline, NO shadow (styles.css:1127).
    }

    // Hero header — the same style as the Charity / Extra Fund
    // cards (owner, Nov 14, 2026): icon chip + title in ONE row,
    // with the sync button at the trailing end — the top-right
    // corner of the card. The title is "Spending" and there is NO
    // date anywhere on the card (owner, Nov 14, 2026 — this
    // supersedes the inline-date "Weekly Budget · Nov 8" from
    // earlier the same day; the date lived only in the Weekly
    // sheet now). The title is 18pt bold like the stat cards
    // (was 24pt on its own line); the hero stays the anchor by
    // its 3px outline and the big figure below. While loading
    // the sync spot holds a skeleton block so the header never
    // jumps when the numbers arrive.
    private var heroHeaderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .semibold))
                // Owner, Nov 14, 2026 ("too much colors"): the
                // hero icon is neutral ink, and its chip ring is a
                // plain light grey — no blue anywhere on the card
                // except the sync button and the 3px outline.
                .foregroundStyle(DesignTokens.ink)
                .frame(width: 36, height: 36)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                )
            Text("Spending")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
            Spacer()
            if viewModel.isAdmin {
                switch viewModel.week {
                case .loading:
                    SkeletonBlock(width: 44, height: 44, cornerRadius: 22)
                case .loaded:
                    syncButton
                case .failed:
                    EmptyView()
                }
            }
        }
    }

    /// Sync button: admin-only; grey tertiary while no allowance
    /// is set, so "Set Your Weekly Allowance" is the hero's only
    /// primary control. The fill is the lighter blue #3b82f6
    /// (DesignTokens.mid), not the primary #2f6bff — same condition
    /// as the Transactions sync button (owner, Nov 12 ~10:29 PM).
    /// Moved here from the figure row (owner, Nov 14, 2026: the
    /// top-right corner of the card, not mid-right over the
    /// progress bar).
    private var syncButton: some View {
        Button { Task { await viewModel.syncBank() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .semibold))
                // White icon on the blue state; dark ink on the
                // grey state — white-on-grey was ~1.1:1 and
                // effectively invisible (audit H-P1-1).
                .foregroundStyle(viewModel.allowanceSet == true ? .white : DesignTokens.ink)
                .frame(width: 44, height: 44)
                .background(
                    viewModel.allowanceSet == true
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

    /// Full-size hero skeleton: same frame, padding, rows and
    /// spacing as the loaded hero, with shimmer blocks where the
    /// figure, progress bar, spent line and stats go — the same
    /// rows as heroLoaded, in the same order, and no extra row the
    /// loaded hero lacks — so the page never jumps when the numbers
    /// arrive (audit H-P2-5). The header row itself is real even
    /// while loading (icon + title, with a skeleton block in the
    /// sync spot for admins), so the skeleton starts at the figure.
    /// Full-width bars (owner, Nov 15, 2026: the shorter lines
    /// stopped well short of the right edge — every bar now runs
    /// edge-to-edge within the card padding). Heights still match
    /// the loaded rows, so the card holds its size while loading.
    /// Verified against heroLoaded, Nov 14 2026: figure / progress
    /// bar / spent line, all present, all the same sizes. (The
    /// stats row — Weekly Allowance + Purchases — moved into the
    /// Weekly sheet, owner Nov 14, 2026, so it has no skeleton
    /// block here.)
    private var heroSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Figure block, full width, same height as the loaded
            // figure — 72 on iPad for the bigger 58pt figure,
            // 56 on iPhone.
            SkeletonBlock(height: isIPad ? 72 : 56, cornerRadius: 8)
            SkeletonBlock(height: 8, cornerRadius: 4)
            SkeletonBlock(height: 14)
            // Carried Debt fund (build 29): the debt math line sits
            // under the spent line in heroLoaded, so its skeleton
            // block goes here — same order, so the page never jumps
            // when the numbers arrive (audit H-P2-5). The owner's
            // week carries debt, so his loading state shows it.
            SkeletonBlock(height: 14)
        }
        .accessibilityLabel("Spending, loading")
    }

    private func weekErrorText(_ error: OnBudgetError) -> String {
        switch error {
        case .networkOffline, .timedOut, .networkError:
            return "Couldn't update this week's numbers — check your connection and try again."
        default:
            return "Couldn't update this week's numbers — tap Try Again to reload."
        }
    }

    @ViewBuilder
    private func heroLoaded(_ result: WeekResult) -> some View {
        // Big figure — the whole figure row opens the Weekly sheet.
        // The sync button lives in the header row now (owner,
        // Nov 14, 2026); the date is gone from the card entirely,
        // and the Weekly Allowance + Purchases stats moved into
        // the Weekly sheet (owner, Nov 14, 2026).
        Button { showWeeklySheet = true } label: {
            heroFigure(cents: result.availableCents)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(
            result.availableCents < 0
                ? "Spending, over budget by \(MoneyFormat.string(cents: -result.availableCents)), show breakdown"
                : "Spending, \(MoneyFormat.string(cents: result.availableCents)) left this week, show breakdown"
        )

        // Progress bar: charges / capacity, capped at 100%; red
        // when charges exceed capacity. Over budget the fill is
        // full-width red — a zero/negative capacity used to force
        // the fraction to 0, so the bar was an empty grey track
        // exactly when over budget (audit H-P2-6).
        let capacity = result.baseAvailableCents + result.tempCents
        let overBudget = result.chargesCents > capacity
        let fraction = overBudget ? 1 : (capacity > 0 ? Double(result.chargesCents) / Double(capacity) : 0)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: "#ececf1"))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    // Owner, Nov 14, 2026 ("too much colors"): the
                    // over-budget bar is the muted hero red, not
                    // the bright error red.
                    .fill(overBudget ? DesignTokens.heroOverBudget : DesignTokens.primary)
                    .frame(width: geometry.size.width * fraction, height: 8)
            }
        }
        .frame(height: 8)

        // Spent line + % used. While no allowance is set the line
        // reads "Not set" in muted regular type — a genuinely unset
        // value, never a bare dash (owner loading/empty language,
        // Nov 12, 2026). A failed allowance read (nil) still shows
        // compute-week's numbers — only an explicit never-set hides
        // them (audit H-P1-4).
        HStack(spacing: 8) {
            if viewModel.allowanceSet != false {
                Text("\(MoneyFormat.string(cents: result.chargesCents)) spent")
                Text("·")
                Text(usedPercentText(result: result, capacity: capacity))
            } else {
                Text("Not set")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color(hex: "#6b7280"))

        // Carried Debt fund (build 29): the week explains itself —
        // "Base $400.00 − Debt $100.00 = $300.00" — so the user
        // always sees WHY the week starts where it does (closes the
        // R6 P1-1 Home-side gap: Home used to show $0 with no
        // reason). Nil on the old server or when nothing was paid
        // this week, so the line appears exactly when it changes
        // the number.
        if let mathLine = result.debtMathLine(baseAllowanceCents: viewModel.allowanceCents) {
            Text(mathLine)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#6b7280"))
        }

        // Allowance-read failure (audit H-P1-4): the hero numbers
        // above already come from compute-week, so this is an error
        // line + retry, not a blank. The "Set Your Weekly Allowance"
        // button below stays gated on an explicit never-set, so a
        // mere read failure never hides it.
        if let allowanceError = viewModel.allowanceError {
            ErrorBox("Couldn't load your allowance setting — \(allowanceError.displayMessage)")
            Button("Try Again") { Task { await viewModel.refresh() } }
                .buttonStyle(TertiaryButtonStyle())
        }

        // Set Your Weekly Allowance: admin only, never-set state.
        // Lands on the Funds page's Spending fund (build 30 — the
        // Budget card moved out of Settings; owner decision #27,
        // re-pointed).
        if viewModel.isAdmin, viewModel.allowanceSet == false {
            Button("Set Your Weekly Allowance") {
                appState.openSpendingFund()
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
    /// (formatCentsHtml, live.js:3651-3659). Negative → the muted
    /// hero red (owner, Nov 14, 2026: the bright error red was
    /// too stark — "too much colors"). iPad (owner, Nov 15, 2026):
    /// materially bigger — 58pt dollars / 32pt cents, where iPhone
    /// stays 44pt / 24pt.
    private func heroFigure(cents: Int) -> some View {
        let parts = MoneyFormat.parts(cents: cents)
        return (Text(parts.sign + "$" + parts.dollars)
            .font(.system(size: isIPad ? 58 : 44, weight: .heavy))
            + Text("." + parts.cents)
            .font(.system(size: isIPad ? 32 : 24, weight: .heavy)))
            .foregroundStyle(cents < 0 ? DesignTokens.heroOverBudget : DesignTokens.ink)
    }

    // MARK: Stat cards — Charity + Extra Fund, half-size side by side

    private var charityCard: some View {
        statCard(
            title: "Charity",
            face: charityFaceText,
            theme: .charity,
            isLoading: viewModel.charity.isLoading,
            statusText: charityStatusText,
            statusIsError: viewModel.charity.isFailed,
            isExpanded: appState.expandedCard == .charity,
            ariaLabel: charityAriaLabel,
            compact: true,
            onTap: {
                switch viewModel.charity {
                case .loading:
                    notLoadedAlertTitle = "Charity"
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    // Failed cards expand too, so the error + Retry
                    // are reachable; loading still shows the alert.
                    appState.expandedCard = appState.expandedCard == .charity ? nil : .charity
                }
            }
        )
    }

    /// Charity detail rows, rendered full-width below the
    /// half-size row when the Charity card is expanded.
    private var charityRows: some View {
        Group {
            if case .failed = viewModel.charity {
                ErrorBox("Could not load charity.")
                Button("Try Again") { Task { await viewModel.refresh() } }
                    .buttonStyle(TertiaryButtonStyle())
            } else if case .loaded(let summary) = viewModel.charity {
                statRow(label: "Available", value: MoneyFormat.signedString(cents: summary.remainingCents))
                statRow(label: "Given", value: MoneyFormat.string(cents: summary.givenCents))
                statRow(label: "Total", value: MoneyFormat.string(cents: summary.committedCents))
            }
        }
    }

    private var fundCard: some View {
        statCard(
            title: "Extra Fund",
            face: fundFaceText,
            theme: .fund,
            isLoading: viewModel.fund.isLoading,
            statusText: fundStatusText,
            statusIsError: viewModel.fund.isFailed,
            isExpanded: appState.expandedCard == .fund,
            ariaLabel: fundAriaLabel,
            compact: true,
            onTap: {
                switch viewModel.fund {
                case .loading:
                    notLoadedAlertTitle = "Extra Fund"
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    appState.expandedCard = appState.expandedCard == .fund ? nil : .fund
                }
            }
        )
    }

    /// Extra Fund detail rows, rendered full-width below the
    /// half-size row when the Extra Fund card is expanded.
    private var fundRows: some View {
        Group {
            if case .failed = viewModel.fund {
                ErrorBox("Could not load Extra Fund balances.")
                Button("Try Again") { Task { await viewModel.refresh() } }
                    .buttonStyle(TertiaryButtonStyle())
            } else if case .loaded(let summary) = viewModel.fund {
                // Home expansions show rows only, no action buttons.
                // Row labels are Title Case (owner rule, Nov 4, 2026):
                // "Spendable Available" (admin) / "Available to
                // Request" (member). The in-code web-parity exemption
                // for these rows was wrong and is removed (audit
                // H-P2-1).
                statRow(
                    label: viewModel.isAdmin ? "Spendable Available" : "Available to Request",
                    value: MoneyFormat.signedString(cents: summary.availableCents))
                statRow(label: "Pending", value: MoneyFormat.string(cents: summary.pendingIncludingHeldCents))
                statRow(label: "Total", value: MoneyFormat.string(cents: summary.totalCents))
            }
        }
    }

    /// A stat card face: icon chip + Title, then the amount in
    /// 28pt heavy in the card's deep tint colour, chevron
    /// bottom-right (SF Symbol chevron.down, down when collapsed,
    /// up when expanded — it flips instantly, no rotation
    /// animation: expand/collapse is instant since build 34,
    /// owner decision Nov 15, 2026). Bigger and outlined (owner, Nov 12, 2026,
    /// corrected ~2:02 PM — StatCardTheme, shared with the Funds
    /// page): 20pt padding, 18pt title, 28pt amount, icon chip;
    /// white inside with a 2px coloured outline (green for Charity,
    /// brand blue for Extra Fund), never a background wash. The
    /// collapsed card reads as a real card, not a bare row. The
    /// whole card is the tap target — the chevron is only a visual
    /// hint (owner, Nov 11, 2026). Loading shows the same bigger
    /// shape with a muted grey outline and muted grey shimmer, with
    /// NO colour (title + grey chip + shimmer amount block, no
    /// spinner, no "Loading…" text). A failed card shows the same
    /// shape with a STATIC grey block for the face — never a bare
    /// "—" — plus the red status line below it; the expanded rows
    /// carry the ErrorBox + Retry. The card body is a tap
    /// gesture, NOT a Button: the expanded rows contain real "Try
    /// Again" Buttons, and a Button nested inside a Button never
    /// fires (audit H-P1-3). A child Button wins over an ancestor
    /// tap gesture, so the retry taps while the rest of the card
    /// still toggles.
    ///
    /// Compact (owner, Nov 14, 2026): on Home the Charity and
    /// Extra Fund cards are half-width in one row, so the face is
    /// smaller (14pt padding, 16pt title, 24pt amount, 32pt icon
    /// chip) and the detail rows do NOT render inside the card —
    /// they drop into a full-width statDetailCard below the row.
    /// iPad (owner, Nov 15, 2026): the compact face scales back
    /// up — 18pt padding, 18pt title, 32pt amount, 44pt icon chip
    /// — because the half-width cards are ~340pt wide there and the
    /// iPhone sizes read too small. Skeletons grow to match.
    private func statCard(
        title: String,
        face: String,
        theme: StatCardTheme,
        isLoading: Bool,
        statusText: String? = nil,
        statusIsError: Bool = false,
        isExpanded: Bool,
        ariaLabel: String,
        compact: Bool = false,
        onTap: @escaping () -> Void
    ) -> some View {
        // One sizing table: compact (Home, iPhone) / compact on
        // iPad / full (unused on Home today, kept for the shared
        // theme). The skeleton blocks below use the same numbers,
        // so loading and loaded share one shape.
        let chip: CGFloat = compact ? (isIPad ? 44 : 32) : 36
        let iconSize: CGFloat = compact ? (isIPad ? 20 : 16) : 18
        let titleSize: CGFloat = compact ? (isIPad ? 18 : 16) : 18
        let amountSize: CGFloat = compact ? (isIPad ? 32 : 24) : 28
        let amountSkeletonHeight: CGFloat = compact ? (isIPad ? 40 : 30) : 36
        let statusSize: CGFloat = compact ? (isIPad ? 13 : 12) : 13
        let chevronSize: CGFloat = compact ? (isIPad ? 15 : 14) : 15
        let pad: CGFloat = compact ? (isIPad ? 18 : 14) : 20
        return VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: compact ? 8 : 12) {
                if isLoading {
                    SkeletonBlock(width: chip, height: chip, cornerRadius: 10)
                } else {
                    Image(systemName: theme.iconName)
                        .font(.system(size: iconSize, weight: .semibold))
                        // Owner, Nov 14, 2026 ("too much colors"):
                        // no colour inside the card — the icon is
                        // ink and its chip ring is plain light
                        // grey. ONLY the 2px card outline keeps
                        // colour.
                        .foregroundStyle(DesignTokens.ink)
                        .frame(width: chip, height: chip)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                }
                Text(title)
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Spacer()
            }
            if isLoading {
                // Full-width bar (owner, Nov 15, 2026: the
                // amount-sized block stopped short of the right
                // edge — it now runs edge-to-edge within the card
                // padding). Same height as the loaded amount, so
                // the card holds its size while loading. No second
                // line: the loaded face has none (statusText is nil
                // when loaded), so a phantom line here would shrink
                // the card — a layout jump — the moment the amount
                // arrives.
                SkeletonBlock(height: amountSkeletonHeight, cornerRadius: 8)
            } else if statusIsError {
                SkeletonBlock(height: amountSkeletonHeight, cornerRadius: 8, animated: false)
            } else {
                Text(face)
                    .font(.system(size: amountSize, weight: .heavy))
                    // Owner, Nov 14, 2026 ("too much colors"): the
                    // amount is ink, never the deep theme colour —
                    // even when negative. ONLY the card outline
                    // keeps colour.
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let statusText {
                Text(statusText)
                    .font(.system(size: statusSize, weight: statusIsError ? .semibold : .regular))
                    .foregroundStyle(statusIsError ? DesignTokens.errorText : Color(hex: "#6b7280"))
            }
            HStack {
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize, weight: .bold))
                    // Owner, Nov 14, 2026 ("too much colors"): the
                    // chevron is muted grey, not brand blue.
                    .foregroundStyle(DesignTokens.muted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    theme.outline,
                    lineWidth: theme.outlineWidth
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(ariaLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// Full-width detail card for an expanded half-size stat card
    /// (owner, Nov 14, 2026): when a half-size Charity / Extra
    /// Fund card is tapped, its rows drop here, below the row —
    /// the compact card has no room for them. Same outline, white
    /// inside, same shadow as the card itself. Tapping the detail
    /// collapses it; a "Try Again" button inside still wins over
    /// the tap gesture (audit H-P1-3 pattern).
    private func statDetailCard<Rows: View>(
        theme: StatCardTheme,
        onTap: @escaping () -> Void,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) { rows() }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(theme.outline, lineWidth: theme.outlineWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    /// Row labels are Title Case, like headings and button labels
    /// (owner rule, Nov 4, 2026 — audit H-P2-1).
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

    /// Face text is only rendered when loaded: loading shows the
    /// shimmer amount block, failure the static grey block — never
    /// a bare "—" (owner loading/empty language, Nov 12, 2026).
    private var charityFaceText: String {
        switch viewModel.charity {
        case .loaded(let summary): return MoneyFormat.signedString(cents: summary.remainingCents)
        case .failed, .loading: return ""
        }
    }

    /// Status line under the Charity face: failure gets a plain red
    /// "Could not load" (the expanded rows carry the ErrorBox +
    /// Retry). Loading gets NO line — the skeleton is the loading
    /// sign. Loaded: none.
    private var charityStatusText: String? {
        switch viewModel.charity {
        case .loading: return nil
        case .failed: return "Could not load"
        case .loaded: return nil
        }
    }

    /// Same status line for Extra Fund.
    private var fundStatusText: String? {
        switch viewModel.fund {
        case .loading: return nil
        case .failed: return "Could not load"
        case .loaded: return nil
        }
    }

    private var fundFaceText: String {
        switch viewModel.fund {
        case .loaded(let summary): return MoneyFormat.signedString(cents: summary.availableCents)
        case .failed, .loading: return ""
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
                Button("See All") { appState.showAllTransactions() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.primary)
            }
            switch viewModel.recent {
            case .loading:
                // Shimmer skeletons shaped like the loaded rows —
                // no spinner, no "Loading…" line (owner loading
                // language, Nov 12, 2026). Ten rows (owner, Nov 15,
                // 2026): three rows left empty white space below
                // them while loading — ten fills the viewport on
                // iPhone and iPad portrait, so there is no gap at
                // the bottom during loading.
                VStack(spacing: 12) {
                    ForEach(0..<10, id: \.self) { _ in TransactionRowSkeleton() }
                }
                .padding(.vertical, 12)
                .accessibilityLabel("Loading recent transactions")
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
        // The amount uses the one shared kind rule
        // (TransactionFormatting.amountDisplay): money in green
        // with "+", charity blue, regular kinds ink — never red.
        let display = TransactionFormatting.amountDisplay(for: row)
        return Button {
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
                        StatePill(row)
                        Text("\(AppDates.relativeDay(row.date)) · \(cardLabel(row))")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#6b7280"))
                    }
                }
                Spacer()
                Text(display.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(display.color)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func cardLabel(_ row: Transaction) -> String {
        row.cardSuffix == "0000" ? "Cash / no card" : "••\(row.cardSuffix)"
    }

    // No Home footer: the "OnBudget · Last bank sync …" line was
    // removed (owner, Nov 11, 2026). The sync stamp lives once,
    // quietly, under Automatic Sync in Settings
    // (ConnectedAccountsView).
}

// MARK: - Weekly sheet

/// Weekly sheet (CLONE_SPEC §14, live.js:3457-3500). Opened by
/// tapping the hero number. Rows, exactly three, in order:
/// Allowance (= base room + temp) / Spent (server charges_cents) /
/// Balance (available_cents). Fourth row only when non-zero:
/// Unlinked refunds. Then the Purchases count (owner, Nov 14,
/// 2026 — moved here from the hero card, which now shows only
/// the "Spending" header, the big figure, the progress bar and
/// the spent line). No explainer line under the header (owner,
/// Nov 12 2026): the "Pending transactions are included and
/// marked." line crowded the header, and pending state is already
/// marked on the rows. Show Transactions (primary) + Close
/// (tertiary) — two-button sheet rule. iPad: 600pt wide, centred
/// (.presentationSizing(.fitted) + fixed width in the regular size
/// class); iPhone: full-width.
public struct WeeklySheet: View {
    let week: WeekResult
    let baseAllowanceCents: Int?
    let purchasesThisWeek: Int?
    @ObservedObject var appState: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(week: WeekResult, baseAllowanceCents: Int?, purchasesThisWeek: Int?, appState: AppViewModel) {
        self.week = week
        self.baseAllowanceCents = baseAllowanceCents
        self.purchasesThisWeek = purchasesThisWeek
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: air above the title (owner, Nov 12 2026 — the
            // sheet felt claustrophobic). Single dismiss control:
            // the bottom "Close" next to "Show Transactions". The
            // header "Cancel" duplicated it (audit H-P2-3), and its
            // centring shim was narrower than the rendered button,
            // so the title now centres on its own frame instead.
            Text("Weekly Budget")
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            // No explainer line here (owner, Nov 12 2026): the
            // "Pending transactions are included and marked." line
            // crowded the header. Pending state is already marked
            // on the rows themselves, so nothing replaces it.
            // Reconciliation rows (live.js v69): Base / Temporary /
            // Carried debt appear exactly when they change the number;
            // a normal week keeps the approved two rows (Spent,
            // Balance) — the redundant Allowance row is gone
            // (owner, Nov 15, 2026 — build 34).
            ForEach(week.sheetRows(baseAllowanceCents: baseAllowanceCents), id: \.label) { row in
                // Deduction rows print with a leading minus
                // (audit H-P2-2) so Base $375 − Debt $50 = Balance
                // $325 adds up on sight; the model cents stay positive.
                sheetRow(label: row.label, value: MoneyFormat.string(cents: row.isDeduction ? -row.cents : row.cents))
            }
            // Purchases count (owner, Nov 14, 2026): moved here
            // from the hero card. A count, not money — same row
            // shape, no dollar sign.
            if let purchases = purchasesThisWeek {
                sheetRow(label: "Purchases", value: String(purchases))
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
            .padding(.top, 8)
            // Footnote only (owner, Nov 12 2026): the header explainer
            // line was removed, but its second sentence explains the
            // Unlinked Refunds row, so it survives here at the bottom,
            // small and muted, only when it applies.
            if week.unlinkedExcessCents != 0 {
                Text("Unlinked refunds above this week's spending are not counted here.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        // iPad width (owner, Nov 12 2026): with .presentationSizing
        // (.fitted) at the presentation site, the sheet sizes to
        // this content — so a fixed 600pt width here actually widens
        // the sheet on iPad (regular size class) instead of the
        // system ~540pt form sheet. On iPhone (compact) no width is
        // fixed and the sheet stays full-width.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
    }

    private func sheetRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.vertical, 4)
    }
}
