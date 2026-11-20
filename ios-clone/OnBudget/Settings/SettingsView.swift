// STAGE — Settings screen (live web v66, §10).
//
// Entry: profile menu → Settings. Heading "Settings" + "← Back"
// (returns to `previousView`, or Home after a reload — the
// coordinator supplies `onBack`). Cards in order: Profile, Bank
// Connection, Email Alerts, Account & Household, Merchant Names.
// (The Budget card moved to the Funds page's Spending fund, build
// 30 — ALL fund settings live there now.)
// Build 43 (owner, Nov 17, 2026): Privacy · Terms is its OWN card
// below the last card, not a bare link at the bottom of the Account
// & Household card.
//
// Each card is its own view (ProfileSettingsView,
// ConnectedAccountsView, EmailAlertsView, MembersSettingsView) so
// the coordinator can also present them individually. This screen
// only assembles them and owns the shared toast state.

import SwiftUI
import OnBudgetKit

struct SettingsView: View {
    let context: SettingsContext
    /// The shared app state (build 46 — the Home Layout switch
    /// below reads and writes `appState.homeLayout`, the per-device
    /// Home layout preference, so flipping it changes Home as soon
    /// as Settings closes).
    let appState: AppViewModel
    let onBack: () -> Void
    let plaidLauncher: PlaidLinkLauncher

    @StateObject private var toast = ToastState()

    init(
        context: SettingsContext,
        appState: AppViewModel,
        onBack: @escaping () -> Void = {},
        plaidLauncher: PlaidLinkLauncher = PlaidLinkNotLinkedLauncher()
    ) {
        self.context = context
        self.appState = appState
        self.onBack = onBack
        self.plaidLauncher = plaidLauncher
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.ink)

                ProfileSettingsView(context: context, toast: toast)
                NotificationsSettingsView(context: context, toast: toast)
                ConnectedAccountsView(context: context, toast: toast, plaidLauncher: plaidLauncher)
                EmailAlertsView(context: context, toast: toast)
                MembersSettingsView(context: context, toast: toast)
                HomeLayoutSettingsCard(appState: appState)
                TakeTheTourSettingsCard(appState: appState, onBack: onBack)
                PrivacyTermsSettingsCard()
                // Merchant Names is NOT here anymore (owner, Nov 15,
                // 2026 — build 34): it moved to the Transactions
                // page ("Merchants" chip), where it felt less
                // "thrown in" than in Settings.
            }
            .padding()
        }
        .toastOverlay(toast) // Top popup toast (owner, Nov 20, 2026 — build 50).
    }
}

/// Build 46 (owner, Nov 18, 2026): the Home Layout switch — the
/// simpler mockup layout is the default, and the previous layout
/// stays available as "Classic" so it can be restored if the owner
/// changes his mind. A per-device preference (each member picks
/// their own layout on their own device), not an admin setting.
private struct HomeLayoutSettingsCard: View {
    @ObservedObject var appState: AppViewModel

    var body: some View {
        SettingsCard(title: "Home Layout") {
            Picker("Home Layout", selection: $appState.homeLayout) {
                Text("Simple").tag(AppViewModel.HomeLayout.simple)
                Text("Classic").tag(AppViewModel.HomeLayout.classic)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.homeLayoutPicker")
        }
    }
}

/// Build 48 (owner, Nov 19, 2026): re-play the first-run
/// walkthrough from Settings ("Take the Tour"). The tour shows once
/// on its own (first entry to Home); this row starts it again any
/// time, from the beginning. Dismisses Settings, lands on Home, and
/// starts the tour after a short delay so the cover is gone first.
private struct TakeTheTourSettingsCard: View {
    @ObservedObject var appState: AppViewModel
    let onBack: () -> Void

    var body: some View {
        SettingsCard(title: "Take the Tour") {
            Text("A quick walk through the app — your spending number, charity, adding, transactions, and funds.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.muted)
            Button("Take the Tour") {
                onBack()
                appState.selectedTab = .home
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    appState.tour.start()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("settings.takeTheTour")
        }
    }
}

/// Build 43 (owner, Nov 17, 2026 — item 13): Privacy · Terms on
/// their OWN card, below the last Settings card — not a bare link at
/// the bottom of the Account & Household card. Same destinations as
/// the auth footer and the old location.
private struct PrivacyTermsSettingsCard: View {
    var body: some View {
        SettingsCard(title: "Privacy · Terms") {
            HStack(spacing: 4) {
                Link("Privacy", destination: URL(string: "https://getstag.us/privacy")!)
                Text("·")
                Link("Terms", destination: URL(string: "https://getstag.us/terms")!)
            }
            .font(.subheadline)
            .foregroundStyle(DesignTokens.mid)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
