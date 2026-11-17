// OnBudget — Settings screen (live web v66, §10).
//
// Entry: profile menu → Settings. Heading "Settings" + "← Back"
// (returns to `previousView`, or Home after a reload — the
// coordinator supplies `onBack`). Cards in order: Profile, Bank
// Connection, Email Alerts, Account & Household, Merchant Names.
// (The Budget card moved to the Funds page's Spending fund, build
// 30 — ALL fund settings live there now.)
//
// Each card is its own view (ProfileSettingsView,
// ConnectedAccountsView, EmailAlertsView, MembersSettingsView) so
// the coordinator can also present them individually. This screen
// only assembles them and owns the shared toast state.

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
                ConnectedAccountsView(context: context, toast: toast, plaidLauncher: plaidLauncher)
                EmailAlertsView(context: context, toast: toast)
                MembersSettingsView(context: context, toast: toast)
                // Merchant Names is NOT here anymore (owner, Nov 15,
                // 2026 — build 34): it moved to the Transactions
                // page ("Merchants" chip), where it felt less
                // "thrown in" than in Settings.
            }
            .padding()
        }
        .toastOverlay(toast) // Centered mid-screen popup (owner, Nov 16, 2026 — build 38).
    }
}
