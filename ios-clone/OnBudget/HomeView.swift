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

    /// True only for the loaded state (a value is on screen).
    /// A refresh keeps a loaded section's value instead of
    /// blanking it back to `.loading` (owner, Nov 16, 2026 —
    /// build 38: show last-known values while fresh data loads).
    public var isLoaded: Bool {
        if case .loaded = self { return true }
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
        // Keep last-known values on screen during a refresh (owner,
        // Nov 16, 2026 — build 38): only sections with no value yet
        // show skeletons. A refresh never blanks loaded cards.
        if !week.isLoaded { week = .loading }
        if !fund.isLoaded { fund = .loading }
        if !charity.isLoaded { charity = .loading }
        if !recent.isLoaded { recent = .loading }

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

        // Collect every result FIRST, then assign all sections
        // TOGETHER (owner, Nov 16, 2026 — build 38): the old code
        // assigned each section as its task finished, so the cards
        // flipped from skeleton to loaded one by one. Now the four
        // cards reveal in one step, after everything has resolved.
        // The derivations below are unchanged — only their results
        // are held in locals until the reveal.

        // Week numbers — everything else keys off the week.
        var weekResult: WeekResult?
        var weekError: OnBudgetError?
        do {
            weekResult = try await weekTask.value
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            weekError = error
        } catch {
            weekError = .unknown("Could not load this week's numbers.")
        }
        let weekStart = weekResult?.weekStart

        // Allowance-set flag ($375 is the schema default, not a
        // choice — allowanceSetAt == nil means never set). The stored
        // base travels with it for the Weekly sheet's reconciliation
        // rows; both clear together when the household read fails so
        // a stale base can never explain a fresh week.
        var allowanceValue: (baseAllowanceCents: Int?, allowanceExplicitlySet: Bool)?
        var allowanceErrorValue: OnBudgetError?
        do {
            allowanceValue = try await allowanceTask.value
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            allowanceErrorValue = error
        } catch {
            allowanceErrorValue = .unknown("Could not load your allowance setting.")
        }

        // Transactions page: recent 6, purchases count, charity
        // gifts. A failure here is an error state, never a silent
        // empty list. The charity summary is derived from the same
        // rows + the concurrently fetched income and settings.
        var txRows: [Transaction] = []
        var txError: OnBudgetError?
        do {
            let (rows, _) = try await txTask.value
            txRows = rows.filter { !$0.isInTrash }
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            txError = error
        } catch {
            txError = .unknown("Could not load recent transactions.")
        }

        // Charity summary (only when the transactions load above
        // succeeded — a failed transactions load already failed the
        // charity section with it, as before).
        var charitySummary: CharitySummary?
        var charityError: OnBudgetError?
        if txError == nil {
            do {
                let income = try await charityIncomeTask.value
                let settings = try await charitySettingsTask.value
                let charityRows = txRows.filter { $0.kind == .charity }
                charitySummary = CharitySummary.compute(
                    activeIncome: income,
                    charityTransactions: charityRows,
                    defaultRateBp: settings?.defaultRateBp ?? 1000)
            } catch let error as OnBudgetError {
                if error == .sessionExpired { appState.showSessionExpired(); return }
                charityError = error
            } catch {
                charityError = .unknown("Could not load charity.")
            }
        } else {
            charityError = txError
        }

        // Extra Fund display aggregation (sums over server rows).
        var fundSummary: FundSummary?
        var fundError: OnBudgetError?
        do {
            fundSummary = FundSummary.compute(
                ledger: try await fundLedgerTask.value,
                releases: try await fundReleasesTask.value,
                shortfallCents: try await fundShortfallTask.value)
        } catch let error as OnBudgetError {
            if error == .sessionExpired { appState.showSessionExpired(); return }
            fundError = error
        } catch {
            fundError = .unknown("Could not load Extra Fund balances.")
        }

        // Plaid suffix → institution map (bank icons). Best-effort —
        // never blocks Home. No sync stamp is kept here: the sync
        // line lives in Settings only.
        var institutionMap: [String: String]?
        do {
            institutionMap = try await plaidTask.value
        } catch {
            institutionMap = nil
        }

        // ---- Reveal together: every section assignment happens
        // here, in one step, after all fetches have resolved. ----
        if let weekResult {
            week = .loaded(weekResult)
        } else if let weekError {
            week = .failed(weekError)
        }
        if let allowanceValue {
            allowanceSet = allowanceValue.allowanceExplicitlySet
            allowanceCents = allowanceValue.baseAllowanceCents
            allowanceError = nil
        } else {
            allowanceSet = nil
            allowanceCents = nil
            allowanceError = allowanceErrorValue
        }
        if txError == nil {
            recent = .loaded(Array(txRows.prefix(6)))
            if let weekStart {
                let weekRows = txRows.filter { AppDates.isInWeek($0.date, weekStart: weekStart) }
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
        } else if let txError {
            recent = .failed(txError)
            purchasesThisWeek = nil
        }
        if let charitySummary {
            charity = .loaded(charitySummary)
        } else if let charityError {
            charity = .failed(charityError)
        }
        if let fundSummary {
            fund = .loaded(fundSummary)
        } else if let fundError {
            fund = .failed(fundError)
        }
        if let institutionMap {
            institutionBySuffix = institutionMap
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
            // Build 40 (widget sync): the household id rides along
            // in the App Group (separate key — the snapshot itself
            // carries no household identifier), so the widget
            // extension knows which household to fetch on a sync tap.
            WidgetSnapshotStore.writeHouseholdId(householdId)
            WidgetSnapshotStore.write(WidgetSnapshot(
                weekStart: result.weekStart,
                availableCents: result.availableCents,
                charityRemainingCents: summary.remainingCents,
                spentCents: result.chargesCents,
                charityGivenCents: summary.givenCents,
                charityCommittedCents: summary.committedCents,
                // Build 37 (fund rename): the household's custom
                // fund names ride along, so the widget shows a
                // renamed fund's name too.
                fundNames: appState.fundNames,
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
            // Fund cards sit as ONE COMPACT UNIT (owner, Nov 16,
            // 2026 — build 40: the white gap between the Spending
            // hero and the Charity/Extra Fund row was "extra" and
            // had to be removed). The stack gap is 10pt (was 16pt)
            // and the hero's white body carries no bottom padding
            // when it is empty (debt is $0), so the three cards read
            // as one unit, not three blocks floating on white. The
            // sections still breathe — 10pt, not zero.
            // Build 41 (owner, Nov 16, 2026 — "much bigger and
            // look like cards.. a small shadow below each card"):
            // the cards are bigger and each carries its own shadow,
            // so the gap grows to 12pt — just enough air for the
            // shadow to read without the cards touching. They are
            // distinct cards now, not one fused unit.
            VStack(alignment: .leading, spacing: 12) {
                heroCard
                // Charity + Extra Fund share one row, half-width
                // each (owner, Nov 14, 2026 — supersedes the Nov 12
                // bigger full-width stacked cards). Each card is ONE
                // unified card (owner, Nov 16, 2026 — build 40):
                // the expanded detail lives INSIDE its own card's
                // white body, under that card only — never a
                // separate block below the row (build 39 put the
                // values under the NEIGHBOURING card). One card open
                // at a time (accordion rule unchanged).
                HStack(alignment: .top, spacing: 14) {
                    charityCard
                        .frame(maxWidth: .infinity, alignment: .leading)
                    fundCard
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Recent Transactions sits on the same 10pt stack
                // gap as the cards above it (owner, Nov 16, 2026 —
                // build 40: no extra padding — the old 8pt top
                // padding on top of the 16pt gap made 24pt, which
                // read as extra white space).
                recentSection
            }
            .padding(16)
        }
        .background(DesignTokens.background)
        // Build 36 (owner, Nov 16, 2026 — iPad): the tab reads as a
        // centered 900pt column on the regular size class (see
        // mainContentWidth), never stretched edge-to-edge.
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
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
    // number on the page). Owner, Nov 16, 2026 (build 40): ONE
    // UNIFIED CARD — a SHORT colored header strip on top (a "$"
    // icon in a white circle + "Spending" + the amount in one row,
    // all white on primary blue) and a WHITE body below (the MAJORITY
    // of the card) holding the progress bar + spent line + chevron,
    // then the debt math line / allowance states. The color is a
    // header accent, not half the card — "the majority should be
    // white, not half half." The Spending bar + spent line moved
    // DOWN into the white body (they were inside the blue in build
    // 39). The sync button stays at the trailing end of the header
    // strip. The loading state renders at the same full hero size
    // (shimmer skeleton blocks on WHITE, no tint, no spinner), so
    // the layout never jumps when the number arrives.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header strip (colored, short): ONE ROW — icon + name
            // + amount + sync button. While loading or failed the
            // strip is white / muted grey, not blue.
            heroHeaderStrip
            // White body (majority): progress bar + spent line +
            // chevron, then the debt math line / allowance states.
            heroWhiteBody
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Build 41 (owner, Nov 16, 2026): a small shadow below
        // the card — the shared fundCardShadow, so the hero lifts
        // exactly like the stat cards and the Funds page cards.
        .fundCardShadow()
        .contentShape(Rectangle())
        // Whole-card tap target (owner, Nov 15, 2026 app-wide
        // pass): the card opens the Weekly sheet, not just the
        // header. The sync button still wins: a Button inside
        // beats the parent tap gesture, and the "Set Your Weekly
        // Allowance" / "Try Again" buttons in the body win too.
        // Loading or failed weeks open nothing — the sheet needs a
        // loaded week.
        .onTapGesture {
            if case .loaded = viewModel.week {
                showWeeklySheet = true
            }
        }
        .accessibilityIdentifier("home.weeklyBudget")
    }

    /// White body of the hero (the majority of the card): progress
    /// bar + spent line + chevron, then the debt math line /
    /// allowance states when present. While loading the bar + spent
    /// line + debt math skeletons sit here (same sizes as the loaded
    /// content, so the body holds its size); while failed the error
    /// box + Try Again sit here. Build 41 (owner, Nov 16, 2026 —
    /// "much bigger"): the body breathes more — 20pt sides, 16pt
    /// top, 18pt bottom, 16pt between rows. Build 42 (owner,
    /// Nov 17, 2026 — "the white body should be double the header"):
    /// the body dominates — roughly 1/3 header, 2/3 white body —
    /// so the top/bottom padding steps up to 36pt and the rows sit
    /// 18pt apart. The header is untouched; the card gets taller.
    private var heroWhiteBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch viewModel.week {
            case .loading:
                // Build 42 (owner, Nov 17, 2026 — progress bar
                // thicker): the bar skeleton matches the loaded
                // bar — 12pt, not 10pt.
                SkeletonBlock(height: 12, cornerRadius: 6)
                SkeletonBlock(height: 14)
                SkeletonBlock(height: 14)
            case .failed(let error):
                // One failure message only: the ErrorBox. The grey
                // "Could not load…" line above it said the same
                // thing twice (audit H-P2-4).
                ErrorBox(weekErrorText(error))
                Button("Try Again") { Task { await viewModel.refresh() } }
                    .buttonStyle(TertiaryButtonStyle())
            case .loaded(let result):
                heroBodyProgress(result)
                heroLoadedContent(result)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
        .padding(.bottom, 36)
    }

    /// Banner colour: the Spending theme's banner (primary blue
    /// #2f6bff since build 41 — the 3-button scheme; the deep blue
    /// #1d4ed8 was the build-38/39 banner) when loaded; WHITE while
    /// LOADING (owner, Nov 16, 2026 — build 40: the pale #dbeafe
    /// tint was horrendous, the original white background with grey
    /// skeleton shapes was nicest); muted grey #e5e7eb when FAILED
    /// (a failed load stays distinct from loading). The theme is
    /// the single source — the hero reads it, never a hard-coded
    /// hex.
    private var heroBannerColor: Color {
        switch viewModel.week {
        case .loaded: return StatCardTheme.spending.banner
        case .loading: return DesignTokens.loadingBanner
        case .failed: return Color(hex: "#e5e7eb")
        }
    }

    /// Text/icon colour on the hero banner: white on the loaded
    /// blue banner, ink on the grey loading/failed banner.
    private var heroBannerTextColor: Color {
        if case .loaded = viewModel.week { return .white }
        return DesignTokens.ink
    }

    // Hero header — icon + title in ONE row, with the sync button
    // at the trailing end (the top-right corner of the banner).
    // The title is "Spending" and there is NO date anywhere on the
    // card (owner, Nov 14, 2026 — this supersedes the inline-date
    // Header strip (owner, Nov 16, 2026 — build 40): ONE ROW —
    // a "$" icon in a white circle + "Spending" + the amount, all
    // white on deep blue, with the sync button at the trailing end.
    // The amount is INLINE in the header (24pt heavy iPhone / 30pt
    // iPad), not a big standalone figure — the strip is short, the
    // white body below is the majority. While loading the strip is
    // WHITE with skeleton blocks (build 40 loading revert — no
    // tint); the sync spot holds a skeleton block so the header
    // never jumps when the numbers arrive. While failed the strip
    // is muted grey.
    // Build 41 (owner, Nov 16, 2026 — "much bigger"): the amount
    // is 30pt heavy on iPhone (36pt iPad), the title 20pt, the
    // icon disc 36pt, the sync circle 40pt, and the strip carries
    // 14pt vertical padding — the header reads as a big card
    // header now, not a slim bar. Skeleton blocks match.
    private var heroHeaderStrip: some View {
        HStack(spacing: 8) {
            if case .loading = viewModel.week {
                // Skeleton icon + title while loading (owner, Nov 16,
                // 2026 — build 38): real dark-ink text on the
                // placeholder read as a finished card.
                SkeletonBlock(width: 36, height: 36, cornerRadius: 18)
                SkeletonBlock(width: 110, height: 20, cornerRadius: 6)
            } else {
                // "$" icon in a white circle (owner, Nov 16, 2026 —
                // build 40 reference): the theme's glyph colour on
                // a white disc (build 41 — the banner colour itself
                // is unreadable on white for the light banners).
                Image(systemName: FundSectionID.spending.resolvedIconName(customIcons: appState.fundIcons))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StatCardTheme.spending.glyph)
                    .frame(width: 36, height: 36)
                    .background(.white)
                    .clipShape(Circle())
                Text(FundSectionID.spending.displayName(customNames: appState.fundNames))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(heroBannerTextColor)
                    .lineLimit(1)
            }
            Spacer()
            // Amount, inline in the header. White on the blue strip
            // even when over budget (the over-budget state shows in
            // the red progress fill + "Over budget" spent line, as
            // in build 39 — red text on blue does not read).
            switch viewModel.week {
            case .loading:
                SkeletonBlock(width: 84, height: 30, cornerRadius: 6)
            case .failed:
                EmptyView()
            case .loaded(let result):
                Text(MoneyFormat.amountText(cents: result.availableCents, isMoneyIn: false))
                    .font(.system(size: isIPad ? 36 : 30, weight: .heavy))
                    .foregroundStyle(heroBannerTextColor)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityLabel(
                        result.availableCents < 0
                            ? "Spending, over budget by \(MoneyFormat.string(cents: -result.availableCents)), show breakdown"
                            : "Spending, \(MoneyFormat.string(cents: result.availableCents)) left this week, show breakdown"
                    )
            }
            if viewModel.isAdmin {
                switch viewModel.week {
                case .loading:
                    SkeletonBlock(width: 40, height: 40, cornerRadius: 20)
                case .loaded:
                    syncButton
                case .failed:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(heroBannerColor)
    }

    /// Sync button: admin-only; grey tertiary while no allowance
    /// is set, so "Set Your Weekly Allowance" is the hero's only
    /// primary control. On the blue banner it is a WHITE circle so
    /// it reads against the banner (the old mid-blue fill vanished
    // on blue): the arrow is primary blue when an allowance is set,
    // ink when not set — the two states still tell apart, and both
    // read on white. Moved here from the figure row (owner, Nov 14,
    // 2026: the top-right corner of the card, not mid-right over
    // the progress bar).
    private var syncButton: some View {
        Button { Task { await viewModel.syncBank() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .semibold))
                // Blue arrow on the white circle when an allowance
                // is set; dark ink when not set — both read on
                // white, and the states still tell apart (audit
                // H-P1-1: white-on-grey was ~1.1:1 and effectively
                // invisible).
                .foregroundStyle(viewModel.allowanceSet == true ? DesignTokens.primary : DesignTokens.ink)
                .frame(width: 40, height: 40)
                .background(.white)
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

    private func weekErrorText(_ error: OnBudgetError) -> String {
        switch error {
        case .networkOffline, .timedOut, .networkError:
            return "Couldn't update this week's numbers — check your connection and try again."
        default:
            return "Couldn't update this week's numbers — tap Try Again to reload."
        }
    }

    /// The hero content in the WHITE body below the progress bar
    /// (debt math, allowance states): the amount lives in the
    /// header strip now (owner, Nov 16, 2026 — build 40), and the
    /// progress bar + spent line moved DOWN into the white body
    /// (they were inside the blue in build 39), so this starts at
    /// the debt math line. The date is gone from the card entirely,
    /// and the Weekly Allowance + Purchases stats moved into the
    /// Weekly sheet (owner, Nov 14, 2026).
    @ViewBuilder
    private func heroLoadedContent(_ result: WeekResult) -> some View {
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

    /// Progress bar + spent line, in the hero's WHITE body (owner,
    /// Nov 16, 2026 — build 40: they were inside the blue in build
    /// 39; the white body is the majority now, so the bar + line
    /// moved DOWN into it). Same math as the build-39 banner
    /// version; only the COLOURS changed — the track is light grey
    /// and the fill is the Spending blue on white (not white-on-
    /// blue), over budget the fill is the brighter red #dc2626 (the
    /// dark red #991b1b did not read on dark blue in build 39, and
    /// it still reads on white). The chevron at the right end of
    /// the spent line is the hint that the card opens the Weekly
    /// sheet. Build 42 (owner, Nov 17, 2026 — progress bar
    /// thicker): the bar is 12pt, not 10pt.
    private func heroBodyProgress(_ result: WeekResult) -> some View {
        // Charges / capacity, capped at 100%; over budget the fill
        // is full-width. A zero/negative capacity used to force
        // the fraction to 0, so the bar was an empty track exactly
        // when over budget (audit H-P2-6).
        let capacity = result.baseAvailableCents + result.tempCents
        let overBudget = result.chargesCents > capacity
        let fraction: CGFloat = overBudget ? 1 : (capacity > 0 ? CGFloat(result.chargesCents) / CGFloat(capacity) : 0)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: "#e5e7eb"))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(overBudget ? Color(hex: "#dc2626") : StatCardTheme.spending.banner)
                        .frame(width: geometry.size.width * fraction, height: 12)
                }
            }
            .frame(height: 12)

            // Spent line + % used + chevron. While no allowance is
            // set the line reads "Not set" — a genuinely unset
            // value, never a bare dash (owner loading/empty
            // language, Nov 12, 2026). A failed allowance read
            // (nil) still shows compute-week's numbers — only an
            // explicit never-set hides them (audit H-P1-4).
            HStack(spacing: 8) {
                if viewModel.allowanceSet != false {
                    Text("\(MoneyFormat.string(cents: result.chargesCents)) spent")
                    Text("·")
                    Text(usedPercentText(result: result, capacity: capacity))
                } else {
                    Text("Not set")
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            .font(.system(size: 15))
            .foregroundStyle(DesignTokens.ink)
        }
    }

    private func usedPercentText(result: WeekResult, capacity: Int) -> String {
        if result.chargesCents == 0 { return "0% used" }
        if capacity <= 0 { return "Over budget" }
        let percent = Int((Double(result.chargesCents) / Double(capacity) * 100).rounded())
        return percent > 100 ? "Over budget" : "\(percent)% used"
    }

    // MARK: Stat cards — Charity + Extra Fund, half-size side by side

    private var charityCard: some View {
        statCard(
            title: FundSectionID.charity.displayName(customNames: appState.fundNames),
            face: charityFaceText,
            theme: .charity,
            section: .charity,
            isLoading: viewModel.charity.isLoading,
            statusText: charityStatusText,
            statusIsError: viewModel.charity.isFailed,
            isExpanded: appState.expandedCard == .charity,
            ariaLabel: charityAriaLabel,
            compact: true,
            onTap: {
                switch viewModel.charity {
                case .loading:
                    notLoadedAlertTitle = FundSectionID.charity.displayName(customNames: appState.fundNames)
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    // Failed cards expand too, so the error + Retry
                    // are reachable; loading still shows the alert.
                    appState.expandedCard = appState.expandedCard == .charity ? nil : .charity
                }
            },
            // Collapsed summary (owner, Nov 16, 2026 — build 40):
            // the white body shows "Given · Total" when collapsed,
            // so the card is majority white even unexpanded. The
            // detail rows (Available/Given/Total) live in the same
            // white body when expanded.
            summaryText: charitySummaryText
        ) { charityRows }
    }

    /// Charity detail rows, rendered INSIDE the Charity card's
    /// white body when it is expanded (owner, Nov 16, 2026 —
    /// build 40: they were a separate block below the banner in
    /// build 39, floating on white with a gap — now they are part
    /// of the same unified card).
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
            title: FundSectionID.fund.displayName(customNames: appState.fundNames),
            face: fundFaceText,
            theme: .fund,
            section: .fund,
            isLoading: viewModel.fund.isLoading,
            statusText: fundStatusText,
            statusIsError: viewModel.fund.isFailed,
            isExpanded: appState.expandedCard == .fund,
            ariaLabel: fundAriaLabel,
            compact: true,
            onTap: {
                switch viewModel.fund {
                case .loading:
                    notLoadedAlertTitle = FundSectionID.fund.displayName(customNames: appState.fundNames)
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    appState.expandedCard = appState.expandedCard == .fund ? nil : .fund
                }
            },
            // Collapsed summary (owner, Nov 16, 2026 — build 40):
            // the white body shows "Pending · Total" when collapsed,
            // so the card is majority white even unexpanded. The
            // detail rows live in the same white body when expanded.
            summaryText: fundSummaryText
        ) { fundRows }
    }

    /// Extra Fund detail rows, rendered INSIDE the Extra Fund
    /// card's white body when it is expanded (owner, Nov 16, 2026
    /// — build 40: they were a separate block below the banner in
    /// build 39, floating on white with a gap — now they are part
    /// of the same unified card).
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

    /// A fund card — ONE UNIFIED CARD (owner, Nov 16, 2026 —
    /// build 40): a SHORT colored header strip on top (an icon in
    /// a white circle + the fund name + the amount in ONE row, all
    /// white on the fund's theme colour — Charity mid blue #3b82f6,
    /// Extra Fund muted grey #6b7280) and a WHITE body below (the
    /// MAJORITY of the card) holding the summary line when collapsed
    /// or the detail rows when expanded, plus the chevron. The color
    /// is a header accent, not half the card — "the majority should
    /// be white, not half half." The detail rows live INSIDE the
    /// card's own white body now (they were a separate block below
    /// the banner in build 39, floating on white with a gap). The
    /// green/amber outlines are gone.
    /// The chevron is SF Symbol chevron.down, down when collapsed,
    /// up when expanded — it flips instantly, no rotation animation:
    /// expand/collapse is instant since build 34 (owner decision
    /// Nov 15, 2026). Loading shows the same card shape in WHITE
    /// with grey shimmer (build 40 loading revert — no tint, no
    /// colour, no spinner, no "Loading…" text). A failed card shows
    /// the same shape with a STATIC grey block for the amount —
    /// never a bare "—" — plus the red status line in the white
    /// body; the expanded rows carry the ErrorBox + Retry. The
    /// whole card is a tap gesture, NOT a Button: the expanded rows
    /// contain real "Try Again" Buttons, and a Button nested inside
    /// a Button never fires (audit H-P1-3). A child Button wins over
    /// an ancestor tap gesture, so the retry taps while the rest of
    /// the card still toggles.
    ///
    /// Compact (owner, Nov 14, 2026): on Home the Charity and
    /// Extra Fund cards are half-width in one row, so the face is
    /// smaller (16pt padding, 18pt title, 24pt amount). iPad
    /// (owner, Nov 15, 2026): the compact face scales back up —
    /// 20pt padding, 20pt title, 28pt amount — because the
    /// half-width cards are ~340pt wide there and the iPhone sizes
    /// read too small. Skeletons grow to match. (Build 41, owner
    /// Nov 16, 2026 — "much bigger": all of these stepped up from
    /// the build-40 12/16/20pt compact sizes.)
    private func statCard<Rows: View>(
        title: String,
        face: String,
        theme: StatCardTheme,
        section: FundSectionID,
        isLoading: Bool,
        statusText: String? = nil,
        statusIsError: Bool = false,
        isExpanded: Bool,
        ariaLabel: String,
        compact: Bool = false,
        onTap: @escaping () -> Void,
        summaryText: String? = nil,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        // One sizing table: compact (Home, iPhone) / compact on
        // iPad / full (unused on Home today, kept for the shared
        // theme). The skeleton blocks below use the same numbers,
        // so loading and loaded share one shape. (Owner, Nov 16,
        // 2026 — build 38, "a bit too heavy": the compact amounts
        // and padding are a touch smaller than build 37.)
        // Build 41 (owner, Nov 16, 2026 — "much bigger"): every
        // number steps up — the half-width cards read as real
        // cards now, not slim strips. The header row stays ONE
        // line: the amount keeps its 0.7 shrink and the title
        // gains a 0.85 shrink, so a long fund name still fits
        // beside a big amount in a half-width card.
        let chip: CGFloat = compact ? (isIPad ? 40 : 34) : 40
        let iconSize: CGFloat = compact ? (isIPad ? 18 : 16) : 20
        let titleSize: CGFloat = compact ? (isIPad ? 20 : 18) : 20
        let amountSize: CGFloat = compact ? (isIPad ? 28 : 24) : 30
        let amountSkeletonHeight: CGFloat = compact ? (isIPad ? 34 : 30) : 38
        let statusSize: CGFloat = compact ? (isIPad ? 14 : 13) : 14
        let chevronSize: CGFloat = compact ? (isIPad ? 15 : 14) : 15
        let pad: CGFloat = compact ? (isIPad ? 20 : 16) : 24
        // Header colour: WHITE while LOADING (owner, Nov 16, 2026
        // — build 40: the pale #dbeafe tint was horrendous, the
        // original white background with grey skeleton shapes was
        // nicest), muted grey #e5e7eb when FAILED (a failed load
        // stays distinct from loading), the theme colour when
        // loaded.
        let bannerColor: Color = {
            if isLoading { return DesignTokens.loadingBanner }
            if statusIsError { return Color(hex: "#e5e7eb") }
            return theme.banner
        }()
        // Text colour on the header: the theme's onBanner colour
        // (build 41 — per theme: white on the dark Spending/Debt
        // banners, ink on the light Charity pale / Extra Fund
        // tertiary banners), ink on the grey loading/failed header.
        // The icon is always the theme's glyph colour — it sits on
        // a WHITE circle, so it reads on white in every state.
        let onBanner: Color = {
            if isLoading || statusIsError { return DesignTokens.ink }
            return theme.onBanner
        }()
        return VStack(alignment: .leading, spacing: 0) {
            // Header strip (colored, short): ONE ROW — icon in a
            // white circle + title + amount, all on the fund color.
            HStack(spacing: 8) {
                if isLoading {
                    SkeletonBlock(width: chip, height: chip, cornerRadius: chip / 2)
                } else {
                    // Icon in a white circle (owner, Nov 16, 2026 —
                    // build 40 reference): the theme's glyph colour
                    // on a white disc (build 41 — the banner colour
                    // itself is unreadable on white for the light
                    // banners).
                    Image(systemName: section.resolvedIconName(customIcons: appState.fundIcons))
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(theme.glyph)
                        .frame(width: chip, height: chip)
                        .background(.white)
                        .clipShape(Circle())
                }
                if isLoading {
                    // Skeleton title while loading (owner, Nov 16,
                    // 2026 — build 38): real dark-ink text on the
                    // placeholder read as a finished card. The
                    // failed state keeps the real title.
                    SkeletonBlock(width: 90, height: 20, cornerRadius: 6)
                } else {
                    Text(title)
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(onBanner)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer()
                if isLoading {
                    // Amount-sized skeleton, inline in the header
                    // row (it was a full-width bar when the amount
                    // sat on its own line below the title). Same
                    // height as the loaded amount, so the header
                    // holds its size while loading.
                    SkeletonBlock(width: 72, height: amountSkeletonHeight, cornerRadius: 6)
                } else if statusIsError {
                    SkeletonBlock(width: 72, height: amountSkeletonHeight, cornerRadius: 6, animated: false)
                } else {
                    Text(face)
                        .font(.system(size: amountSize, weight: .heavy))
                        .foregroundStyle(onBanner)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, pad)
            .padding(.vertical, 14)
            .background(bannerColor)
            // White body (majority): the summary line when
            // collapsed, the detail rows when expanded. While
            // loading a single skeleton line; while failed the red
            // status line when collapsed, or the rows (ErrorBox +
            // Retry) when expanded. Build 42 (owner, Nov 17, 2026
            // — "the white body should be double the header"):
            // roughly 1/3 header, 2/3 white body, so the body
            // padding steps up to 52pt top and bottom — the card
            // gets taller with the white body dominating. The
            // header is untouched.
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    SkeletonBlock(height: 14)
                } else if isExpanded {
                    rows()
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: chevronSize, weight: .bold))
                            .foregroundStyle(DesignTokens.muted)
                            .rotationEffect(.degrees(180))
                    }
                } else if statusIsError, let statusText {
                    HStack(spacing: 8) {
                        Text(statusText)
                            .font(.system(size: statusSize, weight: .semibold))
                            .foregroundStyle(DesignTokens.errorText)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: chevronSize, weight: .bold))
                            .foregroundStyle(DesignTokens.muted)
                    }
                } else if let summaryText {
                    HStack(spacing: 8) {
                        Text(summaryText)
                            .font(.system(size: statusSize))
                            .foregroundStyle(Color(hex: "#6b7280"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: chevronSize, weight: .bold))
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
            }
            .padding(.horizontal, pad)
            .padding(.top, 52)
            .padding(.bottom, 52)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Build 41 (owner, Nov 16, 2026): a small shadow below
        // the card — the shared fundCardShadow, so the stat cards
        // lift exactly like the hero and the Funds page cards.
        .fundCardShadow()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(ariaLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// Row labels are Title Case, like headings and button labels
    /// (owner rule, Nov 4, 2026 — audit H-P2-1). The rows live in
    /// a half-width column now (build 39), so label and value
    /// shrink a little instead of truncating or wrapping — the
    /// long "Spendable Available" label needs it.
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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

    /// Collapsed summary for the Charity card's white body (owner,
    /// Nov 16, 2026 — build 40): "Given · Total" — the two figures
    /// that are NOT the Available amount already in the header, so
    /// the card is majority white even unexpanded. Nil unless loaded.
    private var charitySummaryText: String? {
        switch viewModel.charity {
        case .loaded(let summary):
            return "Given \(MoneyFormat.string(cents: summary.givenCents)) · Total \(MoneyFormat.string(cents: summary.committedCents))"
        case .failed, .loading: return nil
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

    /// Collapsed summary for the Extra Fund card's white body
    /// (owner, Nov 16, 2026 — build 40): "Pending · Total" — the
    /// two figures that are NOT the Available amount already in
    /// the header, so the card is majority white even unexpanded.
    /// Nil unless loaded.
    private var fundSummaryText: String? {
        switch viewModel.fund {
        case .loaded(let summary):
            return "Pending \(MoneyFormat.string(cents: summary.pendingIncludingHeldCents)) · Total \(MoneyFormat.string(cents: summary.totalCents))"
        case .failed, .loading: return nil
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
            // Build 36 (owner, Nov 16, 2026 — Home screenshot): the
            // header sat almost on top of the first transaction row.
            // 6pt extra under the header only, so the header-to-first
            // -row gap is 16pt while the rows stay 10pt apart and
            // everything above the header is untouched.
            .padding(.bottom, 6)
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
