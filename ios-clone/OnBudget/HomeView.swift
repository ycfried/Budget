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
        } catch {
            allowanceSet = nil
            allowanceCents = nil
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
                appState.showToast(
                    "Sync done: \(partial.result.added) added, \(partial.result.updated) updated, \(partial.result.skipped) skipped across \(partial.result.items) connected account(s). — \(partial.failedInstitutions.joined(separator: ", "))",
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
            }
            .padding(16)
        }
        .background(DesignTokens.background)
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
        .sheet(isPresented: $showWeeklySheet) {
            if case .loaded(let result) = viewModel.week {
                WeeklySheet(week: result, baseAllowanceCents: viewModel.allowanceCents, appState: appState)
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
    // full hero size (skeleton blocks + system spinner), so the
    // layout never jumps when the number arrives.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weekly Budget")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            switch viewModel.week {
            case .loading:
                heroSkeleton
            case .failed(let error):
                Text("Could not load this week's numbers.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#6b7280"))
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
                .stroke(DesignTokens.primary, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("home.weeklyBudget")
        // Hero exception: outline, NO shadow (styles.css:1127).
    }

    /// Full-size hero skeleton: same frame, padding and row heights
    /// as the loaded hero, with grey placeholder blocks where the
    /// number, progress bar and stats go, plus the system spinner.
    private var heroSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "#ececf1"))
                .frame(width: 160, height: 18)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "#ececf1"))
                .frame(width: 230, height: 54)
            ProgressView()
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, alignment: .center)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: "#ececf1"))
                .frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "#ececf1"))
                .frame(width: 180, height: 14)
            HStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#ececf1"))
                    .frame(width: 110, height: 40)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#ececf1"))
                    .frame(width: 80, height: 40)
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

    /// A stat card face is Title + signed number only, chevron
    /// bottom-right (SF Symbol chevron.down, down when collapsed,
    /// rotating 180° to up when expanded, with the shared
    /// ExpandAnimation). The whole card is the tap target — the
    /// chevron is only a visual hint (owner, Nov 11, 2026). The
    /// status line under the number explains a loading or failed
    /// face, so a failed card never shows a bare "—" with no
    /// explanation; the expanded rows carry the ErrorBox + Retry.
    private func statCard<Rows: View>(
        title: String,
        face: String,
        statusText: String? = nil,
        statusIsError: Bool = false,
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
                        if let statusText {
                            HStack(spacing: 6) {
                                if !statusIsError {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.8)
                                }
                                Text(statusText)
                                    .font(.system(size: 13, weight: statusIsError ? .semibold : .regular))
                                    .foregroundStyle(statusIsError ? DesignTokens.errorText : Color(hex: "#6b7280"))
                            }
                        }
                    }
                    Spacer()
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.05),
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(ExpandAnimation.animation, value: isExpanded)
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

    /// Status line under the Charity face: loading gets a spinner +
    /// "Loading…", failure gets a plain red "Could not load" (the
    /// expanded rows carry the ErrorBox + Retry). Loaded: none.
    private var charityStatusText: String? {
        switch viewModel.charity {
        case .loading: return "Loading…"
        case .failed: return "Could not load"
        case .loaded: return nil
        }
    }

    /// Same status line for Extra Fund.
    private var fundStatusText: String? {
        switch viewModel.fund {
        case .loading: return "Loading…"
        case .failed: return "Could not load"
        case .loaded: return nil
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
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity)
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
                        StatePill(row)
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
/// Unlinked refunds. Message: "Pending transactions are included
/// and marked." (+ the unlinked sentence when the 4th row is
/// present). Show Transactions (primary) + Close (tertiary) —
/// two-button sheet rule.
public struct WeeklySheet: View {
    let week: WeekResult
    let baseAllowanceCents: Int?
    @ObservedObject var appState: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init(week: WeekResult, baseAllowanceCents: Int?, appState: AppViewModel) {
        self.week = week
        self.baseAllowanceCents = baseAllowanceCents
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
            // Reconciliation rows (live.js v69): Base / Temporary /
            // Carried debt appear exactly when they change the number;
            // a normal week keeps the approved three rows.
            ForEach(week.sheetRows(baseAllowanceCents: baseAllowanceCents), id: \.label) { row in
                sheetRow(label: row.label, value: MoneyFormat.string(cents: row.cents))
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
