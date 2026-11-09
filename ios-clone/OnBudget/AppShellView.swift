// OnBudget — AppShellView.swift
//
// App shell + tab bar (CLONE_SPEC §0.1–0.2, §2.2).
// Home on EVERY fresh load (app start, login, reopen), never on
// in-app navigation. Tab bar: Home, Transactions, Funds.
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
//   Trash is reached from the Transactions "Trash (N)" link only
//   (CLONE_SPEC §11; admin-only, hidden at 0).
// - Funds: `FundsView(context:appState:)`; shares `expandedCard`
//   with Home and opens Temporary Allowance on
//   `pendingTemporaryAllowance` (Settings Budget link).
// - Settings: `SettingsView` in a full-screen cover; its context
//   carries `onShowWeekTransactions` → `showTransactionsForWeek`
//   (Past Weeks tap opens Transactions filtered to that week) and
//   `onOpenTemporaryAllowance` → `openTemporaryAllowance`.
// Toasts render at the ContentView root so they also show on the
// Auth screen (account-created / account-deleted notices).
//
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

public struct AppShellView: View {
    @ObservedObject var appState: AppViewModel
    @State private var transactionsViewModel: TransactionsViewModel?

    public init(appState: AppViewModel) { self.appState = appState }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: $appState.selectedTab) {
                homeTab
                    .tabItem {
                        Label("Home", systemImage: "house")
                    }
                    .tag(AppTab.home)
                transactionsTab
                    .tabItem {
                        Label("Transactions", systemImage: "list.bullet")
                    }
                    .tag(AppTab.transactions)
                fundsTab
                    .tabItem {
                        Label("Funds", systemImage: "banknote")
                    }
                    .tag(AppTab.funds)
            }
            .tint(DesignTokens.primary)
        }
        .fullScreenCover(isPresented: $appState.showSettings) {
            settingsCover
        }
        .task { ensureTransactionsViewModel() }
        .onChange(of: appState.householdId) { _, _ in ensureTransactionsViewModel() }
    }

    /// Settings as a full-screen cover (CLONE_SPEC §2.2 — not a
    /// tab). The tab underneath is left alone so dismissing Settings
    /// returns to where the user was; the "Open Temporary Allowance"
    /// link is the one exception — it closes Settings and switches
    /// to Funds (see `AppViewModel.openTemporaryAllowance`).
    private var settingsCover: some View {
        NavigationStack {
            if let context = settingsContext() {
                SettingsView(context: context, onBack: { appState.showSettings = false })
            } else {
                LoadingView()
            }
        }
    }

    /// The Settings context the shell owns: session + household from
    /// AppViewModel, handoffs back into the shell. Past Weeks taps
    /// land on Transactions filtered to that week; the Budget card's
    /// Temporary Allowance link lands on the Funds form.
    private func settingsContext() -> SettingsContext? {
        guard let householdId = appState.householdId,
              let role = appState.role else { return nil }
        return SettingsContext(
            client: appState.client,
            householdId: householdId,
            isAdmin: appState.isAdmin,
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
            onOpenTemporaryAllowance: { appState.openTemporaryAllowance() }
        )
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 40, height: 40)
            Spacer()
            Text(appState.householdName ?? "OnBudget")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DesignTokens.ink)
            Spacer()
            Menu {
                Button("Settings") { appState.openSettings() }
                Button("Sign Out", role: .destructive) {
                    Task { await appState.signOut() }
                }
            } label: {
                Image(systemName: "person.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(DesignTokens.ink)
                    .frame(width: 40, height: 40)
                    .background(.white)
                    .overlay(
                        Circle().stroke(Color(hex: "#e5e7eb"), lineWidth: 1)
                    )
                    .clipShape(Circle())
            }
            .accessibilityLabel("Profile")
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

    @ViewBuilder
    private var transactionsTab: some View {
        if let viewModel = transactionsViewModel {
            TransactionsView(viewModel: viewModel, appState: appState)
        } else {
            LoadingView()
        }
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
        transactionsViewModel = viewModel
    }
}
