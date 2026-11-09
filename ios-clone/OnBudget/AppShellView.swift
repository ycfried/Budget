// OnBudget — AppShellView.swift
//
// App shell + tab bar (CLONE_SPEC §0.1–0.2, §2.2).
// Home on EVERY fresh load (app start, login, reopen), never on
// in-app navigation. Tab bar: Home, Transactions, Funds, Settings.
// Top bar: white, bottom hairline, title centred, profile button
// right (white bg, dark icon, light-grey border, no blue fill).
// The profile menu offers Settings and Sign Out.
//
// Transactions / Funds / Settings screens are owned by other
// builders; the placeholders here only carry the handoffs this
// workstream wires (recent-row jump, weekly-sheet week filter) so
// the receiving screens can consume them.
//
// Clone basis: live web v66.

import SwiftUI
import OnBudgetKit

public struct AppShellView: View {
    @ObservedObject var appState: AppViewModel

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
                PlaceholderScreen(
                    title: "Transactions",
                    note: "Owned by the Transactions builder.",
                    appState: appState)
                    .tabItem {
                        Label("Transactions", systemImage: "list.bullet")
                    }
                    .tag(AppTab.transactions)
                PlaceholderScreen(
                    title: "Funds",
                    note: "Owned by the Funds builder.",
                    appState: appState)
                    .tabItem {
                        Label("Funds", systemImage: "banknote")
                    }
                    .tag(AppTab.funds)
                PlaceholderScreen(
                    title: "Settings",
                    note: "Owned by the Settings builder.",
                    appState: appState)
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(AppTab.settings)
            }
            .tint(DesignTokens.primary)
        }
        .toastOverlay($appState.toast)
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
                Button("Settings") { appState.selectedTab = .settings }
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
}

/// Temporary placeholder for screens owned by other builders. It
/// surfaces the handoffs this workstream wires so the receiving
/// screen can consume them, and never pretends to be the screen.
public struct PlaceholderScreen: View {
    let title: String
    let note: String
    @ObservedObject var appState: AppViewModel

    public init(title: String, note: String, appState: AppViewModel) {
        self.title = title
        self.note = note
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(TitleCase.apply(to: title))
                .font(.system(size: 22, weight: .bold))
            Text(note)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "#6b7280"))
            if title == "Transactions" {
                if let jump = appState.pendingTransactionJump {
                    Text("Jump to transaction \(jump.uuidString) — expand its detail; clear search and filters first. If the row is not in the loaded page, toast: \"That transaction is not in the loaded list — tap Load more for older ones.\"")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
                if let week = appState.pendingWeekFilter {
                    Text("Week filter: \(AppDates.long(week)) (Sun–Sat).")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#6b7280"))
                }
            }
            Spacer()
        }
        .padding(20)
        .background(DesignTokens.background)
    }
}
