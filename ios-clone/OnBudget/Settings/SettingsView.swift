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

/// A Settings section a caller can ask Settings to land on when it
/// opens (owner decision #27: "Set Your Weekly Allowance" lands on
/// the Budget card). Carried on `AppViewModel.settingsScrollTarget`
/// and consumed once by `SettingsView`.
enum SettingsScrollTarget: String, Hashable {
    case budget
}

struct SettingsView: View {
    let context: SettingsContext
    let onBack: () -> Void
    let plaidLauncher: PlaidLinkLauncher
    /// Section to scroll to on open, if any. Nil = top of Settings.
    let scrollTarget: SettingsScrollTarget?

    @StateObject private var toast = ToastState()

    init(
        context: SettingsContext,
        onBack: @escaping () -> Void = {},
        plaidLauncher: PlaidLinkLauncher = PlaidLinkNotLinkedLauncher(),
        scrollTarget: SettingsScrollTarget? = nil
    ) {
        self.context = context
        self.onBack = onBack
        self.plaidLauncher = plaidLauncher
        self.scrollTarget = scrollTarget
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                            .id(SettingsScrollTarget.budget)
                    }
                    MembersSettingsView(context: context, toast: toast)
                }
                .padding()
            }
            .onAppear {
                // Defer one runloop turn so the cards have laid out
                // before scrolling to the requested section.
                guard let target = scrollTarget else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
        .toastOverlay(toast, clearTabBar: false) // Settings is a full-screen cover: no tab bar under it (audit X-P2-1).
    }
}
