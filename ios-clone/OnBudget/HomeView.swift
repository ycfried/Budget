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
// Hero: white card, 2.5px #2f6bff outline, no shadow. Sync button
// is primary blue when allowance set, grey tertiary until set;
// "Set Your Weekly Allowance" (admin only) when none set. Purchases
// shows "N/A" — never a bare dash — when transactions fail to load.
// Fund + Charity cards: stacked, Charity above Extra Fund, both
// full-width, expand downward IN PLACE, one-open-at-a-time, with
// the expand detail (Available / Pending / Total) and NO action
// buttons on Home (actions belong on the Funds page). Both cards
// are BIGGER and outlined (owner, Nov 12, 2026, corrected ~2:02 PM
// the same day — NOT a wash: Charity green #16a34a outline, Extra
// Fund brand-blue #2f6bff outline, both 2px, white inside like the
// hero, shared StatCardTheme with the Funds page); the Weekly
// Budget hero above them keeps its thicker 2.5px outline.
// "Last synced" is shown once, quietly, under Automatic Sync in
// Settings (ConnectedAccountsView); Home carries NO sync line
// (owner, Nov 11, 2026 — removed from Home entirely).
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
        // choice — allowanceSetAt == nil means never set). The stored
        // base travels with it for the Weekly sheet's reconciliation
        // rows; both clear together when the household read fails so
        // a stale base can never explain a fresh week.
        do {
            let allowance = try await client.postgrest.householdAllowance(householdId: householdId)
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

        // Plaid items: only for the suffix → institution map (bank
        // icons). Best-effort — never blocks Home. No sync stamp is
        // kept here: the sync line lives in Settings only.
        do {
            let items = try await client.postgrest.plaidItems(householdId: householdId)
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
            // Best-effort only: no stamp, no error state.
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
                    // Breathing room (owner, Nov 12 2026): the section
                    // sat too tight under the Extra Fund card — 8pt
                    // extra on top of the 16pt stack gap.
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(DesignTokens.background)
        .task { await viewModel.refresh() }
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
                WeeklySheet(week: result, baseAllowanceCents: viewModel.allowanceCents, appState: appState)
                    // iPad width (owner, Nov 12 2026): a plain .sheet
                    // is a ~540pt form sheet on iPad — narrow and
                    // cramped for this content. .fitted sizes the
                    // sheet to the content, and WeeklySheet fixes its
                    // width to 600pt in the regular size class, so the
                    // sheet opens 600pt wide and centred; on iPhone
                    // (compact) the width stays full-screen and only
                    // the height hugs the content.
                    .presentationSizing(.fitted)
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
    // is the thickest on the page (2.5px, owner correction Nov 12,
    // 2026 — was 1.5px), so it stays the anchor card above the
    // 2px-outlined Charity / Extra Fund cards below it.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weekly Budget")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
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
                .stroke(DesignTokens.primary, lineWidth: 2.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("home.weeklyBudget")
        // Hero exception: outline, NO shadow (styles.css:1127).
    }

    /// Full-size hero skeleton: same frame, padding, rows and
    /// spacing as the loaded hero, with shimmer blocks where the
    /// week label, figure, sync button, progress bar, spent line
    /// and stats go — the same rows as heroLoaded, in the same
    /// order, and no extra row the loaded hero lacks — so the page
    /// never jumps when the numbers arrive (audit H-P2-5). Verified
    /// against heroLoaded, Nov 12 2026: label / figure row with the
    /// 44pt sync-button block / progress bar / spent line / stats
    /// row, all present, all the same sizes.
    private var heroSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBlock(width: 160, height: 18)
            HStack(spacing: 12) {
                SkeletonBlock(width: 230, height: 54, cornerRadius: 8)
                Spacer()
                SkeletonBlock(width: 44, height: 44, cornerRadius: 22)
            }
            SkeletonBlock(height: 8, cornerRadius: 4)
            SkeletonBlock(width: 180, height: 14)
            HStack(spacing: 24) {
                SkeletonBlock(width: 110, height: 40)
                SkeletonBlock(width: 80, height: 40)
            }
        }
        .accessibilityLabel("Weekly Budget, loading")
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
        Text(AppDates.weekLabel(weekStart: result.weekStart))
            .font(.system(size: 15))
            .foregroundStyle(Color(hex: "#6b7280"))

        // Big figure — the whole figure row (not just the digits)
        // opens the Weekly sheet; the sync button stays its own
        // tap target at the end of the row.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { showWeeklySheet = true } label: {
                heroFigure(cents: result.availableCents)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
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
                        // White icon on the blue state; dark ink on the
                        // grey state — white-on-grey was ~1.1:1 and
                        // effectively invisible (audit H-P1-1).
                        .foregroundStyle(viewModel.allowanceSet == true ? .white : DesignTokens.ink)
                        .frame(width: 44, height: 44)
                        .background(
                            viewModel.allowanceSet == true
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
            }
        }

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
                    .fill(overBudget ? DesignTokens.errorText : DesignTokens.primary)
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

        // Hero stats row: Weekly allowance (effective) + Purchases.
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly Allowance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(viewModel.allowanceSet == false
                     ? "Not set"
                     : MoneyFormat.string(cents: capacity))
                    .font(.system(size: 17, weight: viewModel.allowanceSet == false ? .regular : .bold))
                    .foregroundStyle(viewModel.allowanceSet == false ? DesignTokens.muted : DesignTokens.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Purchases")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
                Text(viewModel.purchasesThisWeek.map(String.init) ?? "N/A")
                    .font(.system(size: 17, weight: .bold))
            }
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
        // Lands scrolled to the Budget card in Settings (owner
        // decision #27).
        if viewModel.isAdmin, viewModel.allowanceSet == false {
            Button("Set Your Weekly Allowance") {
                appState.openSettings(to: .budget)
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
            .font(.system(size: 44, weight: .heavy))
            + Text("." + parts.cents)
            .font(.system(size: 24, weight: .heavy)))
            .foregroundStyle(cents < 0 ? DesignTokens.errorText : DesignTokens.ink)
    }

    // MARK: Stat cards — Charity above Extra Fund

    private var charityCard: some View {
        statCard(
            title: "Charity",
            face: charityFaceText,
            theme: .charity,
            isLoading: viewModel.charity.isLoading,
            faceIsNegative: false,
            statusText: charityStatusText,
            statusIsError: viewModel.charity.isFailed,
            isExpanded: appState.expandedCard == .charity,
            ariaLabel: charityAriaLabel,
            onTap: {
                switch viewModel.charity {
                case .loading:
                    notLoadedAlertTitle = "Charity"
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    // Failed cards expand too, so the error + Retry
                    // are reachable; loading still shows the alert.
                    withAnimation(ExpandAnimation.animation) {
                        appState.expandedCard = appState.expandedCard == .charity ? nil : .charity
                    }
                }
            }
        ) {
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
            faceIsNegative: fundFaceIsNegative,
            statusText: fundStatusText,
            statusIsError: viewModel.fund.isFailed,
            isExpanded: appState.expandedCard == .fund,
            ariaLabel: fundAriaLabel,
            onTap: {
                switch viewModel.fund {
                case .loading:
                    notLoadedAlertTitle = "Extra Fund"
                    showNotLoadedAlert = true
                case .failed, .loaded:
                    withAnimation(ExpandAnimation.animation) {
                        appState.expandedCard = appState.expandedCard == .fund ? nil : .fund
                    }
                }
            }
        ) {
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
    /// rotating 180° to up when expanded, with the shared
    /// ExpandAnimation). Bigger and outlined (owner, Nov 12, 2026,
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
    private func statCard<Rows: View>(
        title: String,
        face: String,
        theme: StatCardTheme,
        isLoading: Bool,
        faceIsNegative: Bool = false,
        statusText: String? = nil,
        statusIsError: Bool = false,
        isExpanded: Bool,
        ariaLabel: String,
        onTap: @escaping () -> Void,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if isLoading {
                    SkeletonBlock(width: 36, height: 36, cornerRadius: 10)
                } else {
                    Image(systemName: theme.iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.deep)
                        .frame(width: 36, height: 36)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.outline, lineWidth: 1)
                        )
                }
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DesignTokens.ink)
                Spacer()
            }
            if isLoading {
                SkeletonBlock(width: 150, height: 34, cornerRadius: 8)
            } else if statusIsError {
                SkeletonBlock(width: 150, height: 34, cornerRadius: 8, animated: false)
            } else {
                Text(face)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(faceIsNegative ? DesignTokens.errorText : theme.deep)
            }
            if let statusText {
                Text(statusText)
                    .font(.system(size: 13, weight: statusIsError ? .semibold : .regular))
                    .foregroundStyle(statusIsError ? DesignTokens.errorText : Color(hex: "#6b7280"))
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) { rows() }
                    .padding(.top, 4)
                    .transition(ExpandAnimation.transition)
            }
            HStack {
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignTokens.primary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(ExpandAnimation.animation, value: isExpanded)
            }
        }
        .padding(20)
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
        .animation(ExpandAnimation.animation, value: isExpanded)
        .accessibilityLabel(ariaLabel)
        .accessibilityAddTraits(.isButton)
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

    /// A negative Extra Fund balance reads red, like the hero's
    /// over-budget figure. (A negative Charity remaining means
    /// ahead on giving, so it stays deep green.)
    private var fundFaceIsNegative: Bool {
        if case .loaded(let summary) = viewModel.fund { return summary.availableCents < 0 }
        return false
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
                // language, Nov 12, 2026).
                VStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in TransactionRowSkeleton() }
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
/// Unlinked refunds. No explainer line under the header (owner,
/// Nov 12 2026): the "Pending transactions are included and
/// marked." line crowded the header, and pending state is already
/// marked on the rows. Show Transactions (primary) + Close
/// (tertiary) — two-button sheet rule. iPad: 600pt wide, centred
/// (.presentationSizing(.fitted) + fixed width in the regular size
/// class); iPhone: full-width.
public struct WeeklySheet: View {
    let week: WeekResult
    let baseAllowanceCents: Int?
    @ObservedObject var appState: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(week: WeekResult, baseAllowanceCents: Int?, appState: AppViewModel) {
        self.week = week
        self.baseAllowanceCents = baseAllowanceCents
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
            // a normal week keeps the approved three rows.
            ForEach(week.sheetRows(baseAllowanceCents: baseAllowanceCents), id: \.label) { row in
                // Deduction rows print with a leading minus
                // (audit H-P2-2) so Base $375 → Allowance $325 adds
                // up on sight; the model cents stay positive.
                sheetRow(label: row.label, value: MoneyFormat.string(cents: row.isDeduction ? -row.cents : row.cents))
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
