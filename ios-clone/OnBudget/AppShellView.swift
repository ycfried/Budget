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
// (household name) + the profile menu.
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
// Build 64 (C-5): the app-shell confirmation popup is ALSO
// attached here (shell root + inside the Settings cover) — see
// ConfirmationPopup.swift. While both attachments live, the
// ContentView call must be retired or gated by the coordinator
// (see that file's header) or the popup renders twice in-app.
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
            pageSelectRow
            selectedTabContent
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
        // Build 64 (C-5): the confirmation popup renders at the
        // APP-SHELL level, above the tab content — so a confirmation
        // fired from Home / Transactions / Funds is seen. The
        // `AppState.showToast` API is unchanged; only the rendering
        // changed, from toast bars to the popup card
        // (ConfirmationPopup.swift). This overlay still renders
        // UNDERNEATH any fullScreenCover presented from the shell
        // or its tabs (covers live above the presenting view), so
        // the Settings cover gets its own attachment inside its
        // content below, and TransactionsView's covers need the
        // same inside theirs. See ConfirmationPopup.swift's header
        // for the ContentView double-rendering note.
        .confirmationPopupOverlay($appState.toast)
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
            } else {
                LoadingView()
            }
        }
        // Build 64 (C-5): the popup attached INSIDE the Settings
        // cover's content, so a confirmation fired while Settings
        // is open renders ABOVE the cover instead of underneath
        // it (a shell-root overlay cannot show above a cover the
        // shell presents). Bound to the same `$appState.toast`, so
        // a confirmation shows exactly once — here while Settings
        // is open, at the shell root otherwise.
        .confirmationPopupOverlay($appState.toast)
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
    /// content). Left-aligned, 16pt in from the edge, inside the
    /// same centred 900pt iPad column as the tab content below
    /// (see `mainContentWidth`). The Funds-tab walkthrough step
    /// points at it (`.pageSelect` tour anchor).
    private var pageSelectRow: some View {
        HStack {
            PageSelectControl(selectedTab: $appState.selectedTab)
                .tourAnchor(.pageSelect, tour: appState.tour)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(DesignTokens.background)
        .mainContentWidth(horizontalSizeClass: horizontalSizeClass)
    }

    /// Build 65: plain view switch on `appState.selectedTab` — no
    /// TabView, so no system tab bar is rendered anywhere (the
    /// build-64 `.tabBarOnly` fix did not hold). The Transactions
    /// tab's own NavigationStack lives inside `transactionsTab`
    /// and is unaffected. Swipe-between-tabs is gone; the owner
    /// navigates via the page select above.
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
                Spacer()
                Menu {
                    Button("Settings") { appState.openSettings() }
                    Button("Sign Out", role: .destructive) {
                        Task { await appState.signOut() }
                    }
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
                    .toolbar(.hidden, for: .navigationBar)
            case .activity:
                ActivityView(context: context, filter: historyFilter, onBack: popTransactionsSubpage)
                    .toolbar(.hidden, for: .navigationBar)
            case .review:
                if let reviewViewModel = reviewViewModel {
                    ReviewPageView(viewModel: reviewViewModel, onBack: popTransactionsSubpage)
                        .toolbar(.hidden, for: .navigationBar)
                } else {
                    LoadingView()
                }
            case .merchantNames:
                MerchantNamesPageView(context: context, toast: historyToast, onBack: popTransactionsSubpage)
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
