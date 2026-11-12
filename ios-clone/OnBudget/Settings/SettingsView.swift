// OnBudget — Settings screen (live web v66, §10).
//
// Entry: profile menu → Settings. Heading "Settings" + "← Back"
// (returns to `previousView`, or Home after a reload — the
// coordinator supplies `onBack`). Cards in order: Profile, Bank
// Connection, Email Alerts, Budget (admin only), Account &
// Household.
//
// Each card is its own view (ProfileSettingsView,
// ConnectedAccountsView, EmailAlertsView, BudgetSettingsView,
// MembersSettingsView) so the coordinator can also present them
// individually. This screen only assembles them and owns the shared
// toast state.

import SwiftUI
import OnBudgetKit

struct SettingsView: View {
    let context: SettingsContext
    let onBack: () -> Void
    let plaidLauncher: PlaidLinkLauncher

    @StateObject private var toast = ToastState()

    init(
        context: SettingsContext,
        onBack: @escaping () -> Void = {},
        plaidLauncher: PlaidLinkLauncher = PlaidLinkNotLinkedLauncher()
    ) {
        self.context = context
        self.onBack = onBack
        self.plaidLauncher = plaidLauncher
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.ink)

                ProfileSettingsView(context: context, toast: toast)
                ConnectedAccountsView(context: context, toast: toast, plaidLauncher: plaidLauncher)
                EmailAlertsView(context: context, toast: toast)
                if context.isAdmin {
                    BudgetSettingsView(context: context, toast: toast)
                }
                MembersSettingsView(context: context, toast: toast)
            }
            .padding()
        }
        .toastOverlay(toast, clearTabBar: false) // Settings is a full-screen cover: no tab bar under it (audit X-P2-1).
    }
}
