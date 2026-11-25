// STAGE — AppShellView.swift
//
// App shell + page select (CLONE_SPEC §0.1–0.2, §2.2).
// Home on EVERY fresh load (app start, login, reopen), never on
// in-app navigation. Build 65: there is NO TabView and NO bottom
// tab bar any more. The shell switches on `appState.selectedTab`
// (home / transactions / funds) and renders ONE PageSelectControl
// (SharedViews) below the top bar, above the switched content —
// the single Home/Transactions/Funds control for all three tabs,
// on iPhone and iPad. History: the TabView rendered as a top
// segmented pill on iPad (regular size class) above Home's /
// Funds' own PageSelectControl floaters — two page selects at
// once. Build 64's `.tabViewStyle(.tabBarOnly)` did not hold —
// the duplicate was still seen on Home AND Funds — so build 65
// removes the TabView outright (and the per-page floaters with
// it). Losing swipe-between-tabs is accepted: the owner
// navigates via the page select. The `UseFloatingTabBar` default
// was removed from OnBudgetApp.init with the TabView — see
// that file.
// The top bar keeps just the title
// (household name) + the profile menu, plus the bank-sync button
// on the left on the Home tab (build 71 — it moved off the
// Spending card).
// Settings is NOT a tab — reached from the profile menu only, as a
// full-screen cover over the current tab.
// Top bar: white, bottom hairline, title centred, profile button
// right (white bg, dark icon, light-grey border, no blue fill).
// The profile menu offers Settings and Sign Out.
//
// Wiring (integration, Nov 9, 2026 — the placeholders are gone):
// - Home: `HomeView(appState:householdId:)` (Auth/Home builder).
// - Transactions: `TransactionsView(viewModel:appState:)`; the view
//   model is created here once the household is known and consumes
//   the shell handoffs `pendingWeekFilter` / `pendingTransactionJump`.
//   The tab owns its own NavigationStack (neither the Settings-cover
//   stack nor the Filters sheet's stack inside TransactionsView owns
//   this tab): the "Past Weeks" / "Activity" links push
//   PastWeeksView / ActivityView as subpages, the native equivalent
//   of the web's full pages, sharing one HistoryFilterState. A Past
//   Week tap pops back to the list and then applies the week filter.
//   Trash is reached from the Transactions "Trash (N)" link only
//   (CLONE_SPEC §11; admin-only, hidden at 0).
// - Funds: `FundsView(context:appState:)`; shares `expandedCard`
//   with Home.
// - Settings: `SettingsView` in a full-screen cover; its context
//   carries `onShowWeekTransactions` → `showTransactionsForWeek`
//   (Past Weeks tap opens Transactions filtered to that week).
// Toasts render at the ContentView root so they also show on the
// Auth screen (account-created / account-deleted notices).
// Build 64 (C-5): the app-shell toast is ALSO attached here
// (shell root + inside the Settings cover). While both
// attachments live, the ContentView call stays gated to the
// non-.app phases (see ContentView) or the toast renders twice
// in-app. (Build 74: the Nov 23 branded confirmation popup is
// retired — the top toast is the one confirmation style, owner
// Nov 24, 2026.)
//
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

/// A Transactions-tab subpage (CLONE_SPEC §7 page links). Pushed
/// onto the Transactions NavigationStack — the native equivalent of
/// the web's full Past Weeks / Activity pages.
enum TransactionsSubpage: Hashable {
    case pastWeeks
    case activity
    /// Build 30: Review moved off the Funds page to its own page
    /// here (Transactions "Review" button with a count badge).
    case review
    /// Build 34: Merchant Names moved out of Settings to its own
    /// page here (Transactions "Merchants" chip).
    case merchantNames
}

public struct AppShellView: View {
    @ObservedObject var appState: AppViewModel
    @State private var transactionsViewModel: TransactionsViewModel?
    /// The Review page's FundsViewModel, owned by the shell so the
    /// Transactions tab's Review badge and the Review page share
    /// one live instance (build 30). It only ever loads review
    /// data (`refreshReview()`), never the fund loads.
    @State private var reviewViewModel: FundsViewModel?
    /// The Transactions tab's navigation path. Owned by the shell
    /// (not the tab) so it survives tab switches and the week-tap
    /// pop in `historyContext()` can reach it.
    @State private var transactionsPath: [TransactionsSubpage] = []
    /// One date filter shared by Past Weeks and Activity, as on the
    /// web (`HistoryFilterState`).
    @StateObject private var historyFilter = HistoryFilterState()
    /// Toasts for the history subpages (e.g. the week-tap "Showing
    /// transactions…" line). Owned here so the toast survives the
    /// pop back to the list.
    @StateObject private var historyToast = ToastState()

    /// iPad content width (build 36): the shell's page-select row
    /// reads as part of the centred 900pt column on the regular
    /// size class, like the tab content below it.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(appState: AppViewModel) { self.appState = appState }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            // Build 77 (owner, Nov 25, 2026): the pages bar
            // (Home / Transactions / Funds) sits at the BOTTOM
            // now, not the top — easier to reach, and the top
            // reads cleaner. The bar itself is unchanged
            // (floating white card); only its place in the
            // VStack moved. The content takes the remaining
            // height above the bar, so no row hides under it.
            selectedTabContent
            pageSelectRow
        }
        // The walkthrough's coordinate space (build 48): every tour
        // anchor reports its frame in "tourSpace", and the overlay
        // below draws in the same space, so the cutout and the
        // tooltip land on the real element.
        .coordinateSpace(name: "tourSpace")
        .overlay {
            if appState.tour.isActive {
                TourOverlayView(
                    tour: appState.tour,
                    appState: appState,
                    transactionsViewModel: transactionsViewModel
                )
            }
        }
        // Build 64 (C-5): the toast renders at the APP-SHELL
        // level, above the tab content — so a confirmation fired
        // from Home / Transactions / Funds is seen. This overlay
        // still renders UNDERNEATH any fullScreenCover presented
        // from the shell or its tabs (covers live above the
        // presenting view), so the Settings cover gets its own
        // attachment inside its content below, and
        // TransactionsView's covers need the same inside theirs.
        // (Build 74: the Nov 23 branded popup card is retired —
        // the top toast is the one confirmation style, owner
        // Nov 24, 2026.)
        .toastOverlay($appState.toast)
        .fullScreenCover(isPresented: $appState.showSettings) {
            settingsCover
        }
        // Root toasts clear on tab change (audit X-P2-13): a toast
        // fired on one tab must not linger over the next screen
        // for the rest of its 4s. The history toast is a separate
        // ToastState owned here and deliberately survives the
        // Past-Weeks → Transactions pop (see transactionsTab) —
        // this clears only the root `appState.toast`.
        // Tab reset (owner, Nov 16, 2026 — build 40): a USER tab tap
        // always lands on that tab's TOP-LEVEL MAIN page — the
        // Transactions NavigationStack path pops back to the main
        // list, and any expanded fund card collapses — so a tab
        // never resumes a leftover sub-view. A PROGRAMMATIC tab
        // change (Home "See All", a recent-row jump, the Weekly
        // sheet's "Show Transactions", "Set Your Weekly Allowance")
        // sets `suppressNextTabReset` first and skips this reset,
        // because it intentionally lands on a sub-view. The
        // accordion/expand behavior WITHIN a page is unchanged —
        // this only resets when LEAVING a tab and coming back.
        .onChange(of: appState.selectedTab) { _, newTab in
            appState.toast = nil
            if appState.suppressNextTabReset {
                appState.suppressNextTabReset = false
            } else {
                transactionsPath = []
                appState.expandedCard = nil
            }
            // Build 42 (owner, Nov 17, 2026 — Home stale after
            // Funds changes): Home's figures load once at boot
            // and `refreshIfNeeded()` is a no-op once loaded, so
            // coming back from Funds showed stale fund numbers
            // (e.g. Tzedaka $663.00 after Add to Charity / Record
            // a Gift). Reload Home whenever the Home tab becomes
            // active. `refresh()` coalesces with an in-flight
            // load, so a fast tab switch never doubles the fetch,
            // and it never blanks loaded cards (performRefresh
            // keeps last-known values on screen until the new ones
            // land).
            if newTab == .home {
                Task { await appState.homeViewModel?.refresh() }
            }
        }
        .task { ensureTransactionsViewModel(); ensureReviewViewModel() }
        .onChange(of: appState.householdId) { _, _ in ensureTransactionsViewModel(); ensureReviewViewModel() }
        // Build 43 (owner, Nov 17, 2026 — item 16): the shell-owned
        // view models compose toasts/alerts with the funds' CURRENT
        // display names — a rename must reach them too, not just
        // the views that read `appState.fundNames` directly.
        .onChange(of: appState.fundNames) { _, names in
            transactionsViewModel?.fundNames = names
            reviewViewModel?.fundNames = names
        }
        // Build 77 (owner, Nov 25, 2026): the transaction jump
        // lands with the row ALREADY open. Tapping a Home row
        // first showed the Transactions page as-is, then the row
        // expanded a beat later (consumeHandoffs runs in
        // onAppear, after first paint) — it felt slow. The
        // Transactions view model is shell-owned and long-lived,
        // so when a jump is set, pre-expand the row here if it
        // is already in the loaded page — the first Transactions
        // frame then renders with the row open. The async jump in
        // consumeHandoffs stays as the fallback: it clears
        // filters and loads the full list when the row is not in
        // the loaded page.
        .onChange(of: appState.pendingTransactionJump) { _, jumpId in
            guard let jumpId,
                  let viewModel = transactionsViewModel,
                  viewModel.loadedPage.contains(where: { $0.id == jumpId }) else { return }
            viewModel.expandedTransactionId = jumpId
        }
    }

    /// Settings as a full-screen cover (CLONE_SPEC §2.2 — not a
    /// tab). The tab underneath is left alone so dismissing Settings
    /// returns to where the user was.
    private var settingsCover: some View {
        NavigationStack {
            if let context = settingsContext() {
                SettingsView(
                    context: context,
                    appState: appState,
                    onBack: {
                        appState.dismissSettings()
                    },
                    plaidLauncher: PlaidLinkKitLauncher()
                )
                // Build 68 (item 18): the Settings cover is its
                // own NavigationStack with a hidden bar — the
                // edge swipe back needs re-enabling inside the
                // stack (see enableSwipeBack in SharedViews).
                .enableSwipeBack()
            } else {
                LoadingView()
            }
        }
        // Build 64 (C-5): the toast attached INSIDE the Settings
        // cover's content, so a confirmation fired while Settings
        // is open renders ABOVE the cover instead of underneath
        // it (a shell-root overlay cannot show above a cover the
        // shell presents). Bound to the same `$appState.toast`, so
        // a confirmation shows exactly once — here while Settings
        // is open, at the shell root otherwise.
        .toastOverlay($appState.toast)
        // Build 70, item 2 (owner, Nov 24, 2026): swipe-right
        // dismisses the Settings cover, matching the top-left
        // Back button. (SettingsView has no SheetHeader, so the
        // gesture does not come from there.)
        .sheetSwipeBack()
    }

    /// The Settings context the shell owns: session + household from
    /// AppViewModel, handoffs back into the shell. Past Weeks taps
    /// land on Transactions filtered to that week.
    private func settingsContext() -> SettingsContext? {
        guard let householdId = appState.householdId,
              let role = appState.role else { return nil }
        return SettingsContext(
            client: appState.client,
            householdId: householdId,
            isAdmin: appState.isAdmin,
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
            onShowWeekTransactions: { appState.showTransactionsForWeek($0) },
            unregisterPushToken: { await appState.unregisterPushToken() }
        )
    }

    /// Build 65: the ONE page select for all three tabs — Home /
    /// Transactions / Funds, the current page active as a white
    /// floater — rendered here in the shell, below the top bar and
    /// above the switched tab content, so it can never render
    /// twice. It stays pinned while the tab content scrolls
    /// beneath it (it used to scroll away with the Home/Funds
    /// content). Build 66 (owner, Nov 23, 2026): CENTRED and
    /// floating — the control is a white floating card (see
    /// PageSelectControl) and sits in the middle of the row, not
    /// left-aligned — the Lean look was nicer. Inside the same
    /// centred 900pt iPad column as the tab content below (see
    /// `mainContentWidth`). The Funds-tab walkthrough step
    /// points at it (`.pageSelect` tour anchor).
    private var pageSelectRow: some View {
        HStack {
            Spacer()
            PageSelectControl(selectedTab: $appState.selectedTab)
                .tourAnchor(.pageSelect, tour: appState.tour)
            Spacer()
        }
        .padding(.horizontal, 16)
        // Build 77 (owner, Nov 25, 2026): the bar moved to the
        // BOTTOM. The build-76 12pt bottom padding was for the
        // top position (the card's bottom edge + shadow were
        // painted over by the content below). At the bottom the
        // mirror applies: 12pt ABOVE gives the card's rounded
        // top + shadow room against the content above, and 16pt
        // below keeps the floating card clear of the home
        // indicator / screen edge with room for its shadow.
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(DesignTokens.background)
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
    }

    /// Build 65: plain view switch on `appState.selectedTab` — no
    /// TabView, so no system tab bar is rendered anywhere (the
    /// build-64 `.tabBarOnly` fix did not hold). The Transactions
    /// tab's own NavigationStack lives inside `transactionsTab`
    /// and is unaffected. Swipe-between-tabs is gone; the owner
    /// navigates via the page select below.
    @ViewBuilder
    private var selectedTabContent: some View {
        switch appState.selectedTab {
        case .home:
            homeTab
        case .transactions:
            transactionsTab
        case .funds:
            fundsTab
        }
    }

    private var topBar: some View {
        // Title stays centred via the ZStack (the right-hand
        // profile icon is the only control, so an HStack with a
        // matching left spacer would drift it).
        // Profile: bigger, easily tappable icon (28pt glyph in a
        // 44pt hit target, icon alone — owner, Nov 12, 2026: "No
        // need to write profile next to the icon"; reverses the
        // Nov 11 "Profile" text-label addition).
        // The Menu still opens Profile → Settings / Sign Out.
        ZStack {
            Text(appState.householdName ?? "STAGE")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                // 56pt per side clears the 44pt icon plus a 12pt
                // gap (matching the bar's outer padding); the old
                // 110pt reservation matched the icon + "Profile"
                // label (~110pt) and truncated longer household
                // names early on narrow phones (audit H-P2-10).
                .padding(.horizontal, 56)
            HStack {
                // Build 71: the Home-level bank sync, left of the
                // title — Home tab only (it refreshes Home's
                // figures; the other tabs have no use for it). The
                // 44pt button balances the 44pt profile icon on
                // the right, so the centred title stays centred.
                // It used to live on the Spending card (build 48),
                // where its 44pt frame made the Spending header
                // taller than the Tzedaka header — the main reason
                // the two Home cards looked different.
                if appState.selectedTab == .home, let homeViewModel = appState.homeViewModel {
                    TopBarSyncButton(viewModel: homeViewModel)
                }
                Spacer()
                Menu {
                    Button("Settings") { appState.openSettings() }
                    // Build 69 (owner, Nov 24, 2026): Sign Out sits
                    // right under Settings with nothing between
                    // them — too easy to tap by accident. A divider
                    // separates it, and it keeps its destructive
                    // red (#dc2626, not the system role red).
                    Divider()
                    Button("Sign Out") {
                        Task { await appState.signOut() }
                    }
                    .foregroundStyle(Color(hex: "#dc2626"))
                } label: {
                    Image(systemName: "person.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(DesignTokens.ink)
                        .frame(width: 44, height: 44)
                        .background(.white)
                        .overlay(
                            Circle().stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                        )
                        .clipShape(Circle())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Profile")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white)
        .overlay(
            Rectangle()
                .fill(Color(hex: "#ececf1"))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// Build 71: the bank-sync button — one Home-level refresh in
    /// the shell top bar (Home tab only), not on the Spending card.
    /// Same look and behaviour as the card button it replaces: a
    /// plain arrow in deep blue (ink while no allowance is set),
    /// 44pt hit target, spinning while syncing, visible to every
    /// role (build 64, F-19 — syncBank() itself is open to
    /// members). It observes the HomeViewModel directly, so the
    /// spin and the disabled state stay live.
    private struct TopBarSyncButton: View {
        @ObservedObject var viewModel: HomeViewModel

        var body: some View {
            Button { Task { await viewModel.syncBank() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 20, weight: .semibold))
                    // Deep-blue arrow when an allowance is set; dark
                    // ink when not set — both read on white, and the
                    // states still tell apart (audit H-P1-1:
                    // white-on-grey was ~1.1:1 and effectively
                    // invisible).
                    .foregroundStyle(viewModel.allowanceSet == true ? DesignTokens.deep : DesignTokens.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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

    @ViewBuilder
    private var homeTab: some View {
        if let householdId = appState.householdId {
            HomeView(appState: appState, householdId: householdId)
        } else {
            LoadingView()
        }
    }

    /// The Transactions tab owns its own NavigationStack (neither
    /// the Settings-cover stack above nor the Filters sheet's stack
    /// inside TransactionsView owns this tab): the "Past Weeks" /
    /// "Activity" links push PastWeeksView / ActivityView as
    /// subpages. The system navigation bar stays hidden throughout
    /// the stack — each screen renders its own "← Back" button, as
    /// the web clone does — and the history toast overlay sits on
    /// the stack so the week-tap toast survives the pop.
    /// Build 68 (item 18): the hidden bar turns the edge swipe
    /// back off, so `.enableSwipeBack()` re-enables it on the
    /// stack root and on every subpage (SwiftUI re-disables it
    /// when a new screen is pushed).
    @ViewBuilder
    private var transactionsTab: some View {
        if let viewModel = transactionsViewModel,
           let reviewViewModel = reviewViewModel {
            NavigationStack(path: $transactionsPath) {
                TransactionsView(
                    viewModel: viewModel,
                    appState: appState,
                    reviewViewModel: reviewViewModel,
                    onShowPastWeeks: { transactionsPath.append(.pastWeeks) },
                    onShowActivity: { transactionsPath.append(.activity) },
                    onShowReview: { transactionsPath.append(.review) },
                    onShowMerchantNames: { transactionsPath.append(.merchantNames) }
                )
                .enableSwipeBack()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: TransactionsSubpage.self) { page in
                    transactionsSubpage(page)
                }
            }
            .toastOverlay(historyToast)
        } else {
            LoadingView()
        }
    }

    @ViewBuilder
    private func transactionsSubpage(_ page: TransactionsSubpage) -> some View {
        if let context = historyContext() {
            switch page {
            case .pastWeeks:
                PastWeeksView(context: context, toast: historyToast, filter: historyFilter, onBack: popTransactionsSubpage)
                    .enableSwipeBack()
                    .toolbar(.hidden, for: .navigationBar)
            case .activity:
                ActivityView(context: context, filter: historyFilter, onBack: popTransactionsSubpage)
                    .enableSwipeBack()
                    .toolbar(.hidden, for: .navigationBar)
            case .review:
                if let reviewViewModel = reviewViewModel {
                    ReviewPageView(viewModel: reviewViewModel, onBack: popTransactionsSubpage)
                        .enableSwipeBack()
                        .toolbar(.hidden, for: .navigationBar)
                } else {
                    LoadingView()
                }
            case .merchantNames:
                MerchantNamesPageView(context: context, toast: historyToast, onBack: popTransactionsSubpage)
                    .enableSwipeBack()
                    .toolbar(.hidden, for: .navigationBar)
            }
        } else {
            LoadingView()
        }
    }

    /// The Settings context for the history subpages: the shell's
    /// own context, except a Past Week tap pops back to the list
    /// first and THEN applies the week filter — otherwise the
    /// filtered list would sit hidden under the subpage.
    private func historyContext() -> SettingsContext? {
        guard var context = settingsContext() else { return nil }
        context.onShowWeekTransactions = { [self] week in
            popTransactionsSubpage()
            appState.showTransactionsForWeek(week)
        }
        return context
    }

    private func popTransactionsSubpage() {
        guard !transactionsPath.isEmpty else { return }
        transactionsPath.removeLast()
    }

    @ViewBuilder
    private var fundsTab: some View {
        if let householdId = appState.householdId,
           let role = appState.role,
           let userId = appState.client.currentSession?.user.id {
            FundsView(
                context: FundsContext(
                    client: appState.client,
                    householdId: householdId,
                    role: role,
                    userId: userId
                ),
                appState: appState
            )
        } else {
            LoadingView()
        }
    }

    /// The Transactions view model is owned by the shell (one per
    /// household session) so the tab keeps its loaded page + filters
    /// across tab switches. A dead session routes to the expired
    /// screen ("Sign In Again").
    private func ensureTransactionsViewModel() {
        guard let householdId = appState.householdId,
              let userId = appState.client.currentSession?.user.id else { return }
        // Recreate when the household changes (sign-out + sign-in as
        // a different household must not reuse the old page).
        guard transactionsViewModel?.householdId != householdId else { return }
        let viewModel = TransactionsViewModel(
            client: appState.client,
            householdId: householdId,
            isAdmin: appState.isAdmin,
            currentUserId: userId
        )
        viewModel.onSignInAgain = { appState.showSessionExpired() }
        viewModel.fundNames = appState.fundNames
        transactionsViewModel = viewModel
    }

    /// Build 30: the shell-owned FundsViewModel behind the
    /// Transactions "Review" badge and the Review page. Same
    /// household-change guard as the Transactions view model, and
    /// the same FundsContext the Funds tab builds for itself.
    private func ensureReviewViewModel() {
        guard let householdId = appState.householdId,
              let role = appState.role,
              let userId = appState.client.currentSession?.user.id else { return }
        guard reviewViewModel?.context.householdId != householdId else { return }
        let review = FundsViewModel(context: FundsContext(
            client: appState.client,
            householdId: householdId,
            role: role,
            userId: userId
        ))
        review.fundNames = appState.fundNames
        reviewViewModel = review
    }
}
