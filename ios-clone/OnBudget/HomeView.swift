// STAGE — HomeView.swift
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
// Build 65 (owner, Nov 23, 2026 — items 2, 5): on iPad the
// Spending hero and Tzedaka card sit side by side in two equal
// columns inside the 900pt column (see simpleContent), and
// tapping the Tzedaka card opens the Tzedaka sheet — numbers plus
// its two actions (Add to Tzedaka + Record a Donation) — mirroring
// the Weekly sheet. The classic stacked stat cards above are the
// retired backup; the live Home is simpleContent.
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
    /// Pending top-ups (build 43, owner Nov 17, 2026 — "Doesn't
    /// show the pending amounts"): saved but not yet confirmed in
    /// checking. The Funds detail already folds them into Pending
    /// (FundsViewModel.savingsPendingCents); Home's expanded
    /// Savings rows do the same now, so a $650 pending top-up reads
    /// Pending $650.00 here too. Best-effort — a failed fetch leaves
    /// 0 and never fails the fund card. Relies on the build-43
    /// fetch fix (PostgrestClient.fundTopups selects `status`).
    @Published public var pendingTopupsCents: Int = 0
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
    /// Gmail error banner (build 49, owner Nov 19, 2026): the plain
    /// line when a Gmail connection is in error state — email alerts
    /// have stopped and Home must say so, not stay silent. Nil when
    /// nothing is broken (or the fetch failed — a failed fetch leaves
    /// no banner rather than failing Home).
    @Published public var gmailErrorMessage: String?

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

    /// Hide a fund from Home (build 48, owner Nov 19, 2026 — the
    /// extra funds must be removable from Home right on the card,
    /// not only from the buried edit-sheet toggle on the Funds
    /// page). Admin only, server-enforced (`set_fund_hidden`
    /// refuses Spending and Tzedaka, and refuses non-admins).
    /// Updates the shared `appState.fundHidden`, so Home drops the
    /// fund at once; the Funds page keeps the fund and shows
    /// "Hidden from Home" with a Show on Home button to put it
    /// back. Hiding never touches the fund's prominence, so
    /// showing it again puts it back where it was. Returns true
    /// on success; the caller shows the toast (Home's toasts go
    /// through `appState.showToast`).
    public func hideFundFromHome(section: FundSectionID) async -> Bool {
        guard section.canHideFromHome else { return false }
        do {
            let map = try await client.rpcs.setFundHidden(
                pHouseholdId: householdId, pFundKey: section.rawValue, pHidden: true
            )
            appState.fundHidden = map
            return true
        } catch {
            return false
        }
    }

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
        // Cash gifts (build 43, item 22, owner Nov 17, 2026): cash
        // given off-card lives in charity_cash_gifts, NOT in the
        // transactions table, so Home must fetch it separately —
        // otherwise "Record a Donation" never shows in the Tzedaka
        // figures. Awaited fault-tolerantly below (the Funds
        // pattern): if the table does not exist yet, the fetch
        // throws and the gifts read as $0 rather than failing the
        // whole charity section.
        let charityCashGiftsTask = Task<[CharityCashGift], Error> {
            try await client.postgrest.charityCashGifts(householdId: householdId)
        }
        // Whole-history charity gift amounts (build 50, Nov 20,
        // 2026 — Tzedaka $37 fix): Given and Pending MUST come
        // from whole-history server queries, never from the
        // 100-row transactionsPage. The page holds only the 100
        // newest rows, so once history passed 100 rows the two
        // Nov 3 verified gifts ($2.00 TOIREM.ORG CHARITY +
        // $35.00 =TENYADKALLAHGEMACH) fell out of the page and
        // Home's Given missed $37.00 — Available read $982.32
        // instead of the correct $945.32, and the ring read 6%
        // instead of ~10%. Funds already uses this pattern
        // (verifiedCharityGiftAmounts); Home now does the same,
        // plus the provisional mirror for Pending.
        let charityGivenTask = Task<[Int], Error> {
            try await client.postgrest.verifiedCharityGiftAmounts(householdId: householdId)
        }
        let charityPendingTask = Task<[Int], Error> {
            try await client.postgrest.provisionalCharityGiftAmounts(householdId: householdId)
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
        // Pending top-ups (build 43, owner Nov 17, 2026): saved but
        // not yet confirmed in checking — folded into the expanded
        // Savings Pending/Total rows below (see fundRows), matching
        // FundsViewModel.savingsPendingCents. Separate task so its
        // failure never cancels the ledger fetches.
        let fundTopupsTask = Task<Int, Error> {
            let topups = try await client.postgrest.fundTopups(householdId: householdId)
            return topups.filter { $0.isPending }.reduce(0) { $0 + $1.amountCents }
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
        // Gmail connections (build 49, owner Nov 19, 2026): the Home
        // banner needs the connection state — a connection in error
        // state means email alerts have stopped. Best-effort, like
        // the Plaid map: a failed fetch leaves no banner rather than
        // failing Home.
        let emailTask = Task<[EmailConnectionPublic], Error> {
            try await client.postgrest.emailConnections(householdId: householdId)
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
        // charity section with it, as before). Given and Pending
        // come from the whole-history server queries (build 50,
        // Nov 20, 2026 — Tzedaka $37 fix), NOT from the 100-row
        // page: the page drops older gifts once history passes
        // 100 rows. The Funds pattern, verbatim: Given =
        // verified whole-history gifts + cash gifts; Pending =
        // provisional whole-history gifts; Total = active income
        // at each row's own rate.
        var charitySummary: CharitySummary?
        var charityError: OnBudgetError?
        if txError == nil {
            do {
                let income = try await charityIncomeTask.value
                let settings = try await charitySettingsTask.value
                let givenAmounts = try await charityGivenTask.value
                let pendingAmounts = try await charityPendingTask.value
                let cashGiftCents = (try? await charityCashGiftsTask.value)?
                    .reduce(0) { $0 + $1.amountCents } ?? 0
                charitySummary = CharitySummary(
                    committedCents: income.filter { $0.status == "active" }.reduce(0) { $0 + $1.committedCents },
                    givenCents: givenAmounts.reduce(0, +) + cashGiftCents,
                    pendingGiftCents: pendingAmounts.reduce(0, +),
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
            // Build 43 (owner, Nov 17, 2026 — item 16): the fund's
            // CURRENT display name, never the hardcoded default.
            fundError = .unknown("Could not load \(FundSectionID.fund.displayName(customNames: appState.fundNames)) balances.")
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

        // Gmail connections (build 49): best-effort — a failed fetch
        // leaves no banner rather than failing Home.
        let gmailConnections = try? await emailTask.value

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
        // Pending top-ups (build 43): best-effort — a failed fetch
        // leaves 0 and never fails the fund card (the ledger-based
        // figures above are unaffected).
        do {
            pendingTopupsCents = try await fundTopupsTask.value
        } catch {
            pendingTopupsCents = 0
        }
        if let institutionMap {
            institutionBySuffix = institutionMap
        }
        // Gmail error banner (build 49): nil when nothing is broken
        // (or the fetch failed) — the banner only ever appears on a
        // real error connection, never on a load failure.
        gmailErrorMessage = GmailErrorBanner.message(for: gmailConnections ?? [])

        // Widget snapshot (build 17): the two numbers the Home-screen
        // widget shows — the same figures as the hero and Charity
        // cards. The SNAPSHOT is written only when BOTH loads
        // succeeded; a failed load writes nothing, so the previous
        // snapshot goes stale instead of being overwritten with a
        // partial one. The widget reloads its timeline from this
        // write; a bank sync refreshes Home too, so a sync updates
        // the widget as well.
        //
        // Build 51 (widget refresh, owner Nov 20, 2026): the
        // household id is written whenever it is known — it used to
        // sit inside the both-loads-succeeded block below, so a
        // failed charity (or week) load meant the id was never
        // stored on that device and the widget button / background
        // task could never fetch. The id is stable (it only changes
        // on household switch / sign-out, both of which rewrite
        // it), so writing it unconditionally is safe.
        WidgetSnapshotStore.writeHouseholdId(householdId)
        if case .loaded(let result) = week,
           case .loaded(let summary) = charity {
            // Build 40 (widget sync): the household id rides along
            // in the App Group (separate key — the snapshot itself
            // carries no household identifier), so the widget
            // extension knows which household to fetch on a sync tap.
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
            // Build 51: a fresh snapshot means the widget numbers
            // are current, so a lingering failed-sync mark from an
            // earlier tap no longer applies — clear it, or the
            // button would stay red after the app itself refreshed.
            WidgetSyncStateStore.clear()
            // Build 54: gated — reload only when the snapshot
            // actually changed (a fresh snapshot here is new, so
            // this reloads; a duplicate refresh with no new data
            // does not burn the budget).
            appState.reloadWidgetTimelinesIfSnapshotChanged()
        }
    }


    // MARK: - Bank sync

    /// Plaid refresh on app open (build 50, owner Nov 20, 2026):
    /// STAGE used to refresh Plaid only on the hourly cron and on
    /// a manual sync tap — Copilot's background sync picked up new
    /// transactions while STAGE's hourly/manual sync did not fetch
    /// them (Plaid per-Item freshness). So opening the app now
    /// also triggers a Plaid sync. Throttled to once per 15
    /// minutes per household (UserDefaults) so it never hammers
    /// Plaid on every Home appear or foreground; best-effort
    /// and SILENT — no toast on success or failure, the data just
    /// refreshes when it arrives. The hourly cron stays as the
    /// backstop, and the manual sync button stays the visible
    /// path (it surfaces errors; this one never does). Reuses
    /// `isSyncing`, so a manual sync cannot overlap it (and the
    /// button honestly spins while it runs). Build 64 (F-19
    /// follow-up): the old `isAdmin` guard is gone — members get
    /// the open sync too, now that the server auth relax lets
    /// them call the sync functions; before that deploy lands, a
    /// member's 403 is swallowed here silently by design, exactly
    /// like any other background failure. Gmail is deliberately
    /// NOT added here: this silent path exists for Plaid per-Item
    /// freshness, a Plaid-specific problem, and the manual sync
    /// button now covers Gmail explicitly — a second silent Gmail
    /// check on every foreground would add edge-function calls
    /// for no visible benefit.
    public func syncBankOnOpenIfDue() async {
        guard !isSyncing else { return }
        let key = "plaid.openSyncAt.\(householdId.uuidString)"
        let last = UserDefaults.standard.double(forKey: key)
        if last > 0, Date().timeIntervalSince1970 - last < 900 { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await client.functions.plaidSyncAllowingPartialFailure(householdId: householdId)
            await refresh()
        } catch {
            // Silent: the hourly cron is the backstop, and the
            // manual sync button surfaces errors. A failed
            // background refresh must never toast on open.
        }
    }

    /// Home sync button (live.js:2842-2876, runBankSync): one sync
    /// at a time, spins while syncing. Build 64 (F-19, owner Nov
    /// 23, 2026): the sync button syncs EVERYTHING — Plaid bank
    /// AND Gmail email — and is open to members, not just admins
    /// (the old `isAdmin` guard meant members never saw a sync
    /// button, and the old path never pulled Gmail). ONE combined
    /// toast covers both halves, via `AppState.showToast`. The
    /// email half is best-effort: a failed email check never fails
    /// the bank sync, it just adds a line to the toast. Mirrors
    /// TransactionsViewModel.runSync() — same halves, same plain
    /// pre-deploy 403 line, same combined toast; only the bank
    /// text keeps Home's richer `syncToastText` (duplicate-removed
    /// line — build 65 dropped the counts and the stale line). The server auth relax (members allowed to
    /// call the sync functions) is a separate change and is NOT
    /// deployed yet — until it lands, a member's tap can come back
    /// 403, and that shows as one plain line, never the server's
    /// 403 text. The toast text is bankSyncToast
    /// (filterState.mjs:449-463).
    public func syncBank() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        // Bank half: the existing Plaid sync. A 403 here is the
        // pre-deploy server (auth relax not live yet) — plain
        // words, no reload, no technical text.
        let outcome: EdgeFunctionsClient.PlaidSyncOutcome
        do {
            outcome = try await client.functions.plaidSyncAllowingPartialFailure(householdId: householdId)
        } catch let error as OnBudgetError {
            if case .adminOnly = error {
                appState.showToast("Sync isn't available for members yet — the server update is still on its way. Try again later.", kind: .error)
            } else if case .forbidden = error {
                appState.showToast("Sync isn't available for members yet — the server update is still on its way. Try again later.", kind: .error)
            } else if error == .sessionExpired {
                appState.showSessionExpired()
            } else {
                appState.showToast("Sync failed: \(error.displayMessage)", kind: .error)
            }
            return
        } catch {
            appState.showToast("Sync failed: the server did not answer.", kind: .error)
            return
        }
        // Email half: best-effort Gmail poll alongside the bank
        // sync. A throw here never fails the sync — the toast just
        // says the email check didn't run.
        let emailText: String?
        do {
            let poll = try await client.functions.gmailPoll(householdId: householdId)
            let (text, isError) = EmailCheckMessage.text(
                topLevelError: nil,
                firstConnectionError: poll.firstError?.error,
                stored: poll.stored,
                duplicates: poll.duplicates,
                quarantined: poll.quarantined,
                unparseable: poll.unparseable,
                stale: poll.stale,
                minutesSincePreviousPoll: poll.minutesSincePreviousPoll
            )
            // Only mention email when it added something or
            // failed — a quiet "0 added" line adds nothing.
            emailText = (isError || poll.stored > 0) ? text : nil
        } catch {
            emailText = "Email check didn't run — bank sync still finished."
        }
        // ONE combined toast for both halves.
        let bankText: String
        let bankKind: ToastStyle.Kind
        switch outcome {
        case .success(let result):
            if result.noBankConnected == true {
                bankText = "No bank connection yet — connect a bank account first."
                bankKind = .error
            } else {
                bankText = Self.syncToastText(result)
                bankKind = .success
            }
        case .partial(let partial):
            // Lead with the failure (audit H-P2-7): the old text
            // opened "Sync done:" and never said what failed.
            // The counts still follow, so the partial progress
            // is not lost.
            let names = partial.failedInstitutions.isEmpty
                ? partial.failedItems.joined(separator: ", ")
                : partial.failedInstitutions.joined(separator: ", ")
            bankText = "Couldn't sync \(names): \(partial.result.added) added, \(partial.result.updated) updated, \(partial.result.skipped) skipped across \(partial.result.items) connected account(s)."
            bankKind = .error
        }
        if let emailText {
            appState.showToast("\(bankText) \(emailText)", kind: bankKind)
        } else {
            appState.showToast(bankText, kind: bankKind)
        }
        await refresh()
    }

    /// bankSyncToast (filterState.mjs:449-463). Build 65 (owner,
    /// Nov 23, 2026 — item 3): drastically shorter — the count
    /// list ("X added, Y updated, Z skipped across N connected
    /// account(s)") is gone. Nothing changed reads just "You're
    /// up to date" (no counts, no account line); a change names
    /// only the meaningful count, the new transactions. The
    /// duplicate-connection line stays: a removed connection is a
    /// real event, not a count. The stale line is dropped with the
    /// counts. The failure path (.partial in syncBank, above) is
    /// untouched — it still names what failed.
    static func syncToastText(_ out: PlaidSyncResult) -> String {
        var text: String
        if out.added > 0 {
            text = out.added == 1 ? "1 new transaction" : "\(out.added) new transactions"
        } else {
            text = "You're up to date"
        }
        if let removed = out.duplicateRemoved, !removed.isEmpty {
            text += " A duplicate bank connection was removed because those accounts are already connected on another connection. Past transactions stay."
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

/// The taller of the two iPad Home columns' heights (build 67,
/// owner Nov 23, 2026 — the two cards still were not the same
/// size): each column reports its height, the reduce takes the
/// max, and both columns render at least that tall.
private struct TwoColumnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Compact fitted sheet on iPad, full-screen cover on iPhone
/// (build 68, item 9): the Weekly and Tzedaka sheets rendered as
/// full-screen covers on iPad — a full page with ~60% empty space
/// at the bottom (the content is top-anchored with a trailing
/// Spacer). On iPad they are now a centred sheet sized to their
/// content (`.presentationSizing(.fitted)`, white presentation
/// background, visible drag indicator), so they read as a compact
/// fitted popup. iPhone keeps the full-screen cover, unchanged.
/// Only the presentation changes — the sheet content itself is
/// untouched. The drag indicator + white background are the
/// build-68 sheet standard (see item 6).
/// Build 74 (owner, Nov 24, 2026 — popup sizing): on iPhone the
/// cover content scrolls — the sheets have no ScrollView of their
/// own, and on a short screen / large text the bottom "Show
/// Transactions" button could be pushed off with no way to reach
/// it. The iPad branch is untouched (a ScrollView would break the
/// fitted sizing); swipe-right still dismisses on iPhone.
private struct FittedSheetOnIPad<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var isIPad: Bool
    @ViewBuilder var sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        if isIPad {
            content.sheet(isPresented: $isPresented) {
                sheetContent()
                    .presentationSizing(.fitted)
                    .presentationBackground(.white)
                    .presentationDragIndicator(.visible)
            }
        } else {
            content.fullScreenCover(isPresented: $isPresented) {
                ScrollView {
                    sheetContent()
                }
            }
        }
    }
}

public struct HomeView: View {
    @ObservedObject var appState: AppViewModel
    /// Owned by AppState (created at boot so the dashboard can be
    /// preloaded behind the loading screen); Home only observes
    /// it. Falls back to a fresh one if AppState has none yet.
    @ObservedObject var viewModel: HomeViewModel
    @State private var showWeeklySheet = false
    /// Build 65 (owner, Nov 23, 2026 — item 5): tapping the
    /// Tzedaka card opens the Tzedaka sheet (same fitted
    /// full-screen presentation as the Weekly sheet), not the
    /// Funds tab.
    @State private var showTzedakaSheet = false
    @State private var showPastWeeks = false
    /// Build 67 (owner, Nov 23, 2026 — the two cards still were
    /// not the same size): the taller of the two iPad columns'
    /// heights, so both columns render at exactly that height,
    /// loaded and loading. Applied as a MINIMUM, not a fixed
    /// height: a column whose content grows past it can still
    /// grow (never clipped), and the measurement then picks up
    /// the new taller height so the other column follows.
    @State private var twoColumnHeight: CGFloat? = nil
    /// Past Weeks presented from Home (build 64, F-18): its own
    /// toast + date filter, like the shell's history pages — the
    /// shell owns the Transactions-tab copies and Home cannot
    /// reach them.
    @StateObject private var pastWeeksToast = ToastState()
    @StateObject private var pastWeeksFilter = HistoryFilterState()
    @State private var showNotLoadedAlert = false
    @State private var notLoadedAlertTitle = "Weekly Budget"
    /// Build 68 (shared standard): the empty-week explainer lives
    /// behind a blue info icon, not inline in the hero — the full
    /// sentence cluttered the card. Tapping the icon reveals it.
    @State private var showEmptyWeekHint = false
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
        // Build 74 (tour): the ScrollViewReader lets the tour
        // scroll its current target into view on step change
        // (see scrollTourAnchorIntoView).
        ScrollViewReader { proxy in
            ScrollView {
            // Build 46 (owner, Nov 18, 2026 — the simpler-Home
            // mockup IS the new Home): the default layout is the
            // mockup — a Spending hero, Tzedaka as the clear second
            // card, Savings and Overspent (Past) as quiet rows.
            // Build 64 (F-40 follow-up): Simple IS the Home — the
            // stored `homeLayout` is ignored, so nobody is stuck
            // on Classic now that the Settings switch is gone.
            // `classicContent` below is retired (kept in the file
            // as the backup; restore from git if the owner ever
            // wants it back). Recent Transactions is shared by
            // both layouts.
            VStack(alignment: .leading, spacing: 12) {
                // Build 65: the page select lives in the shell
                // (AppShellView) now — one control for all tabs,
                // so Home no longer renders its own.
                // Build 49 (owner, Nov 19, 2026): when a Gmail
                // connection is in error state, email alerts have
                // stopped — Home says so out loud at the top, with a
                // tap that opens Settings where the Email Alerts card
                // carries the Reconnect button. The banner only ever
                // appears on a real error connection, never on a load
                // failure, and it sits above both Home layouts.
                if let gmailError = viewModel.gmailErrorMessage {
                    Button {
                        appState.showSettings = true
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(gmailError)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DesignTokens.errorText)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Settings")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DesignTokens.primary)
                        }
                        .padding(12)
                        .background(DesignTokens.errorBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignTokens.errorBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(gmailError) Open Settings to reconnect.")
                }
                // Build 64 (F-40 follow-up): Simple is the Home —
                // the stored `homeLayout` is ignored, so nobody is
                // stuck on Classic now that the Settings switch is
                // gone (see the note above).
                simpleContent
                // Build 64 (F-18): Past Weeks as a VISIBLE
                // destination from Home — it used to hide behind
                // the Spending card's chevron (the Weekly sheet)
                // and behind the Transactions "More" menu. A
                // quiet white row, like the quiet fund rows, so
                // closed weeks are one tap away from Home.
                pastWeeksButton
                // Recent Transactions sits on the same 10pt stack
                // gap as the cards above it (owner, Nov 16, 2026 —
                // build 40: no extra padding — the old 8pt top
                // padding on top of the 16pt gap made 24pt, which
                // read as extra white space).
                recentSection
            }
            .padding(16)
        }
        // Build 74 (tour): scroll the current step's target into
        // view on step change — the rate editor and the fund
        // cards can sit below the fold, where the cutout would
        // point at nothing visible.
        .onChange(of: appState.tour.stepIndex) { _, _ in
            scrollTourAnchorIntoView(proxy, tour: appState.tour, tab: .home)
        }
        .background(DesignTokens.background)
        // Build 36 (owner, Nov 16, 2026 — iPad): the tab reads as a
        // centered 900pt column on the regular size class (see
        // mainContentWidth), never stretched edge-to-edge.
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
        .task {
            await viewModel.refreshIfNeeded()
            // Plaid refresh on open (build 50, owner Nov 20, 2026):
            // opening the app also pulls fresh bank transactions,
            // throttled to once per 15 minutes (see
            // syncBankOnOpenIfDue) — the hourly cron is only the
            // backstop now.
            await viewModel.syncBankOnOpenIfDue()
        }
        .refreshable { await viewModel.refresh() }
        }
        // Settings dismiss (audit H-P1-5): the Settings cover sits
        // over this tab and never re-ran the load, so a just-set
        // allowance still showed the old state. Refresh when the
        // cover closes; opening it changes nothing.
        .onChange(of: appState.showSettings) { _, isShowing in
            if !isShowing { Task { await viewModel.refresh() } }
        }
        // The walkthrough trigger (build 48, owner Nov 19, 2026):
        // first entry to Home after the household is set — the week
        // has loaded, the tour has never been seen for this user +
        // household, and it is not already running. A short delay
        // lets the user see Home first. Skipping or finishing marks
        // it seen, so it shows once; re-playable from Settings
        // ("Replay Tutorial"). The onAppear covers an already-loaded
        // week (returning to Home); the onChange covers the load
        // finishing while Home is showing.
        .onAppear { maybeStartTour() }
        .onChange(of: viewModel.week.isLoaded) { _, isLoaded in
            if isLoaded { maybeStartTour() }
        }
        // Build 43 (owner, Nov 17, 2026 — item 17): full-screen
        // cover, not a detent sheet — popups are always full size.
        // Build 68 (item 9): on iPad this is a COMPACT FITTED
        // popup instead — a full-screen cover left ~60% empty
        // space at the bottom. iPhone keeps the full-screen
        // cover; see FittedSheetOnIPad above.
        .modifier(FittedSheetOnIPad(isPresented: $showWeeklySheet, isIPad: isIPad) {
            if case .loaded(let result) = viewModel.week {
                WeeklySheet(week: result, baseAllowanceCents: viewModel.allowanceCents, purchasesThisWeek: viewModel.purchasesThisWeek, appState: appState, onChanged: { Task { await viewModel.refresh() } })
                    // iPad width (owner, Nov 12 2026): WeeklySheet
                    // fixes its width to 600pt in the regular size
                    // class, so the popup opens 600pt wide and
                    // centred; on iPhone (compact) the width stays
                    // full-screen.
            }
        })
        // Build 65 (owner, Nov 23, 2026 — item 5): the Tzedaka
        // sheet — the same presentation as the Weekly sheet above
        // (compact fitted popup on iPad, full-screen cover on
        // iPhone — build 68, item 9). It needs both a loaded
        // charity summary (its numbers) and a loaded week (the
        // week start its transactions button routes to); otherwise
        // the card tap shows the not-loaded alert instead (see
        // simpleFundCard).
        .modifier(FittedSheetOnIPad(isPresented: $showTzedakaSheet, isIPad: isIPad) {
            if case .loaded(let summary) = viewModel.charity,
               case .loaded(let result) = viewModel.week {
                TzedakaSheet(summary: summary, appState: appState, onChanged: { Task { await viewModel.refresh() } })
            }
        })
        // Build 64 (F-18): Past Weeks presented from Home, same
        // full-screen cover as the Weekly sheet. Its own toast
        // overlay rides on the cover, so the week-tap toast
        // ("Showing transactions for the week of …") is visible.
        .fullScreenCover(isPresented: $showPastWeeks) {
            if let context = pastWeeksContext {
                PastWeeksView(context: context, toast: pastWeeksToast, filter: pastWeeksFilter, onBack: { showPastWeeks = false })
                    .toastOverlay(pastWeeksToast)
            }
        }
        .alert(notLoadedAlertTitle, isPresented: $showNotLoadedAlert) {
            Button("Close", role: .cancel) {}
        } message: {
            Text("\(notLoadedAlertTitle == "Weekly Budget" ? "Weekly numbers" : "\(notLoadedAlertTitle) balances") are not loaded yet. Try again in a moment.")
        }
    }

    // MARK: Home layouts (build 46)

    /// The previous Home layout (builds 40–45), preserved verbatim
    /// as the backup (owner, Nov 18, 2026 — "keep the current Home
    /// as a backup"): the Spending hero on top, Charity + Extra
    /// Fund half-width in one row below it. RETIRED in build 64
    /// (F-40 follow-up) — Simple is the Home and the stored layout
    /// value is ignored, so this is unreachable now; kept in the
    /// file as the backup (restore from git if the owner ever
    /// wants it back). The fund cards sit as ONE COMPACT UNIT (owner, Nov 16, 2026 — build 40: the white gap
    /// between the Spending hero and the Charity/Extra Fund row was
    /// "extra" and had to be removed). Build 41 (owner, Nov 16,
    /// 2026 — "much bigger and look like cards.. a small shadow
    /// below each card"): the cards are bigger and each carries its
    /// own shadow, so the gap grows to 12pt — just enough air for
    /// the shadow to read without the cards touching.
    private var classicContent: some View {
        Group {
            // Walkthrough anchors (build 54, owner Nov 21, 2026):
            // the Classic layout had NO anchors for steps 1–2 —
            // the tour pointed at nothing (tooltip at the bottom,
            // no cutout, no arrow). Mirrors the Simple layout
            // (simpleContent), where the hero carries
            // .spendingHero and the Tzedaka card carries
            // .charityCard. Only one layout is in the hierarchy
            // at a time, so the two anchor sites never conflict.
            heroCard()
                .tourAnchor(.spendingHero, tour: appState.tour)
            // Charity + Extra Fund share one row, half-width each
            // (owner, Nov 14, 2026 — supersedes the Nov 12 bigger
            // full-width stacked cards). Each card is ONE unified
            // card (owner, Nov 16, 2026 — build 40): the expanded
            // detail lives INSIDE its own card's white body, under
            // that card only — never a separate block below the row
            // (build 39 put the values under the NEIGHBOURING
            // card). One card open at a time (accordion rule
            // unchanged).
            HStack(alignment: .top, spacing: 14) {
                charityCard
                    .tourAnchor(.charityCard, tour: appState.tour)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Build 47: Savings leaves the classic Home too
                // when hidden — the Tzedaka card then takes the
                // full row width.
                if !isHiddenFromHome(.fund) {
                    fundCard
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The mockup's fund order on Home (build 46 — owner, Nov 18,
    /// 2026): Spending, Tzedaka, Savings, Overspent (Past). The
    /// layout order is FIXED in this order — the Funds page's
    /// reorderable `fundOrder` does not move Home — and prominence
    /// controls only the TREATMENT (hero / card / quiet row), never
    /// the order: heroes first, then cards, then the quiet card,
    /// each tier in this order.
    private var mockupOrder: [FundSectionID] { [.spending, .charity, .fund, .debt] }

    /// How a fund shows on the simpler Home: its stored
    /// prominence, or the mockup default (Spending hero, Tzedaka
    /// card, Savings and Overspent quiet).
    private func prominence(of section: FundSectionID) -> FundProminence {
        section.prominence(customProminence: appState.fundProminence)
    }

    /// Whether a fund is hidden from Home (build 47 — owner, Nov
    /// 19, 2026). Only Savings and Overspent (Past) can be hidden;
    /// Spending and Tzedaka are built in and always read false.
    private func isHiddenFromHome(_ section: FundSectionID) -> Bool {
        section.isHidden(customHidden: appState.fundHidden)
    }

    /// Start the first-run walkthrough if it is due (build 48):
    /// the week has loaded, the tour has never been seen for this
    /// household on this device (build 50: the STABLE
    /// per-household flag — the old key folded in the session
    /// user UUID and was read back under a different key, so the
    /// tour showed on every open), it is not already running, and
    /// the user is on the Home tab with a household set. A short
    /// delay lets the user see Home first; the guards re-run after
    /// the delay, so navigating away in that window cancels the
    /// start. Build 54: the "Show on first open" toggle (default
    /// ON, Settings → Replay Tutorial) gates the auto-start — when
    /// OFF the tour never auto-shows, but replay still works.
    private func maybeStartTour() {
        let tour = appState.tour
        guard appState.tourAutoShow else { return }
        guard viewModel.week.isLoaded else { return }
        guard !tour.isActive, !appState.tourSeen else { return }
        guard appState.selectedTab == .home, appState.householdId != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard appState.tourAutoShow else { return }
            guard viewModel.week.isLoaded else { return }
            guard !tour.isActive, !appState.tourSeen else { return }
            guard appState.selectedTab == .home else { return }
            tour.start()
        }
    }

    /// The simpler Home (build 46 — owner, Nov 18, 2026: the
    /// simpler-home-mockup layout IS the new Home): the hero fund
    /// (Spending by default) on top, then the card funds (Tzedaka
    /// by default), then ONE quiet card holding every quiet fund
    /// (Savings and Overspent (Past) by default). 14pt between the
    /// cards, like the mockup. Each fund's treatment is its stored
    /// prominence — the owner sets it from the fund's edit sheet on
    /// the Funds page — so any fund can be the hero, a card, or a
    /// quiet row. Build 47: a hidden fund leaves Home entirely
    /// (hero, card and quiet tiers all filter it out); hiding
    /// both quiet funds removes the quiet card itself.
    /// Build 65 (owner, Nov 23, 2026 — item 2): on iPad the hero
    /// and card tiers sit SIDE BY SIDE in two equal columns
    /// instead of each stretching the full 900pt column with
    /// iPhone-sized content and huge empty areas — Spending left,
    /// Tzedaka right, by default. iPhone keeps the stacked
    /// full-width layout. The two-column form applies only when
    /// both tiers are non-empty; otherwise the stacked layout
    /// stays (a lone tier keeps the full width).
    /// Build 67 (owner, Nov 23, 2026 — the cards still were not
    /// the same size): the two columns are FORCED to the same
    /// height — each column reports its height, the taller wins,
    /// and both columns render at least that tall, with each card
    /// stretching to fill its column — in BOTH the loaded state
    /// and the skeleton loading state, so the two cards are
    /// pixel-identical however much content each holds. Build 66
    /// only scaled the hero down; scaling cannot equalise two
    /// columns whose content differs (Spending has the extra
    /// "spent so far" line and the refresh row), so the height
    /// itself is equalised here instead. Build 68 (item 4): the
    /// frame stretch alone did NOT stretch the white card — the
    /// card's background stopped at its content, so the ERROR
    /// state (ErrorBox + Try Again, far shorter than a loaded
    /// body) still read as a shorter card. The hero and fund
    /// cards now carry a zero-height stretch Spacer, so the
    /// white card itself fills the equal height in loaded,
    /// loading AND error states.
    private var simpleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if useIPadTwoColumn {
                HStack(alignment: .top, spacing: 14) {
                    heroTier
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(twoColumnHeightProbe)
                        .frame(minHeight: twoColumnHeight, alignment: .top)
                    cardTier
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(twoColumnHeightProbe)
                        .frame(minHeight: twoColumnHeight, alignment: .top)
                }
                .onPreferenceChange(TwoColumnHeightKey.self) { height in
                    if height > 0 && height != twoColumnHeight {
                        twoColumnHeight = height
                    }
                }
            } else {
                heroTier
                cardTier
            }
            quietCard
        }
    }

    /// The height probe for the two-column row (build 67): each
    /// column reports its own height; the key's reduce takes the
    /// max, so `twoColumnHeight` is the taller column.
    private var twoColumnHeightProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TwoColumnHeightKey.self, value: proxy.size.height)
        }
    }

    /// The hero-tier funds, in mockup order (Spending by default).
    private var heroSections: [FundSectionID] {
        mockupOrder.filter { prominence(of: $0) == .hero && !isHiddenFromHome($0) }
    }

    /// The card-tier funds, in mockup order (Tzedaka by default).
    private var cardSections: [FundSectionID] {
        mockupOrder.filter { prominence(of: $0) == .card && !isHiddenFromHome($0) }
    }

    /// True only on iPad when both the hero and card tiers have a
    /// fund to show — the two-column condition (build 65, item 2).
    private var useIPadTwoColumn: Bool {
        isIPad && !heroSections.isEmpty && !cardSections.isEmpty
    }

    private var heroTier: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(heroSections, id: \.self) { section in
                if section == .spending {
                    heroCard(simple: true)
                        // Build 67: in the two-column row the card
                        // stretches to fill the column height, so
                        // both cards end up the same size.
                        .frame(maxHeight: useIPadTwoColumn ? .infinity : nil, alignment: .top)
                        // Build 74 (tour): the anchor sits AFTER
                        // the stretch frame, so it reports the
                        // stretched card's real height — attached
                        // inside the frame it reported the
                        // unstretched content height and the
                        // cutout came up short on iPad.
                        .tourAnchor(.spendingHero, tour: appState.tour)
                        .id(TourAnchor.spendingHero)
                } else {
                    simpleFundCard(section: section, hero: true)
                        .frame(maxHeight: useIPadTwoColumn ? .infinity : nil, alignment: .top)
                        // Build 74 (tour): same post-stretch anchor
                        // as the Spending hero above.
                        .tourAnchor(
                            section == .charity ? .charityCard
                                : (section == .spending ? .spendingHero : nil),
                            tour: appState.tour
                        )
                        .id(section == .charity ? TourAnchor.charityCard : (section == .spending ? TourAnchor.spendingHero : nil))
                }
            }
        }
    }

    private var cardTier: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(cardSections, id: \.self) { section in
                simpleFundCard(section: section, hero: false)
                    // Build 67: in the two-column row the card
                    // stretches to fill the column height, so both
                    // cards end up the same size.
                    .frame(maxHeight: useIPadTwoColumn ? .infinity : nil, alignment: .top)
                    // Build 74 (tour): the anchor sits AFTER the
                    // stretch frame (it used to live inside
                    // simpleFundCard, where it reported the
                    // unstretched content height and the cutout
                    // came up short on iPad).
                    .tourAnchor(
                        section == .charity ? .charityCard
                            : (section == .spending ? .spendingHero : nil),
                        tour: appState.tour
                    )
                    .id(section == .charity ? TourAnchor.charityCard : (section == .spending ? TourAnchor.spendingHero : nil))
            }
        }
    }

/// Build 71 (owner, Nov 24, 2026 — the two Home cards must look
/// the SAME): the ONE shared loaded body for the Spending hero and
/// the Tzedaka card — label above the amount, amount + donut row,
/// subline, then the chevron row at the bottom-right. Both cards
/// render this one view, so their elements sit at the same
/// positions by construction and cannot drift apart again. The
/// amount size and the donut size are the SAME for both cards (the
/// hero's sizes) — the different sizes were part of why the
/// sublines landed on different baselines. The fund's own colour
/// and amount weight stay (deep blue + bold for Spending, primary
/// blue + semibold for Tzedaka), so the cards keep their identity;
/// only the layout is shared. `extra` is the Spending hero's
/// debt-math / allowance lines, slotted between the subline and
/// the chevron so the chevron stays the last row; Tzedaka passes
/// an empty view.
private struct HomeCardLoadedBody<Donut: View, Subline: View, Extra: View>: View {
    let label: String
    let amountText: String
    let amountColor: Color
    let amountWeight: Font.Weight
    let amountSize: CGFloat
    let amountAccessibilityIdentifier: String
    let amountAccessibilityLabel: String
    let donut: Donut
    let subline: Subline
    let extra: Extra

    init(
        label: String,
        amountText: String,
        amountColor: Color,
        amountWeight: Font.Weight,
        amountSize: CGFloat,
        amountAccessibilityIdentifier: String,
        amountAccessibilityLabel: String,
        @ViewBuilder donut: () -> Donut,
        @ViewBuilder subline: () -> Subline,
        @ViewBuilder extra: () -> Extra
    ) {
        self.label = label
        self.amountText = amountText
        self.amountColor = amountColor
        self.amountWeight = amountWeight
        self.amountSize = amountSize
        self.amountAccessibilityIdentifier = amountAccessibilityIdentifier
        self.amountAccessibilityLabel = amountAccessibilityLabel
        self.donut = donut()
        self.subline = subline()
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.muted)
            HStack(spacing: 16) {
                Text(amountText)
                    .font(.system(size: amountSize, weight: amountWeight))
                    .foregroundStyle(amountColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .accessibilityIdentifier(amountAccessibilityIdentifier)
                    .accessibilityLabel(amountAccessibilityLabel)
                Spacer()
                donut
            }
            subline
            extra
            HStack {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#9aa3af"))
            }
        }
    }
}

/// Build 71: the ONE shared loading skeleton for the Spending hero
/// and the Tzedaka card — built from the same structure as
/// `HomeCardLoadedBody` (label block, amount + donut row, subline
/// bar, chevron row), so the two skeletons look identical and each
/// one mirrors its loaded card. Both cards pass the same sizes, so
/// the skeletons cannot drift apart either.
private struct HomeCardSkeletonBody: View {
    let amountSkeletonWidth: CGFloat
    let amountSkeletonHeight: CGFloat
    let donutSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkeletonBlock(width: 110, height: 14, cornerRadius: 6)
            HStack(spacing: 16) {
                SkeletonBlock(width: amountSkeletonWidth, height: amountSkeletonHeight, cornerRadius: 6)
                Spacer()
                SkeletonBlock(width: donutSize, height: donutSize, cornerRadius: donutSize / 2)
            }
            SkeletonBlock(width: 180, height: 14, cornerRadius: 6)
            HStack {
                Spacer()
                SkeletonBlock(width: 13, height: 13, cornerRadius: 3)
            }
        }
    }
}

    // MARK: Hero — Weekly Budget

    // Hero — Weekly Budget. Bigger and more prominent than the
    // other cards (owner, Nov 11, 2026: it is the most important
    // number on the page). Build 64 (C-2 B2): the header is plain
    // white — the name in deep blue, a small deep-blue glyph, no
    // solid banner, no thin rule — and the WHITE body below (the
    // MAJORITY of the card) holds the big amount + the progress
    // circle side by side, with the spent line below. The sync
    // button stays at the trailing end of the header. The loading
    // state renders at the same full hero size (shimmer skeleton
    // blocks on WHITE, no tint, no spinner), so the layout never
    // jumps when the number arrives.
    private func heroCard(simple: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header strip (colored, short): ONE ROW — icon + name
            // + sync button. While loading or failed the strip is
            // white / muted grey, not blue.
            heroHeaderStrip(simple: simple)
            // White body (majority): big amount + progress circle
            // side by side, spent line below, then the debt math
            // line / allowance states.
            heroWhiteBody(simple: simple)
            // Build 68 (item 4 — equal height in ALL states): the
            // stretch spacer. The two-column row stretches this
            // card's FRAME to the taller column (minHeight +
            // maxHeight: .infinity in heroTier), but a VStack with
            // no flexible child sizes to its content — so the
            // white background stopped at the content and the
            // card READ short whenever its content was short
            // (the error state: ErrorBox + Try Again is far
            // shorter than the loaded body). The zero-height
            // spacer absorbs any extra height the frame offers,
            // so the white card itself stretches to the equal
            // height in loaded, loading AND error states. It
            // takes no space when no extra height is offered
            // (iPhone stacked layout), so nothing else moves.
            Spacer(minLength: 0)
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

    /// White body of the hero (the majority of the card): the big
    /// amount + the progress circle side by side, the spent line
    /// below, then the debt math line / allowance states when
    /// present. While loading the amount + circle + spent-line
    /// skeletons sit here (same sizes as the loaded content, so
    /// the body holds its size); while failed the error box + Try
    /// Again sit here. Build 41 (owner, Nov 16, 2026 — "much
    /// bigger"): the body breathes more — 20pt sides, 16pt top,
    /// 18pt bottom, 16pt between rows. Build 42 (owner, Nov 17,
    /// 2026 — "the white body should be double the header"): the
    /// body dominates — roughly 1/3 header, 2/3 white body — so
    /// the top/bottom padding steps up to 36pt and the rows sit
    /// 18pt apart. The header is untouched; the card gets taller.
    /// Build 46 (owner, Nov 18, 2026): the amount lives here now
    /// (it was inline in the header strip in builds 40–45), at
    /// the biggest size the card allows, with the progress circle
    /// alongside it — the horizontal progress bar is gone.
    private func heroWhiteBody(simple: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            switch viewModel.week {
            case .loading:
                // Build 46 (owner, Nov 18, 2026): the skeletons
                // match the loaded body — a big amount-sized block
                // + a circle + the spent line — so the body holds
                // its size while loading. Build 70: the "Available"
                // label block sits above the amount skeleton (the
                // loaded body has the label now), so the loading
                // card holds the same height as the loaded one.
                // Build 71: the simple hero renders the ONE shared
                // skeleton (HomeCardSkeletonBody) — the same view
                // the Tzedaka card renders — so the two skeletons
                // look identical. The retired classic hero keeps
                // its own blocks below.
                if simple {
                    HomeCardSkeletonBody(amountSkeletonWidth: heroAmountSkeletonWidth, amountSkeletonHeight: heroAmountSkeletonHeight, donutSize: heroDonutSize)
                } else {
                    HStack(spacing: 16) {
                        SkeletonBlock(width: heroAmountSkeletonWidth, height: heroAmountSkeletonHeight, cornerRadius: 6)
                        Spacer()
                        SkeletonBlock(width: heroDonutSize, height: heroDonutSize, cornerRadius: heroDonutSize / 2)
                    }
                    SkeletonBlock(width: 180, height: 14, cornerRadius: 6)
                }
            case .failed(let error):
                // One failure message only: the ErrorBox. The grey
                // "Could not load…" line above it said the same
                // thing twice (audit H-P2-4). Build 71: the 6pt
                // spacing matches the Tzedaka card's failed body,
                // so the error states look the same too.
                VStack(alignment: .leading, spacing: 6) {
                    ErrorBox(weekErrorText(error))
                    Button("Try Again") { Task { await viewModel.refresh() } }
                        .buttonStyle(TertiaryButtonStyle())
                }
            case .loaded(let result):
                if simple {
                    // Build 71: the simple hero's extra lines
                    // (debt math, allowance states) ride INSIDE
                    // the shared card body now — heroBodyAmountDonut
                    // passes them as the `extra` slot — so the
                    // chevron stays the last row, as on Tzedaka.
                    heroBodyAmountDonut(result, simple: true)
                } else {
                    heroBodyAmountDonut(result, simple: false)
                    heroLoadedContent(result)
                }
            }
        }
        .padding(.horizontal, 20)
        // Build 66 (owner, Nov 23, 2026 — iPad two-column): the
        // full-width 36pt top/bottom padding makes the half-width
        // Spending card tall and empty next to the Tzedaka card —
        // 20pt in two columns keeps the two cards balanced.
        // Build 69 (owner, Nov 24, 2026 — the Spending card on
        // iPhone is too tall, lots of empty space): the 36pt
        // padding is too much on iPhone too — 20pt, matching the
        // two-column value and the Tzedaka card's compact body
        // (18/20pt), so the card fits its content. Full-width
        // iPad keeps 36pt.
        .padding(.top, useIPadTwoColumn ? 20 : (isIPad ? 36 : 20))
        .padding(.bottom, useIPadTwoColumn ? 20 : (isIPad ? 36 : 20))
    }

    // Build 64 (C-2 B2): the solid deep-blue banner is gone, so
    // the heroBannerColor / heroBannerTextColor helpers are deleted
    // with it — the header is plain white, the name in deep blue.
    // (The helpers used to live here; see git history.)

    /// The hero amount + donut sizes (build 64, C-1 — QUIETER:
    /// the owner picked the maturity option over "numbers as big
    /// as they can be"): the amount is 36pt bold on iPhone
    /// (56-64pt on iPad — 60pt here), down from 52pt heavy /
    /// 96pt, and the loading skeleton height matches the amount's
    /// line height, so the body holds its size while loading.
    /// Build 66 (owner, Nov 23, 2026 — iPad two-column): in the
    /// half-width two-column layout the full-width iPad sizes
    /// make the Spending card tall and empty next to the Tzedaka
    /// card, and the 320pt amount skeleton overflows the column
    /// (it forced the whole Home wider than the screen while
    /// loading — labels clipped on both edges). In two columns
    /// the hero scales down — 48pt amount, 96pt donut, 56pt
    /// skeleton height — so the two cards balance, and the
    /// loading skeleton (160pt amount + 96pt donut) fits the
    /// narrowest iPad column with room to spare. iPhone and the
    /// full-width iPad hero are untouched.
    private var heroAmountSize: CGFloat { useIPadTwoColumn ? 48 : (isIPad ? 60 : 36) }
    private var heroAmountSkeletonHeight: CGFloat { useIPadTwoColumn ? 56 : (isIPad ? 72 : 44) }
    private var heroDonutSize: CGFloat { useIPadTwoColumn ? 96 : (isIPad ? 120 : 88) }
    /// The loading amount-skeleton width (build 66): 160pt in the
    /// two-column layout — 160 + 16 + 96 (donut) = 272pt, inside
    /// the narrowest iPad column's ~309pt body width — so the
    /// skeleton can never force the page wider than the screen.
    private var heroAmountSkeletonWidth: CGFloat { useIPadTwoColumn ? 160 : (isIPad ? 320 : 200) }

    // Hero header — icon + title in ONE row (build 71: NO trailing
    // control any more — the sync button moved to the shell top
    // bar, so this header is the same height as the Tzedaka
    // card's header and the two cards' elements line up).
    // Build 64 (C-2 B2 — "Coloured name, no line"): the solid
    // deep-blue banner is GONE — the header is plain white, the
    // name "Spending" is written in its own deep blue #1d4ed8 at
    // 17pt semibold, and the icon is a small 20pt deep-blue glyph
    // directly on white (P-6 — the white-circle disc is gone).
    // "Available" is the amount's label in the body (build 70),
    // not the header. While failed the name keeps its
    // colour (the name is local); the failed signal is the error
    // box in the body below.
    private func heroHeaderStrip(simple: Bool = false) -> some View {
        HStack(spacing: 8) {
            // The icon + name are LOCAL — they render in every
            // state (loading, loaded, failed), never as skeletons.
            // Only the number in the body below waits on the data.
            Image(systemName: FundSectionID.spending.resolvedIconName(customIcons: appState.fundIcons))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(StatCardTheme.spending.number)
                .frame(width: 22, height: 22)
            Text(FundSectionID.spending.displayName(customNames: appState.fundNames))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StatCardTheme.spending.number)
                .lineLimit(1)
            Spacer()
            // Build 71: NO trailing control here any more. The
            // sync button lived in this header (build 48) and its
            // 44pt frame made the Spending header taller than the
            // Tzedaka header — the main reason the two cards
            // looked different. The button now lives in the shell
            // top bar (AppShellView, Home tab only); the header
            // here is icon + name only, like the Tzedaka card's.
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func weekErrorText(_ error: OnBudgetError) -> String {
        switch error {
        case .networkOffline, .timedOut, .networkError:
            return "Couldn't update this week's numbers — check your connection and try again."
        default:
            return "Couldn't update this week's numbers — tap Try Again to reload."
        }
    }

    /// The hero content in the WHITE body below the amount + donut
    /// (debt math, allowance states): the amount lives in the white
    /// body now (build 46, owner Nov 18, 2026 — it was inline in
    /// the header strip in builds 40–45), and the progress bar is
    /// gone — the circle beside the amount carries the progress —
    /// so this starts at the debt math line. The date is gone from
    /// the card entirely, and the Weekly Allowance + Purchases
    /// stats moved into the Weekly sheet (owner, Nov 14, 2026).
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
        // never while loading or on failure. Build 68 (shared
        // standard): the short line stays, the guidance ("Add one
        // by hand, or connect a bank account…") lives behind a
        // brand-blue info icon — the full sentence cluttered the
        // hero card. Tapping the icon reveals it; tapping again
        // hides it. The icon button wins over the card's tap
        // gesture, so it never opens the Weekly sheet by accident.
        if viewModel.allowanceSet == true,
           (viewModel.purchasesThisWeek ?? 1) == 0, result.chargesCents == 0 {
            HStack(alignment: .top, spacing: 4) {
                Text("No transactions this week yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Button { showEmptyWeekHint.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showEmptyWeekHint ? "Hide explanation" : "Why is the full allowance still available?")
            }
            if showEmptyWeekHint {
                Text("The full allowance is still available. Add one by hand, or connect a bank account in Settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
        }
    }

    /// Big amount + progress circle, in the hero's WHITE body
    /// (build 46, owner Nov 18, 2026). Build 71: the simple hero
    /// renders the shared HomeCardLoadedBody — the chevron is a
    /// row below the spent line now, as on the Tzedaka card (the
    /// retired classic hero keeps its inline chevron). The amount
    /// moved DOWN out
    /// of the header strip into the body (build 64, C-1: 36pt bold
    /// on iPhone / 60pt iPad — see heroAmountSize), with the
    /// widget's progress CIRCLE alongside it — the horizontal
    /// progress bar is gone. The spent line sits below
    /// the pair, with the chevron at its right end (the hint that
    /// the card opens the Weekly sheet). Same math as the old bar:
    /// charges / capacity, capped at 100%; over budget the ring is
    /// full and red, and the amount reads in the over-budget red
    /// (it sits on WHITE now, so the red reads — unlike on the old
    /// blue header, where it did not). While no allowance is set
    /// the spent line reads "Not set" — a genuinely unset value,
    /// never a bare dash (owner loading/empty language, Nov 12,
    /// 2026). A failed allowance read (nil) still shows
    /// compute-week's numbers — only an explicit never-set hides
    /// them (audit H-P1-4).
    @ViewBuilder
    private func heroBodyAmountDonut(_ result: WeekResult, simple: Bool = false) -> some View {
        let capacity = result.baseAvailableCents + result.tempCents
        let overBudget = SpendingProgress.isOverBudget(chargesCents: result.chargesCents, capacityCents: capacity)
        let fraction = SpendingProgress.fraction(chargesCents: result.chargesCents, capacityCents: capacity)
        if simple {
            // Build 71: the simple hero renders the ONE shared
            // Home card body (HomeCardLoadedBody) — the same view
            // the Tzedaka card renders — so the two cards'
            // elements sit at the same positions. The "Available"
            // label (build 70) stays above the amount, mirroring
            // the Tzedaka card's "Ready to give". On iPhone the
            // label + amount must not crowd or wrap — the label is
            // short and the amount already scales
            // (minimumScaleFactor 0.5).
            HomeCardLoadedBody(
                label: "Available",
                amountText: MoneyFormat.amountText(cents: result.availableCents, isMoneyIn: false),
                // Build 64 (C-1 + C-2 B2): 36pt bold (was 52pt
                // heavy), in the Spending name colour — deep blue
                // #1d4ed8. Over budget the amount is red — the
                // over-budget signal is never lost.
                amountColor: overBudget ? DesignTokens.heroOverBudget : StatCardTheme.spending.number,
                amountWeight: .bold,
                amountSize: heroAmountSize,
                amountAccessibilityIdentifier: "home.heroAmount",
                amountAccessibilityLabel: result.availableCents < 0
                    ? "\(FundSectionID.spending.displayName(customNames: appState.fundNames)), over budget by \(MoneyFormat.string(cents: -result.availableCents)), show breakdown"
                    : "\(FundSectionID.spending.displayName(customNames: appState.fundNames)), \(MoneyFormat.string(cents: result.availableCents)) left this week, show breakdown",
                donut: {
                    spendingDonut(fraction: fraction, overBudget: overBudget, size: heroDonutSize, showUsedLabel: true)
                },
                subline: {
                    // The simpler Home (build 46 — the mockup): the
                    // spent line reads "$236.42 spent so far" — the
                    // spent figure in bold ink, "spent so far"
                    // muted — and NO "· 59% used", because the ring
                    // beside the amount already shows the
                    // percentage. While no allowance is set the line
                    // reads "Not set".
                    if viewModel.allowanceSet != false {
                        HStack(spacing: 0) {
                            Text(MoneyFormat.string(cents: result.chargesCents))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DesignTokens.ink)
                            Text(" spent so far")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.muted)
                        }
                    } else {
                        Text("Not set")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignTokens.muted)
                    }
                },
                extra: {
                    heroLoadedContent(result)
                }
            )
        } else {
            // The retired classic hero (unchanged): the amount +
            // donut, then the spent line + % used + chevron. Same
            // math as the old bar: charges / capacity, capped at
            // 100%; over budget the ring is full and red, and the
            // amount reads in the over-budget red (it sits on
            // WHITE now, so the red reads — unlike on the old blue
            // header, where it did not).
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Text(MoneyFormat.amountText(cents: result.availableCents, isMoneyIn: false))
                        .font(.system(size: heroAmountSize, weight: .bold))
                        .foregroundStyle(overBudget ? DesignTokens.heroOverBudget : StatCardTheme.spending.number)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .accessibilityIdentifier("home.heroAmount")
                        .accessibilityLabel(
                            result.availableCents < 0
                                ? "\(FundSectionID.spending.displayName(customNames: appState.fundNames)), over budget by \(MoneyFormat.string(cents: -result.availableCents)), show breakdown"
                                : "\(FundSectionID.spending.displayName(customNames: appState.fundNames)), \(MoneyFormat.string(cents: result.availableCents)) left this week, show breakdown"
                        )
                    Spacer()
                    spendingDonut(fraction: fraction, overBudget: overBudget, size: heroDonutSize, showUsedLabel: false)
                }
                // Spent line + % used + chevron. While no allowance is
                // set the line reads "Not set".
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
    }

    /// Progress circle, like the widget's donut (build 46, owner
    /// Nov 18, 2026): the spent slice in brand blue, over budget
    /// the muted red #991b1b (full ring), the remaining slice pale
    /// light blue #dbeafe, the spent percentage in the centre. Same
    /// colours as OnBudgetWidget.donut, so the card and the widget
    /// can never drift apart. Build 64 (P-6): the ring is THIN
    /// now — 5pt on iPhone and iPad (was 12/14pt) — a hairline
    /// track, not a thick coloured band. In the simpler Home
    /// the centre also carries "used" under the percentage, like
    /// the mockup's ring (59% over "used").
    private func spendingDonut(fraction: Double, overBudget: Bool, size: CGFloat, showUsedLabel: Bool = false) -> some View {
        let lineWidth: CGFloat = 5
        let percent = Int((fraction * 100).rounded())
        return ZStack {
            Circle()
                .stroke(Color(hex: "#dbeafe"), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    overBudget ? DesignTokens.heroOverBudget : DesignTokens.primary,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: fraction >= 1 ? .butt : .round)
                )
                .rotationEffect(.degrees(-90))
            if showUsedLabel {
                VStack(spacing: 0) {
                    Text("\(percent)%")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(DesignTokens.ink)
                    Text("used")
                        .font(.system(size: size * 0.125))
                        .foregroundStyle(DesignTokens.muted)
                }
            } else {
                Text("\(percent)%")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(DesignTokens.ink)
            }
        }
        .frame(width: size, height: size)
        .accessibilityIdentifier("home.heroDonut")
        .accessibilityLabel("\(percent) percent of the weekly budget used")
    }

    private func usedPercentText(result: WeekResult, capacity: Int) -> String {
        if result.chargesCents == 0 { return "0% used" }
        if capacity <= 0 { return "Over budget" }
        let percent = Int((Double(result.chargesCents) / Double(capacity) * 100).rounded())
        return percent > 100 ? "Over budget" : "\(percent)% used"
    }

    // MARK: Simpler Home — fund card + quiet rows

    // Build 64 (C-2 B2): simpleCharityBanner is DELETED — there
    // is no solid Tzedaka banner any more. The name is written in
    // primary blue #2f6bff on white (theme.number), like every
    // other fund's name in its own colour. (The helper used to
    // live here; see git history.)

    /// The loaded body data for a fund's simple card: the small
    /// label above the amount, the amount itself, and the sub-line
    /// below it (nil when the fund has no sub-line). Nil while the
    /// fund's numbers are still loading (the caller shows
    /// skeletons); a failed load is `simpleCardFailed`, not nil.
    private func simpleCardData(for section: FundSectionID) -> (label: String, amountText: String, subText: String?)? {
        switch section {
        case .spending:
            guard case .loaded(let result) = viewModel.week else { return nil }
            let capacity = result.baseAvailableCents + result.tempCents
            return (
                // Build 70 (owner, Nov 24, 2026): the label is
                // "Available", matching the hero's label above the
                // amount (the old "Left to spend" is gone) — the
                // same word the Savings card already uses.
                label: "Available",
                amountText: MoneyFormat.amountText(cents: result.availableCents, isMoneyIn: false),
                subText: "\(MoneyFormat.string(cents: result.chargesCents)) spent · \(usedPercentText(result: result, capacity: capacity))"
            )
        case .charity:
            guard case .loaded(let summary) = viewModel.charity else { return nil }
            let rate = summary.defaultRateBp / 100
            return (
                label: "Ready to give",
                amountText: MoneyFormat.signedString(cents: summary.remainingCents),
                subText: rate > 0 ? "Set aside for you — \(rate)% of income" : "Set aside for you"
            )
        case .fund:
            guard case .loaded(let summary) = viewModel.fund else { return nil }
            let pending = summary.pendingIncludingHeldCents + viewModel.pendingTopupsCents
            return (
                label: "Available",
                amountText: MoneyFormat.signedString(cents: summary.availableCents),
                subText: pending > 0 ? "\(MoneyFormat.string(cents: pending)) pending" : nil
            )
        case .debt:
            guard case .loaded(let result) = viewModel.week else { return nil }
            return (
                label: "Still Owed",
                amountText: MoneyFormat.signedString(cents: result.carriedDebtCents),
                subText: nil
            )
        }
    }

    /// Whether a fund's simple card is in the FAILED state (the
    /// caller shows the ErrorBox + Try Again).
    private func simpleCardFailed(for section: FundSectionID) -> Bool {
        switch section {
        case .spending, .debt:
            if case .failed = viewModel.week { return true }
            return false
        case .charity:
            if case .failed = viewModel.charity { return true }
            return false
        case .fund:
            if case .failed = viewModel.fund { return true }
            return false
        }
    }

    /// A full-width fund card in the simpler Home (build 46 — the
    /// mockup): build 64 (C-2 B2) — NO solid header banner any
    /// more. The header is plain white: a small 20pt glyph in the
    /// fund's own colour + the fund NAME in that colour at 17pt
    /// semibold (Spending deep blue, Tzedaka primary blue, Savings
    /// muted grey, Overspent ink), and the WHITE body below holds
    /// the label, the big amount in the same colour, the sub-line,
    /// and a faint chevron at the bottom-right. `hero: true` is
    /// the same card with the hero-sized amount (a non-Spending
    /// fund set to hero — the ring stays Spending-only, so a hero
    /// card has no ring and no chevron). Tapping a card opens its
    /// fund on the Funds tab — EXCEPT Tzedaka (build 65, owner
    /// Nov 23, 2026 — item 5): tapping the Tzedaka card opens
    /// the Tzedaka sheet instead, like the Spending hero opens
    /// the Weekly sheet. A Tzedaka tap while charity is still
    /// loading (or failed) shows the not-loaded alert, like the
    /// retired stat cards did — the sheet needs loaded numbers.
    /// The header renders immediately —
    /// the name and icon are local — only the body waits on the
    /// numbers.
    private func simpleFundCard(section: FundSectionID, hero: Bool) -> some View {
        let theme = section.theme
        let name = section.displayName(customNames: appState.fundNames)
        // Build 71: the two Home cards (Spending + Tzedaka) share
        // the hero amount size — different sizes were part of why
        // their sublines landed on different baselines. Savings /
        // Overspent keep the compact card size.
        // Build 64 (C-1): fund amounts are 30pt semibold on
        // iPhone (32pt iPad), down from 42pt heavy / 64pt; a hero
        // card takes the hero size (36/60pt).
        let amountSize: CGFloat = (section == .spending || section == .charity || hero) ? heroAmountSize : (isIPad ? 32 : 30)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: section.resolvedIconName(customIcons: appState.fundIcons))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.number)
                    .frame(width: 22, height: 22)
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.number)
                    // Build 50 (owner, Nov 20, 2026 — iPhone
                    // readability): the name wraps to a second line
                    // rather than shrinking — one uniform 17pt on
                    // every card, nothing cut off. The old 0.85
                    // minimumScaleFactor made long names render
                    // smaller than short ones.
                    .lineLimit(2)
                Spacer()
                // Build 48 (owner, Nov 19, 2026): the remove
                // control lives ON the card — an eye-off button in
                // the header, admin-only, only for the funds that
                // can leave Home (Savings, Overspent). Spending and
                // Tzedaka always stay, so they get no button. A
                // child Button wins over the card's tap gesture, so
                // tapping the eye hides while tapping the card still
                // opens the fund. The fund is put back from its
                // Funds card ("Show on Home").
                if section.canHideFromHome, viewModel.isAdmin {
                    Button {
                        Task {
                            if await viewModel.hideFundFromHome(section: section) {
                                appState.showToast("Hidden from Home. Find it on the Funds tab to put it back.", kind: .success)
                            } else {
                                appState.showToast("Could not hide \(name).", kind: .error)
                            }
                        }
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignTokens.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide \(name) from Home")
                    .accessibilityIdentifier("home.hideFund.\(section.rawValue)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 6) {
                if let data = simpleCardData(for: section) {
                    if section == .charity {
                        // Build 71: the Tzedaka card renders the
                        // ONE shared Home card body
                        // (HomeCardLoadedBody) — the same view the
                        // Spending hero renders — so the two cards'
                        // elements sit at the same positions. The
                        // ring (build 47, owner Nov 19, 2026) is
                        // the amount + the Given ring side by side,
                        // like the Spending hero's amount + ring.
                        // The big number stays the Available
                        // ("left to give").
                        HomeCardLoadedBody(
                            label: data.label,
                            amountText: data.amountText,
                            amountColor: theme.number,
                            amountWeight: .semibold,
                            amountSize: amountSize,
                            amountAccessibilityIdentifier: "home.tzedakaAmount",
                            amountAccessibilityLabel: data.amountText,
                            donut: {
                                charityDonut(fraction: charityGivenFraction(), size: heroDonutSize)
                            },
                            subline: {
                                if let subText = data.subText {
                                    Text(subText)
                                        .font(.system(size: 14))
                                        .foregroundStyle(DesignTokens.muted)
                                }
                            },
                            extra: {
                                EmptyView()
                            }
                        )
                    } else {
                        Text(data.label)
                            .font(.system(size: 14))
                            .foregroundStyle(DesignTokens.muted)
                        simpleAmountText(data.amountText, amountSize: amountSize, section: section, theme: theme)
                        if let subText = data.subText {
                            Text(subText)
                                .font(.system(size: 14))
                                .foregroundStyle(DesignTokens.muted)
                        }
                        if !hero {
                            HStack {
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: "#9aa3af"))
                            }
                        }
                    }
                } else if simpleCardFailed(for: section) {
                    ErrorBox("Could not load \(name).")
                    Button("Try Again") { Task { await viewModel.refresh() } }
                        .buttonStyle(TertiaryButtonStyle())
                } else {
                    // Build 71: the Tzedaka card shares the ONE
                    // skeleton (HomeCardSkeletonBody) — the same
                    // view the Spending hero renders — so the two
                    // skeletons look identical. The other cards
                    // keep their own (no ring). Build 69 (owner,
                    // Nov 24, 2026 — the skeletons must mirror
                    // their loaded cards exactly): the label block,
                    // the amount + ring row, the subline bar AND
                    // the chevron row — the loaded card has a
                    // chevron, so the skeleton holds its height
                    // while loading instead of growing ~24pt when
                    // the chevron arrives.
                    if section == .charity {
                        HomeCardSkeletonBody(amountSkeletonWidth: heroAmountSkeletonWidth, amountSkeletonHeight: heroAmountSkeletonHeight, donutSize: heroDonutSize)
                    } else {
                        SkeletonBlock(width: 110, height: 14, cornerRadius: 6)
                        SkeletonBlock(width: 180, height: amountSize + 8, cornerRadius: 6)
                        SkeletonBlock(width: 180, height: 14, cornerRadius: 6)
                        // The chevron row (loaded only when !hero) —
                        // without it the skeleton card reads ~24pt
                        // shorter than the loaded card.
                        if !hero {
                            HStack {
                                Spacer()
                                SkeletonBlock(width: 13, height: 13, cornerRadius: 3)
                            }
                        }
                    }
                }
            }
            // Build 71: the two Home cards (Spending + Tzedaka)
            // share the Spending hero's body padding (20/20/20),
            // so their elements sit at the same positions.
            // Savings / Overspent keep the compact card padding.
            .padding(.horizontal, (section == .spending || section == .charity) ? 20 : (hero ? 16 : 18))
            .padding(.top, (section == .spending || section == .charity) ? 20 : (hero ? 24 : 18))
            .padding(.bottom, (section == .spending || section == .charity) ? 20 : (hero ? 22 : 20))
            // Build 68 (item 4 — equal height in ALL states): the
            // stretch spacer, same as the hero card's — the
            // two-column row stretches this card's FRAME to the
            // taller column, but without a flexible child the
            // white background stops at the content, so the
            // short error body (ErrorBox + Try Again) read as a
            // shorter card than the loaded Tzedaka card. The
            // zero-height spacer absorbs the extra height, so
            // the white card stretches to the equal height in
            // loaded, loading AND error states, and takes no
            // space when no extra height is offered.
            Spacer(minLength: 0)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fundCardShadow()
        .contentShape(Rectangle())
        .onTapGesture {
            if section == .charity {
                switch viewModel.charity {
                case .loaded:
                    // The sheet also routes its transactions button
                    // by week start, so a failed week keeps the
                    // alert instead of opening a sheet whose button
                    // would go nowhere.
                    if case .loaded = viewModel.week {
                        showTzedakaSheet = true
                    } else {
                        notLoadedAlertTitle = "Weekly Budget"
                        showNotLoadedAlert = true
                    }
                case .loading, .failed:
                    notLoadedAlertTitle = FundSectionID.charity.displayName(customNames: appState.fundNames)
                    showNotLoadedAlert = true
                }
            } else {
                appState.openFund(section)
            }
        }
        // Walkthrough anchors (build 48): the Tzedaka card for the
        // charity step, and the Spending card for the one-number
        // step when Spending is a card rather than the hero (the
        // hero itself carries the anchor in simpleContent).
        // Build 74: the anchor itself moved OUT of here to the
        // heroTier / cardTier call sites, AFTER the stretch frame
        // — attached here it reported the unstretched content
        // height and the cutout came up short on iPad. This
        // comment stays so the next reader knows where it went.
        .accessibilityIdentifier(section == .charity ? "home.tzedakaCard" : "home.simpleCard.\(section.rawValue)")
        .accessibilityLabel(
            simpleCardData(for: section).map { "\(name), \($0.amountText), show fund" } ?? "\(name), loading"
        )
        // (Build 74: the tour anchor moved out — see the comment
        // above the accessibilityIdentifier, and the heroTier /
        // cardTier call sites.)
    }

    /// The Tzedaka ring fraction (build 47, owner Nov 19, 2026):
    /// Given / Committed, ALL TIME (cumulative since Nov 1,
    /// 2026 — the card's figures are cumulative, so the ring is
    /// too). 0 while loading or when Committed is $0 (no income
    /// yet) — the ring shows empty, never a crash (the fraction
    /// clamps 0...1 and returns 0 for a zero denominator).
    private func charityGivenFraction() -> Double {
        guard case .loaded(let summary) = viewModel.charity else { return 0 }
        return SpendingProgress.fraction(chargesCents: summary.givenCents, capacityCents: summary.committedCents)
    }

    /// Progress circle for the Tzedaka card (build 47, owner Nov
    /// 19, 2026 — the Tzedaka card gets a ring like Spending's,
    /// showing how much of the charity Committed has been Given):
    /// the given slice in Tzedaka blue #2f6bff, the remaining
    /// slice pale light blue #dbeafe (the same track as
    /// Spending's ring), the given percentage in the centre with
    /// "given" under it, like Spending's "used". Build 64 (P-6):
    /// the ring is THIN now — 5pt (was 12/14pt).
    private func charityDonut(fraction: Double, size: CGFloat) -> some View {
        let lineWidth: CGFloat = 5
        let percent = Int((fraction * 100).rounded())
        return ZStack {
            Circle()
                .stroke(Color(hex: "#dbeafe"), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    DesignTokens.primary,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: fraction >= 1 ? .butt : .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(percent)%")
                    .font(.system(size: size * 0.22, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(DesignTokens.ink)
                Text("given")
                    .font(.system(size: size * 0.125))
                    .foregroundStyle(DesignTokens.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityIdentifier("home.tzedakaDonut")
        .accessibilityLabel("\(percent) percent of charity given")
    }

    /// The big amount text for a simple card (build 47 — the
    /// Tzedaka amount is shared by the plain and the ring
    /// layouts, so it lives once here). Build 64 (C-1): semibold,
    /// not heavy; the colour is the fund's own (theme.number) —
    /// the B2 rule that the amount matches the name.
    private func simpleAmountText(_ text: String, amountSize: CGFloat, section: FundSectionID, theme: StatCardTheme) -> some View {
        Text(text)
            .font(.system(size: amountSize, weight: .semibold))
            .foregroundStyle(theme.number)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityIdentifier(section == .charity ? "home.tzedakaAmount" : "home.simpleAmount.\(section.rawValue)")
    }

    /// The amount for a quiet row: the fund's headline figure
    /// (Savings = Available, Overspent = the carried debt, Tzedaka
    /// = Ready to give, Spending = Left to spend). Nil while its
    /// source is still loading (the caller shows a skeleton row).
    private func quietAmountText(for section: FundSectionID) -> String? {
        switch section {
        case .spending:
            guard case .loaded(let result) = viewModel.week else { return nil }
            return MoneyFormat.signedString(cents: result.availableCents)
        case .charity:
            guard case .loaded(let summary) = viewModel.charity else { return nil }
            return MoneyFormat.signedString(cents: summary.remainingCents)
        case .fund:
            guard case .loaded(let summary) = viewModel.fund else { return nil }
            return MoneyFormat.signedString(cents: summary.availableCents)
        case .debt:
            guard case .loaded(let result) = viewModel.week else { return nil }
            return MoneyFormat.signedString(cents: result.carriedDebtCents)
        }
    }

    /// ONE white card holding every quiet fund (build 46 — the
    /// mockup's Savings + Overspent (Past) rows): a hairline
    /// divider between rows, each row a small icon circle, the
    /// name, the amount in muted grey, and a faint chevron.
    /// Renders only when at least one fund is quiet. Each row
    /// loads independently — a slow fund shows a skeleton row
    /// while the others already read.
    @ViewBuilder
    private var quietCard: some View {
        let quiet = mockupOrder.filter { prominence(of: $0) == .quiet && !isHiddenFromHome($0) }
        if !quiet.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(quiet.enumerated()), id: \.element) { index, section in
                    quietRow(section)
                    if index < quiet.count - 1 {
                        Rectangle()
                            .fill(Color(hex: "#e7eaee"))
                            .frame(height: 0.5)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .fundCardShadow()
            .accessibilityIdentifier("home.quietCard")
        }
    }

    /// One quiet row (build 46 — the mockup): build 64 (P-6) — a
    /// small 20pt glyph in the fund's own colour directly on
    /// white, NO coloured circle disc; the fund name, the amount
    /// in muted grey, and a faint chevron. Tapping the row opens
    /// its fund on the Funds tab. A failed row reads "Couldn't
    /// load" in error red (its fund's ErrorBox + Try Again live
    /// on the Funds page).
    private func quietRow(_ section: FundSectionID) -> some View {
        let name = section.displayName(customNames: appState.fundNames)
        let failed = simpleCardFailed(for: section)
        let amount = quietAmountText(for: section)
        return Button { appState.openFund(section) } label: {
            HStack(spacing: 12) {
                // The icon + name render in EVERY state — loaded,
                // loading, and failed (build 47, owner Nov 19,
                // 2026: "The other 2 funds should also have
                // theirs colors, although they're collapsed" — the
                // icon and name are local, so the row shows its
                // colour from the first paint; only the amount
                // waits on the numbers). Build 64 (P-6): the glyph
                // sits directly on white in the fund's own colour
                // (theme.number) — the old coloured disc is gone.
                Image(systemName: section.resolvedIconName(customIcons: appState.fundIcons))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(section.theme.number)
                    .frame(width: 22, height: 22)
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: "#3c4654"))
                    .lineLimit(1)
                Spacer()
                if failed {
                    Text("Couldn't load")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.errorText)
                } else if let amount {
                    Text(amount)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.muted)
                } else {
                    // Loading: only the amount is a skeleton — the
                    // icon + name above already show the fund.
                    SkeletonBlock(width: 60, height: 15, cornerRadius: 6)
                }
                // Build 48 (owner, Nov 19, 2026): the remove control
                // lives ON the row — an eye-off button, admin-only,
                // only for the funds that can leave Home (Savings,
                // Overspent). A child Button wins over the row's
                // tap, so tapping the eye hides while tapping the
                // row still opens the fund. The fund is put back
                // from its Funds card ("Show on Home").
                if section.canHideFromHome, viewModel.isAdmin {
                    Button {
                        Task {
                            if await viewModel.hideFundFromHome(section: section) {
                                appState.showToast("Hidden from Home. Find it on the Funds tab to put it back.", kind: .success)
                            } else {
                                appState.showToast("Could not hide \(name).", kind: .error)
                            }
                        }
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide \(name) from Home")
                    .accessibilityIdentifier("home.hideFund.\(section.rawValue)")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "#c3cad2"))
            }
            .frame(minHeight: 48)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(section == .fund ? "home.quietSavings" : (section == .debt ? "home.quietDebt" : "home.quietRow.\(section.rawValue)"))
        .accessibilityLabel(amount.map { "\(name), \($0), show fund" } ?? "\(name), loading")
    }

    // MARK: Stat cards — Charity + Extra Fund, half-size side by side

    /// Build 43 (owner, Nov 17, 2026): the two Home stat cards
    /// expand and collapse as ONE unit — tapping either card opens
    /// both, tapping again closes both — so the row never shows an
    /// uneven pair with a gap under a collapsed card. The shared
    /// `expandedCard` still holds only one value (one-open-at-a-
    /// time across Home + Funds), so "expanded" here means it holds
    /// either .charity or .fund; the stored value is whichever card
    /// was tapped to open the pair, so the Funds page still opens
    /// that one card. The Spending hero is separate and untouched.
    /// Both cards read this one boolean, so their chevrons always
    /// agree. Instant — no animation (owner rule, build 34).
    private var isStatCardsExpanded: Bool {
        appState.expandedCard == .charity || appState.expandedCard == .fund
    }

    /// Toggle the linked Home stat-card pair: open (storing the
    /// tapped card) or close both together.
    private func toggleStatCards(_ card: ExpandedCard) {
        if isStatCardsExpanded {
            appState.expandedCard = nil
        } else {
            appState.expandedCard = card
        }
    }

    private var charityCard: some View {
        statCard(
            title: FundSectionID.charity.displayName(customNames: appState.fundNames),
            face: charityFaceText,
            theme: .charity,
            section: .charity,
            isLoading: viewModel.charity.isLoading,
            statusText: charityStatusText,
            statusIsError: viewModel.charity.isFailed,
            isExpanded: isStatCardsExpanded,
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
                    // Build 43: the pair opens/closes together.
                    toggleStatCards(.charity)
                }
            }
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
            isExpanded: isStatCardsExpanded,
            ariaLabel: fundAriaLabel,
            compact: true,
            onTap: {
                switch viewModel.fund {
                case .loading:
                    notLoadedAlertTitle = FundSectionID.fund.displayName(customNames: appState.fundNames)
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    // Build 43: the pair opens/closes together.
                    toggleStatCards(.fund)
                }
            }
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
                ErrorBox("Could not load \(FundSectionID.fund.displayName(customNames: appState.fundNames)) balances.")
                Button("Try Again") { Task { await viewModel.refresh() } }
                    .buttonStyle(TertiaryButtonStyle())
            } else if case .loaded(let summary) = viewModel.fund {
                // Home expansions show rows only, no action buttons.
                // Row labels are Title Case (owner rule, Nov 4, 2026).
                // Build 43 (owner, Nov 17, 2026): the first row is
                // just "Available" — "Spendable Available" was too
                // long and truncated in the half-width card. The
                // in-code web-parity exemption for these rows was
                // wrong and is removed (audit H-P2-1).
                statRow(
                    label: "Available",
                    value: MoneyFormat.signedString(cents: summary.availableCents))
                // Build 43 (owner, Nov 17, 2026 — "Doesn't show the
                // pending amounts"): Pending/Total fold in pending
                // top-ups, matching FundsViewModel.savingsPendingCents
                // — a $650 pending top-up reads Pending $650.00 and
                // Total $650.00 here, not $0.00.
                statRow(label: "Pending", value: MoneyFormat.string(cents: summary.pendingIncludingHeldCents + viewModel.pendingTopupsCents))
                statRow(label: "Total", value: MoneyFormat.string(cents: summary.totalCents + viewModel.pendingTopupsCents))
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
    /// Build 43 (owner, Nov 17, 2026): the collapsed card shows
    /// the fund NAME in the header bar (icon + name) and the AMOUNT
    /// CENTRED in the white body below — the "Given · Total" /
    /// "Pending · Total" summary line is gone (it truncated and
    /// looked ugly). This reverses build 42 item 22, which hid the
    /// name in the header and put the amount there: with the amount
    /// out of the header, icon + name fit on a compact iPhone. The
    /// expanded view still shows the full detail rows.
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
        // Build 43 (owner, Nov 17, 2026): the name is ALWAYS in
        // the header now — build 42 item 22 hid it on a compact
        // iPhone because title + amount did not fit in a half-
        // width card, but the amount has moved OUT of the header
        // into the white body (centred), so icon + name fit:
        // icon 34 + title (~90 skeleton) + padding 32 ≈ 156pt
        // against the ~173pt card width. The build-42 overflow
        // fix (item 23) still holds — nothing in the header is
        // wider than before.
        // Build 46 (owner, Nov 18, 2026 — "numbers as big as they
        // can be"): the amounts step up again — 34pt on a compact
        // iPhone (the half-width card interior is ~141pt; "$945.32"
        // at 34pt is ~138pt, so it just fits, and the 0.7 shrink
        // covers longer amounts), 64pt on iPad (interior ~387pt;
        // the same figure is ~260pt, so it fills the card without
        // crowding the edges), 44pt / 64pt non-compact. The
        // skeleton heights match the amounts' line heights, and
        // the skeleton WIDTHS match the amounts' widths, so the
        // body holds its size while loading. The iPad title
        // skeleton widens to 150pt (FIX 2, same owner report — the
        // 90pt bar was lost in the 387pt card interior).
        // Build 64 (C-1 — QUIETER): the amounts step back down —
        // 28pt on a compact iPhone (32pt iPad), 30pt non-compact —
        // semibold, not heavy, in the fund's own colour; titles
        // are 17pt semibold everywhere. The header icon is a
        // small 20pt glyph directly on white (P-6 — the white
        // circle disc is gone).
        let iconSize: CGFloat = 20
        let titleSize: CGFloat = 17
        let amountSize: CGFloat = compact ? (isIPad ? 32 : 28) : (isIPad ? 32 : 30)
        let amountSkeletonHeight: CGFloat = compact ? (isIPad ? 40 : 34) : (isIPad ? 40 : 36)
        let amountSkeletonWidth: CGFloat = compact ? (isIPad ? 240 : 130) : (isIPad ? 240 : 170)
        let statusSize: CGFloat = compact ? (isIPad ? 14 : 13) : 14
        let chevronSize: CGFloat = compact ? (isIPad ? 15 : 14) : 15
        let pad: CGFloat = compact ? (isIPad ? 20 : 16) : 24
        // Build 64 (C-2 B2): NO banner any more — the header is
        // plain white and the name is written in the fund's own
        // colour (theme.number). The old bannerColor / onBanner
        // helpers are deleted with the banner; the failed signal
        // is the static grey block in the body plus the red status
        // line, never a grey header.
        return VStack(alignment: .leading, spacing: 0) {
            // Header (build 64, B2): ONE ROW — a small glyph in
            // the fund's own colour + the title in that colour,
            // on plain white. Build 43 (owner, Nov 17, 2026):
            // the amount is NOT here any more — it is centred in
            // the white body below (build 42 item 22 had it here
            // with the title hidden; that is reversed).
            HStack(spacing: 8) {
                // The icon + name render in EVERY state — loaded,
                // loading, and failed (build 47, owner Nov 19,
                // 2026: the header shows its colour and name from
                // the first paint, like the simpler Home's cards;
                // the name and icon are local, only the amount
                // waits). The old loading skeletons are gone from
                // the header — a grey block on the light banners
                // (Savings tertiary #e5e7eb) was nearly invisible,
                // and the body amount skeleton is the loading sign.
                // Icon directly on white (build 64, P-6): the
                // theme's number colour, no white disc.
                Image(systemName: section.resolvedIconName(customIcons: appState.fundIcons))
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(theme.number)
                    .frame(width: 22, height: 22)
                // Build 43 (owner, Nov 17, 2026): the name is
                // always in the header; the amount lives in the
                // white body below, so the header is icon + name
                // only — nothing here can truncate against an
                // amount any more. Build 50 (owner, Nov 20, 2026
                // — iPhone readability): the name wraps to a
                // second line rather than shrinking — one uniform
                // size on every card, nothing cut off. The old
                // 0.85 minimumScaleFactor made long names render
                // smaller than short ones.
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(theme.number)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, pad)
            .padding(.vertical, 14)
            // White body (majority): the amount CENTRED when
            // collapsed (build 43), the detail rows when expanded.
            // While loading a centred amount-sized skeleton; while
            // failed the red status line when collapsed, or the
            // rows (ErrorBox + Retry) when expanded. Build 42
            // (owner, Nov 17, 2026 — "the white body should be
            // double the header"): roughly 1/3 header, 2/3 white
            // body. Build 64 (P-4): the body padding steps DOWN
            // to 22pt top and bottom (was 52pt) — the card stops
            // towering over its content; the white body still
            // dominates, just without the dead air. The header is
            // untouched.
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    // Amount-sized skeleton, CENTRED like the
                    // loaded amount below (build 43) — same height
                    // and near the same width as the amount, so the
                    // body holds its size while loading. Build 46
                    // (owner, Nov 18, 2026): 240pt on iPad, so the
                    // bar fills the wider card instead of sitting
                    // lost in the space.
                    SkeletonBlock(width: amountSkeletonWidth, height: amountSkeletonHeight, cornerRadius: 6)
                        .frame(maxWidth: .infinity, alignment: .center)
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
                } else {
                    // Build 43 (owner, Nov 17, 2026): the collapsed
                    // body is the AMOUNT, CENTRED — the "Given ·
                    // Total" / "Pending · Total" summary line is
                    // gone (it truncated and looked ugly). The
                    // chevron sits at the bottom-right below it, so
                    // the amount stays truly centred. The expanded
                    // view still shows the full detail rows above.
                    // Build 64 (C-1 + C-2 B2): semibold, not heavy,
                    // in the fund's own colour (theme.number) — the
                    // amount matches the name.
                    Text(face)
                        .font(.system(size: amountSize, weight: .semibold))
                        .foregroundStyle(theme.number)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: chevronSize, weight: .bold))
                            .foregroundStyle(DesignTokens.muted)
                    }
                }
            }
            .padding(.horizontal, pad)
            .padding(.top, 22)
            .padding(.bottom, 22)
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
    /// first row is just "Available" since build 43 (the old
    /// "Spendable Available" label was too long and truncated).
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
        let name = FundSectionID.charity.displayName(customNames: appState.fundNames)
        switch viewModel.charity {
        case .loaded(let summary):
            if summary.committedCents == 0 && summary.givenCents == 0 {
                return "\(name), no charity tracked yet, show breakdown"
            }
            if summary.remainingCents < 0 {
                return "\(name), ahead by \(MoneyFormat.string(cents: -summary.remainingCents)), show breakdown"
            }
            return "\(name), \(MoneyFormat.string(cents: summary.remainingCents)) remaining, \(MoneyFormat.string(cents: summary.givenCents)) given, \(MoneyFormat.string(cents: summary.committedCents)) committed, show breakdown"
        case .failed:
            return "\(name), could not load, show breakdown"
        case .loading:
            return "\(name), loading, show breakdown"
        }
    }

    private var fundAriaLabel: String {
        let name = FundSectionID.fund.displayName(customNames: appState.fundNames)
        switch viewModel.fund {
        case .loaded(let summary):
            let pending = summary.pendingIncludingHeldCents + viewModel.pendingTopupsCents
            if pending > 0 {
                return "\(name), \(MoneyFormat.string(cents: summary.availableCents)) available, \(MoneyFormat.string(cents: pending)) pending, show breakdown"
            }
            return "\(name), \(MoneyFormat.string(cents: summary.availableCents)) available, show breakdown"
        case .failed:
            return "\(name), could not load balances, show breakdown"
        case .loading:
            return "\(name), loading, show breakdown"
        }
    }

    // MARK: Past Weeks (build 64, F-18)

    /// The visible Past Weeks destination on Home: a quiet white
    /// row — calendar glyph in deep blue, "Past Weeks" in ink,
    /// faint chevron — so closed weeks are one tap away instead
    /// of hiding behind the Spending card's chevron or the
    /// Transactions "More" menu.
    private var pastWeeksButton: some View {
        Button { showPastWeeks = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignTokens.deep)
                    .frame(width: 22, height: 22)
                Text("Past Weeks")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.ink)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "#c3cad2"))
            }
            .frame(minHeight: 48)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fundCardShadow()
        .accessibilityIdentifier("home.pastWeeks")
        .accessibilityLabel("Past Weeks, show closed weeks")
    }

    /// The Settings context for the Home-presented Past Weeks —
    /// the same context the shell builds for its history pages
    /// (AppShellView.settingsContext), except a Past Week tap
    /// closes this cover first and THEN applies the week filter —
    /// otherwise the filtered list would sit hidden under the
    /// cover. Nil when the household is unknown (the shell's
    /// homeTab already gates on it, so this is a safe fallback,
    /// never a blank cover).
    private var pastWeeksContext: SettingsContext? {
        guard let householdId = appState.householdId else { return nil }
        return SettingsContext(
            client: appState.client,
            householdId: householdId,
            isAdmin: viewModel.isAdmin,
            isOwner: appState.isOwner,
            currentUserId: appState.client.currentSession?.user.id,
            displayName: appState.displayName,
            email: appState.client.currentSession?.user.email,
            householdName: appState.householdName,
            onSignOut: { Task { await appState.signOut() } },
            onAccountDeleted: { message in
                Task { await appState.signOut() }
                appState.showToast(message, kind: .info)
            },
            onShowWeekTransactions: { week in
                showPastWeeks = false
                appState.showTransactionsForWeek(week)
            },
            unregisterPushToken: { await appState.unregisterPushToken() }
        )
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
                        ? nil : viewModel.institutionBySuffix[row.cardSuffix],
                    // Build 53 (owner, Nov 21, 2026): only a bank
                    // row (transfer / card payment) keeps the bank
                    // logo — an unmapped merchant gets the monogram,
                    // never the bank logo.
                    isBankRow: row.kind == .transfer || row.kind == .payment)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TransactionFormatting.displayMerchant(row.merchant))
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

// MARK: - Home sheets' fund forms (build 65)
//
// The Weekly and Tzedaka sheets reuse the Funds page's own forms
// (Adjust This Week's Budget, Add to Tzedaka, Record a Gift) —
// the forms live in FundsRulesView / FundsView /
// CharityIncomeForm and take a FundsViewModel, which Home does not
// own. The sheets build one lazily from the same
// FundsContext the shell builds for the Funds tab
// (AppShellView), refresh it once so the forms' previews and
// balances load (base allowance, charity Available), and forward
// its toast to the one root toast, exactly like FundsView does —
// so a form's success message is never lost inside a sheet.
// The view model is created once per sheet presentation and kept
// in the sheet's @State; its refresh only fills its own figures,
// so the sheet's onChanged hook refreshes Home after a form
// closes, or Home would keep showing pre-action numbers.

// @MainActor (build 65 fix): AppViewModel's householdId / role /
// fundNames and FundsViewModel.init are main-actor-isolated, and
// a free function is nonisolated by default — the archive failed
// to compile until this was marked @MainActor. All call sites are
// SwiftUI view code (already main actor), so the call stays
// synchronous.
@MainActor
private func makeFundsViewModel(appState: AppViewModel) -> FundsViewModel? {
    guard let householdId = appState.householdId,
          let role = appState.role,
          let userId = appState.client.currentSession?.user.id else { return nil }
    let viewModel = FundsViewModel(context: FundsContext(
        client: appState.client, householdId: householdId, role: role, userId: userId))
    viewModel.fundNames = appState.fundNames
    return viewModel
}

/// One tappable action row inside a Home sheet (build 65, owner
/// Nov 23, 2026 — items 4–5): a real row, not a big button and
/// not bare text — icon in the action's colour, title + subline,
/// faint chevron, 56pt minimum height, the whole row tappable.
/// Rows (not more big buttons) so the extra actions never clash
/// with the sheet's solid-blue primary / grey Close pair and
/// never break the button rule.
private struct SheetActionRow: View {
    let icon: String?
    /// A custom drawn glyph, used instead of `icon` when set
    /// (build 68, item 11: the calculator glyph, which no SF
    /// Symbol renders reliably on device).
    let glyph: AnyView?
    let iconColor: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    /// The usual row, with an SF Symbol icon.
    init(icon: String, iconColor: Color, title: String, subtitle: String, action: @escaping () -> Void) {
        self.icon = icon
        self.glyph = nil
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    /// A row with a custom drawn glyph instead of an SF Symbol.
    /// The glyph is drawn in `iconColor` by its caller, so the
    /// row still reads as one consistent list (item 10).
    init(glyph: AnyView, iconColor: Color, title: String, subtitle: String, action: @escaping () -> Void) {
        self.icon = nil
        self.glyph = glyph
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let glyph {
                    glyph
                        .frame(width: 22, height: 22)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "#c3cad2"))
            }
            .frame(minHeight: 56)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

/// The hairline divider between two sheet action rows, matching
/// the quiet card's divider on Home. Shared (build 67): the
/// Expenses list uses the same divider between its rows.
struct SheetActionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(hex: "#e7eaee"))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
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
/// marked on the rows. Show Transactions stands alone, full
/// width (build 70, items 2+5: the Close beside it is gone).
/// iPad: 600pt wide, centred
/// (detents + fixed width in the regular size
/// class); iPhone: full-width.
public struct WeeklySheet: View {
    let week: WeekResult
    let baseAllowanceCents: Int?
    let purchasesThisWeek: Int?
    @ObservedObject var appState: AppViewModel
    /// Build 65: run after a form sheet opened from here closes,
    /// so Home reloads the changed week numbers (the Funds view
    /// model refreshes only its own figures). Home passes its own
    /// refresh; nil keeps the old behaviour.
    var onChanged: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Build 65 (owner, Nov 23, 2026 — item 4): the action rows
    /// below the numbers — Adjust This Week's Budget, Recurring
    /// Expenses, Weekly Budget Calculator. Build 68 (item 29):
    /// Top Up Budget + Set This Week's Budget merged into the one
    /// Adjust This Week's Budget sheet.
    @State private var showAdjustWeeklyBudget = false
    @State private var showCalculator = false
    /// Build 67 (owner, Nov 23, 2026): the Expenses list, opened
    /// from the Recurring Expenses row in the actions card below.
    @State private var showExpenses = false
    /// The Funds view model the Adjust This Week's Budget form
    /// needs (see the note above the Weekly sheet section). Built
    /// lazily, once per presentation.
    @State private var fundsViewModel: FundsViewModel?

    public init(week: WeekResult, baseAllowanceCents: Int?, purchasesThisWeek: Int?, appState: AppViewModel, onChanged: (() -> Void)? = nil) {
        self.week = week
        self.baseAllowanceCents = baseAllowanceCents
        self.purchasesThisWeek = purchasesThisWeek
        self.appState = appState
        self.onChanged = onChanged
    }

    /// Build 66 (owner, Nov 23, 2026 — item 5): the numbers as
    /// one list for the numbers card below — the reconciliation
    /// rows (Base / Spent / Balance / Debt Remaining) plus the
    /// Purchases count — so the card can lay them out with
    /// hairline dividers like the actions card. Deduction rows
    /// print with a leading minus (audit H-P2-2) so Base $375 −
    /// Debt $50 = Balance $325 adds up on sight; the model cents
    /// stay positive. Purchases is a count, not money — same row
    /// shape, no dollar sign (owner, Nov 14, 2026).
    private var weeklyNumbersRows: [(label: String, value: String)] {
        var rows = week.sheetRows(baseAllowanceCents: baseAllowanceCents).map { row in
            (label: row.label, value: MoneyFormat.string(cents: row.isDeduction ? -row.cents : row.cents))
        }
        if let purchases = purchasesThisWeek {
            rows.append((label: "Purchases", value: String(purchases)))
        }
        return rows
    }

    /// The Funds view model, built on first need (see
    /// makeFundsViewModel). Nil only before the household is
    /// known — in practice never while Home is showing.
    private func ensureFundsViewModel() -> FundsViewModel? {
        if let fundsViewModel { return fundsViewModel }
        guard let viewModel = makeFundsViewModel(appState: appState) else { return nil }
        fundsViewModel = viewModel
        return viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Build 70, items 2+5 (owner, Nov 24, 2026): the
            // dismiss is the top-left X in the SheetHeader +
            // swipe-right (the header carries the gesture) — the
            // bottom "Close" next to "Show Transactions" is gone
            // (it duplicated the dismiss). The Nov 12 single-
            // dismiss-control decision is superseded by the
            // back-button-on-every-popup rule.
            SheetHeader(title: "Weekly Budget", onClose: { dismiss() })
            // No explainer line here (owner, Nov 12 2026): the
            // "Pending transactions are included and marked." line
            // crowded the header. Pending state is already marked
            // on the rows themselves, so nothing replaces it.
            // Reconciliation rows (live.js v69): Base / Temporary /
            // Carried debt appear exactly when they change the number;
            // a normal week keeps the approved two rows (Spent,
            // Balance) — the redundant Allowance row is gone
            // (owner, Nov 15, 2026 — build 34).
            // Build 66 (owner, Nov 23, 2026 — item 5): the numbers
            // live on a white card matching the actions card below
            // — plain rows on the sheet background read as
            // background noise, not part of the centerpiece. Same
            // card treatment (white, 12pt radius, hairline
            // #e5e7eb border, fund shadow) and hairline dividers
            // between the rows, so the two halves read as one sheet.
            // Build 67 (owner, Nov 23, 2026 — "way too crammed and
            // claustrophobic"): the rows get real air — 10pt
            // vertical padding per row and 16pt inside the card —
            // so the card breathes instead of packing the figures.
            VStack(spacing: 0) {
                ForEach(weeklyNumbersRows.indices, id: \.self) { index in
                    let row = weeklyNumbersRows[index]
                    sheetRow(label: row.label, value: row.value)
                    if index < weeklyNumbersRows.count - 1 {
                        SheetActionDivider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .fundCardShadow()
            // Build 65 (owner, Nov 23, 2026 — item 4): the sheet
            // used to end at the numbers with dead space below —
            // the week actions live here now, as tappable ROWS in
            // one white card (not more big buttons, so they never
            // clash with the solid-blue Show Transactions button
            // below and never break the button rule).
            // Adjust This Week's Budget is admin-only (the Funds
            // page gates it the same way); the Calculator is
            // local-only and stays visible to every role. Each row
            // opens the Funds page's own form — no logic is
            // duplicated here. The card renders only when it holds
            // at least one row (admin rows, or the
            // calculator for every role) — never an empty white card.
            if appState.isAdmin || appState.householdId != nil {
                weeklyActionsCard
            }
            Button("Show Transactions") {
                dismiss()
                appState.showTransactionsForWeek(week.weekStart)
            }
            .buttonStyle(PrimaryButtonStyle())
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
            // Build 43 (owner, Nov 17, 2026 — item 18): the trailing
            // Spacer top-anchors the content in the full-screen
            // cover — it already did this in the detent sheet, and
            // it is what keeps the rows at the top now.
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        // iPad width (owner, Nov 12 2026): a fixed 600pt width here
        // widens the popup on iPad (regular size class) instead of
        // the system ~540pt form sheet. On iPhone (compact) no width
        // is fixed and the popup stays full-width.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 65: load the Funds figures the forms need (base
        // allowance for the Temporary Allowance preview); forward
        // the forms' toasts to the one root toast, like FundsView.
        .task {
            if let viewModel = ensureFundsViewModel() {
                await viewModel.refresh()
            }
        }
        .onChange(of: fundsViewModel?.toast) { _, newValue in
            if let toast = newValue {
                appState.showToast(toast.message, kind: toast.kind)
                fundsViewModel?.toast = nil
            }
        }
        // Adjust This Week's Budget (FundsRulesView.
        // AdjustWeeklyBudgetSheet, build 68 item 29): Top Up
        // Budget + Set This Week's Budget merged into one sheet —
        // an Add / Set Total slider, wired to the existing Top Up
        // and Temporary Allowance operations. Refreshes Home on
        // dismiss, so the new total shows at once. A fitted sheet
        // (the detents live in the form itself).
        .sheet(isPresented: $showAdjustWeeklyBudget, onDismiss: { onChanged?() }) {
            if let fundsViewModel {
                AdjustWeeklyBudgetSheet(viewModel: fundsViewModel, onClose: { showAdjustWeeklyBudget = false })
                    // Build 68 (item 6): a light airy sheet — white
                    // presentation background, so the sheet sits
                    // bright against a lighter backdrop.
                    .presentationBackground(.white)
            }
        }
        // Weekly Budget Calculator (FundsView.
        // WeeklyBudgetCalculatorSheet): the existing calculator,
        // reused as-is — local-only, suggestion-only, no server
        // write, so no Home refresh on dismiss. Build 67: the
        // Calculator reads its recurring costs from the tagged
        // expenses (the sheet's Funds view model loads them) —
        // the LIVE ones only, so an expense in the Trash stops
        // counting at once.
        .fullScreenCover(isPresented: $showCalculator) {
            // Build 69: the Calculator needs a view model (its
            // `@ObservedObject` cannot wrap an Optional), so the
            // cover unwraps `ensureFundsViewModel()` alongside the
            // household id — nil only before the household is
            // known, in practice never while Home is showing.
            if let householdId = appState.householdId, let fundsViewModel = ensureFundsViewModel() {
                WeeklyBudgetCalculatorSheet(
                    householdId: householdId,
                    charityName: FundSectionID.charity.displayName(customNames: appState.fundNames),
                    viewModel: fundsViewModel,
                    onClose: { showCalculator = false }
                )
            }
        }
        // Recurring Expenses (build 67, owner Nov 23, 2026): the
        // Expenses list. Refreshes Home on dismiss, so removing
        // an expense (its transaction counts as a purchase again)
        // shows in the week figures at once.
        .sheet(isPresented: $showExpenses, onDismiss: { onChanged?() }) {
            if let fundsViewModel {
                ExpensesListView(
                    expenses: fundsViewModel.liveExpenses,
                    isAdmin: appState.isAdmin,
                    onSave: { expense, name, amountCents, frequency in
                        await fundsViewModel.updateExpense(expense, name: name, amountCents: amountCents, frequency: frequency)
                    },
                    onRemove: { expense in
                        await fundsViewModel.removeExpense(expense)
                    },
                    onClose: { showExpenses = false }
                )
                // Build 68 (item 6): white presentation background.
                .presentationBackground(.white)
            }
        }
    }

    /// The Recurring Expenses row's subtitle (build 67): the
    /// count + the monthly total — "2 expenses · $310.00 a
    /// month". "No expenses tagged yet" while the list is empty
    /// (or still loading).
    private var expensesSubtitle: String {
        let live = fundsViewModel?.liveExpenses ?? []
        guard !live.isEmpty else { return "No expenses tagged yet" }
        let monthly = live.reduce(0) { $0 + $1.monthlyCents }
        // Build 68 (frequency format): the frequency is a compact
        // suffix on the amount — "$160.00/mo", never "a month".
        return "\(live.count) \(live.count == 1 ? "expense" : "expenses") · \(MoneyFormat.formatCents(monthly))/mo"
    }

    /// The week-action rows (build 65, item 4): Adjust This
    /// Week's Budget for admins (build 68, item 29 — Top Up
    /// Budget + Set This Week's Budget merged into one sheet),
    /// Recurring Expenses and the Weekly Budget Calculator for
    /// every role. When the Funds view model cannot be built
    /// (household not yet known — in practice never while Home is
    /// showing), the admin row falls back to the Spending fund on
    /// the Funds page, where the same action lives; the sheet
    /// itself never strands the user.
    /// Build 68 (item 10): all the row icons share one colour —
    /// brand blue — so the card reads as one consistent list.
    private var weeklyActionsCard: some View {
        VStack(spacing: 0) {
            if appState.isAdmin {
                SheetActionRow(
                    icon: "slider.horizontal.3",
                    iconColor: DesignTokens.primary,
                    title: "Adjust This Week's Budget",
                    subtitle: "Add a one-time amount or set a new total"
                ) {
                    if ensureFundsViewModel() != nil {
                        showAdjustWeeklyBudget = true
                    } else {
                        dismiss()
                        appState.openSpendingFund()
                    }
                }
            }
            if appState.householdId != nil {
                SheetActionDivider()
                // Build 67 (owner, Nov 23, 2026): Recurring
                // Expenses — visible to every role, like the
                // Calculator (members see the list read-only; only
                // the admin can tag or edit). It sits above the
                // Calculator because the Calculator reads from it.
                SheetActionRow(
                    icon: "house",
                    iconColor: DesignTokens.primary,
                    title: "Recurring Expenses",
                    subtitle: expensesSubtitle
                ) {
                    showExpenses = true
                }
                SheetActionDivider()
                SheetActionRow(
                    // Build 68 (item 11): the "calculator" SF
                    // Symbol renders NOTHING on device (verified
                    // build 66), and the ± glyph (plus.
                    // forwardslash.minus) did not read as a
                    // calculator — this row now uses the same
                    // shape-drawn CalculatorGlyph as the Funds
                    // Calculate button, which cannot fail to
                    // resolve.
                    glyph: AnyView(CalculatorGlyph(size: 20, color: DesignTokens.primary)),
                    iconColor: DesignTokens.primary,
                    title: "Weekly Budget Calculator",
                    subtitle: "Work out the right weekly amount"
                ) {
                    showCalculator = true
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .fundCardShadow()
    }

    private func sheetRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
        // Build 67 (owner, Nov 23, 2026 — "way too crammed and
        // claustrophobic"): 10pt of air per row, so the numbers
        // card breathes.
        .padding(.vertical, 10)
    }
}

// MARK: - Tzedaka sheet (build 65, owner Nov 23, 2026 — item 5)
//
// Opened by tapping the Tzedaka card on Home. Mirrors the Weekly
// Budget sheet's structure and fitted full-screen presentation:
// the Tzedaka numbers (Available / Given / Pending / Total), the
// two Tzedaka actions as tappable rows (Add to Tzedaka + Record a
// Gift — Record Income is NOT here; it lives in the "+ Add" flow),
// then the Show Transactions button, full width (build 70,
// items 2+5: the Close beside it is gone — the SheetHeader X +
// swipe dismiss).
// The actions are rows, not more big buttons, for the same reason
// as the Weekly sheet's rows: the sheet already has its
// solid-blue / grey button pair, and two more full-width buttons
// would put two solid blues in one sheet.

public struct TzedakaSheet: View {
    let summary: CharitySummary
    @ObservedObject var appState: AppViewModel
    /// Build 65: run after a form sheet opened from here closes,
    /// so Home reloads the changed charity numbers. Home passes
    /// its own refresh; nil keeps the sheet self-contained.
    var onChanged: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showAddToCharity = false
    @State private var showRecordGift = false
    /// The Funds view model the Add to Tzedaka / Record a Donation
    /// forms need (see the note above the Weekly sheet section).
    /// Built lazily, once per presentation.
    @State private var fundsViewModel: FundsViewModel?

    public init(summary: CharitySummary, appState: AppViewModel, onChanged: (() -> Void)? = nil) {
        self.summary = summary
        self.appState = appState
        self.onChanged = onChanged
    }

    private var charityName: String {
        FundSectionID.charity.displayName(customNames: appState.fundNames)
    }

    /// The Funds view model, built on first need (see
    /// makeFundsViewModel). Nil only before the household is
    /// known — in practice never while Home is showing.
    private func ensureFundsViewModel() -> FundsViewModel? {
        if let fundsViewModel { return fundsViewModel }
        guard let viewModel = makeFundsViewModel(appState: appState) else { return nil }
        fundsViewModel = viewModel
        return viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Build 70, items 2+5 (owner, Nov 24, 2026): the
            // dismiss is the top-left X in the SheetHeader +
            // swipe-right — the bottom "Close" is gone (see the
            // Weekly sheet note).
            SheetHeader(title: charityName, onClose: { dismiss() })
            // The Tzedaka numbers, in the same row shape as the
            // Weekly sheet's rows. All four always show — Available
            // is committed less Given less Pending, so the four
            // add up on sight.
            // Build 66 (owner, Nov 23, 2026 — item 7, "Same on
            // this page"): the numbers live on a white card
            // matching the actions card below, exactly like the
            // Weekly sheet's numbers card — plain rows on the
            // sheet background read as background noise, not part
            // of the centerpiece.
            // Build 67 (owner, Nov 23, 2026 — "way too crammed and
            // claustrophobic"): same air as the Weekly sheet's
            // numbers card — 10pt per row, 16pt inside the card.
            VStack(spacing: 0) {
                sheetRow(label: "Available", value: MoneyFormat.signedString(cents: summary.remainingCents))
                SheetActionDivider()
                sheetRow(label: "Given", value: MoneyFormat.string(cents: summary.givenCents))
                SheetActionDivider()
                sheetRow(label: "Pending", value: MoneyFormat.string(cents: summary.pendingGiftCents))
                SheetActionDivider()
                sheetRow(label: "Total", value: MoneyFormat.string(cents: summary.committedCents))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
            )
            .fundCardShadow()
            // The Tzedaka actions, as tappable rows (admin-only,
            // like the Funds page's Tzedaka card). Only these two:
            // Add to Tzedaka + Record a Donation. Record Income is
            // deliberately absent — it lives in the "+ Add" flow.
            if appState.isAdmin {
                tzedakaActionsCard
            }
            // Build 69 (owner, Nov 24, 2026): "Show Tzedaka
            // Transactions" wrapped to two lines — the label
            // was too long for the button. "Show Transactions"
            // is unambiguous here (this IS the Tzedaka sheet).
            // Build 70, items 2+5: the Close beside it is gone
            // (the SheetHeader X + swipe dismiss), so Show
            // Transactions stands alone, full width.
            Button("Show Transactions") {
                dismiss()
                // Build 65: the Tzedaka pre-filter — the list
                // lands on the rows behind these numbers (gifts
                // given + income rows that accrued charity, all
                // time), via the pending-charity handoff.
                appState.showTzedakaTransactions()
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        // iPad width, like the Weekly sheet: a fixed 600pt width
        // in the regular size class, full-width on iPhone.
        .frame(width: horizontalSizeClass == .regular ? 600 : nil)
        // Build 65: load the Funds figures the forms need (the
        // charity Available for the Record a Donation over-available
        // check); forward the forms' toasts to the one root toast,
        // like FundsView.
        .task {
            if let viewModel = ensureFundsViewModel() {
                await viewModel.refresh()
            }
        }
        .onChange(of: fundsViewModel?.toast) { _, newValue in
            if let toast = newValue {
                appState.showToast(toast.message, kind: toast.kind)
                fundsViewModel?.toast = nil
            }
        }
        // Build 68 (item 30): Add to Tzedaka + Record a Donation
        // merged into the one compact TzedakaActionSheet — the
        // Add / Record a Donation choice sits at the top of the
        // sheet itself, so both rows open the same sheet pre-set
        // to their direction. Refreshes Home on dismiss, so the
        // new Available shows at once. A fitted sheet, not a
        // full-screen cover (the detents live in the form itself).
        .sheet(isPresented: $showAddToCharity, onDismiss: { onChanged?() }) {
            if let fundsViewModel {
                TzedakaActionSheet(viewModel: fundsViewModel, fundName: charityName, initialMode: .add, onClose: { showAddToCharity = false })
                    // Build 68 (item 6): white presentation background.
                    .presentationBackground(.white)
            }
        }
        .sheet(isPresented: $showRecordGift, onDismiss: { onChanged?() }) {
            if let fundsViewModel {
                TzedakaActionSheet(viewModel: fundsViewModel, fundName: charityName, initialMode: .record, onClose: { showRecordGift = false })
                    // Build 68 (item 6): white presentation background.
                    .presentationBackground(.white)
            }
        }
    }

    /// The Tzedaka action rows (build 65, item 5). When the Funds
    /// view model cannot be built (household not yet known — in
    /// practice never while Home is showing), the rows fall back
    /// to the Tzedaka fund on the Funds page, where the same
    /// actions live; the sheet itself never strands the user.
    private var tzedakaActionsCard: some View {
        VStack(spacing: 0) {
            SheetActionRow(
                icon: "plus.circle",
                iconColor: DesignTokens.primary,
                title: "Add to \(charityName)",
                subtitle: "Add money to the amount ready to give"
            ) {
                if ensureFundsViewModel() != nil {
                    showAddToCharity = true
                } else {
                    dismiss()
                    appState.openFund(.charity)
                }
            }
            SheetActionDivider()
            SheetActionRow(
                icon: "gift",
                iconColor: DesignTokens.primary,
                title: "Record a Donation",
                subtitle: "Record a cash donation given off-card"
            ) {
                if ensureFundsViewModel() != nil {
                    showRecordGift = true
                } else {
                    dismiss()
                    appState.openFund(.charity)
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
        )
        .fundCardShadow()
    }

    private func sheetRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
        // Build 67 (owner, Nov 23, 2026 — "way too crammed and
        // claustrophobic"): 10pt of air per row, so the numbers
        // card breathes.
        .padding(.vertical, 10)
    }
}
