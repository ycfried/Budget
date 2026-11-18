// OnBudget — Settings screen (live web v66, §10).
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
                NotificationsSettingsView(context: context, toast: toast)
                ConnectedAccountsView(context: context, toast: toast, plaidLauncher: plaidLauncher)
                EmailAlertsView(context: context, toast: toast)
                MembersSettingsView(context: context, toast: toast)
                PrivacyTermsSettingsCard()
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

/// Build 43 (owner, Nov 17, 2026 — item 13): Privacy · Terms on
/// their OWN card, below the last Settings card — not a bare link at
/// the bottom of the Account & Household card. Same destinations as
/// the auth footer and the old location.
private struct PrivacyTermsSettingsCard: View {
    var body: some View {
        SettingsCard(title: "Privacy · Terms") {
            HStack(spacing: 4) {
                Link("Privacy", destination: URL(string: "https://ycfried.github.io/Budget/privacy.html")!)
                Text("·")
                Link("Terms", destination: URL(string: "https://ycfried.github.io/Budget/terms.html")!)
            }
            .font(.subheadline)
            .foregroundStyle(DesignTokens.mid)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
