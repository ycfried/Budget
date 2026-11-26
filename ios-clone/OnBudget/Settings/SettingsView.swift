// STAGE — Settings screen (live web v66, §10).
//
// Build 74 (owner, Nov 24, 2026): Settings is a hub now, not one
// long dense page. The root is a short list — Profile, Household &
// Members, Connections, Notifications, App — and each row pushes a
// focused subpage (the same back-button-top-left + swipe-right
// pattern as the Transactions subpages). Daily flows (Home /
// Transactions / Funds) stay flat; Settings is a rarely-visited
// hub, where a short scannable list beats one long page. The
// section views themselves are unchanged — this file only assembles
// them, owns the shared toast state, and scaffolds the subpages.
//
// Entry: profile menu → Settings. Heading "Settings" + "← Back"
// (returns to `previousView`, or Home after a reload — the
// coordinator supplies `onBack`).
//
// Subpage map (build 74):
// - Profile — ProfileSettingsView (name, email, password,
//   Face ID / Touch ID unlock, Sign Out).
// - Household & Members — MembersSettingsView (household name,
//   invite code, members, roles, Delete Account).
// - Connections — ConnectedAccountsView (Bank Connection via
//   Plaid) + EmailAlertsView (Gmail connection).
// - Notifications — NotificationsSettingsView (All Notifications
//   + categories).
// - App — ReplayTutorialSettingsCard + PrivacyTermsSettingsCard.
//
// The Settings cover in AppShellView is already its own
// NavigationStack, so the hub pushes with NavigationLink(value:)
// + navigationDestination here — no shell change needed. The stack
// root (this hub) and every subpage hide the system navigation bar
// and render their own back chevron, as the Transactions stack
// does; each subpage also re-enables the edge swipe-back (build 68,
// item 18: SwiftUI re-disables it when a new screen is pushed).
// The shared toast overlay rides on the hub AND on every subpage
// scaffold, so a confirmation fired on a subpage still shows — the
// hub's copy sits underneath the pushed page and never double
// renders. The shell's separate appState.toast attachment is a
// different binding — do not merge them.
//
// (The Budget card moved to the Funds page's Spending fund, build
// 30 — ALL fund settings live there now. Merchant Names is NOT
// here anymore (owner, Nov 15, 2026 — build 34): it moved to the
// Transactions page ("Merchants" chip). Build 43 (owner, Nov 17,
// 2026): Privacy · Terms is its OWN card below the last card, not
// a bare link at the bottom of the Account & Household card —
// on the App subpage it sits below the Replay Tutorial card.)

import SwiftUI
import OnBudgetKit

/// One Settings hub row / subpage. The hub lists these in order;
/// each pushes its subpage.
private enum SettingsSubpage: Hashable, CaseIterable {
    case profile
    case household
    case connections
    case notifications
    case app

    /// Title Case — the hub row label and the subpage title.
    var title: String {
        switch self {
        case .profile: "Profile"
        case .household: "Household & Members"
        case .connections: "Connections"
        case .notifications: "Notifications"
        case .app: "App"
        }
    }

    /// One plain line saying what lives behind the row.
    var subtitle: String {
        switch self {
        case .profile: "Name, email, password, sign out"
        case .household: "Household name, invite code, members"
        case .connections: "Bank and Gmail"
        case .notifications: "Which alerts you get"
        case .app: "Tutorial, privacy, and terms"
        }
    }

    var accessibilityID: String {
        switch self {
        case .profile: "profile"
        case .household: "household"
        case .connections: "connections"
        case .notifications: "notifications"
        case .app: "app"
        }
    }
}

struct SettingsView: View {
    let context: SettingsContext
    /// The shared app state (build 48 — the Replay Tutorial card
    /// below reads `appState.tourAutoShow` and starts the tour via
    /// `appState.tour`, so replaying lands on Home first).
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

                // Build 74: the hub — one row per area, each
                // pushing its subpage. The section cards live on
                // the subpages now, not here.
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(SettingsSubpage.allCases.enumerated()), id: \.element) { index, page in
                            SettingsHubRow(page: page)
                            if index < SettingsSubpage.allCases.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .overlay(alignment: .top) { TopSafeAreaStrip() }
        .toastOverlay(toast) // Top popup toast (owner, Nov 20, 2026 — build 50).
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: SettingsSubpage.self) { page in
            settingsSubpage(page)
        }
    }

    @ViewBuilder
    private func settingsSubpage(_ page: SettingsSubpage) -> some View {
        switch page {
        case .profile:
            SettingsSubpageScaffold(title: page.title, toast: toast) {
                ProfileSettingsView(context: context, toast: toast, hideCardTitle: true)
            }
        case .household:
            SettingsSubpageScaffold(title: page.title, toast: toast) {
                MembersSettingsView(context: context, toast: toast, hideCardTitle: true)
            }
        case .connections:
            SettingsSubpageScaffold(title: page.title, toast: toast) {
                ConnectedAccountsView(context: context, toast: toast, plaidLauncher: plaidLauncher)
                EmailAlertsView(context: context, toast: toast)
            }
        case .notifications:
            SettingsSubpageScaffold(title: page.title, toast: toast) {
                NotificationsSettingsView(context: context, toast: toast, hideCardTitle: true)
            }
        case .app:
            SettingsSubpageScaffold(title: page.title, toast: toast) {
                ReplayTutorialSettingsCard(appState: appState, onBack: onBack)
                PrivacyTermsSettingsCard()
            }
        }
    }
}

/// One hub row: title + one plain subtitle line + chevron.
/// 48pt+ tap target, whole row tappable, squarish (no pill).
private struct SettingsHubRow: View {
    let page: SettingsSubpage

    var body: some View {
        NavigationLink(value: page) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignTokens.ink)
                    Text(page.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#6b7280"))
            }
            .padding(.vertical, 12)
            .frame(minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.\(page.accessibilityID)")
    }
}

/// One Settings subpage: the same header as every other pushed
/// subpage in the app (Past Weeks, Activity) — a top-left back
/// chevron + the page title, then the section card(s). Back pops
/// via the environment dismiss: the stack itself lives in the
/// shell's settingsCover, so there is no path binding here to pop.
/// The toast overlay + the opaque top strip ride along, so a
/// confirmation fired on a subpage still shows, and scrolled
/// content still passes behind the clock, exactly as on the hub.
private struct SettingsSubpageScaffold<Content: View>: View {
    let title: String
    let toast: ToastState
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    BackButton { dismiss() }
                    Spacer()
                }
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.ink)
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
            }
            .padding()
        }
        .overlay(alignment: .top) { TopSafeAreaStrip() }
        .toastOverlay(toast)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
    }
}

/// Build 69 (owner, Nov 24, 2026): the card headers scrolled under
/// the translucent status bar and read as overlapping the time
/// ("Email Alerts" / "Connected Email" at the top). An opaque strip
/// pinned to the top safe area keeps the time legible — scrolled
/// content passes behind it, never through the clock. It takes no
/// taps (status-bar area only). Shared by the hub and every subpage
/// scaffold.
private struct TopSafeAreaStrip: View {
    var body: some View {
        GeometryReader { proxy in
            DesignTokens.background
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(height: 0)
        .allowsHitTesting(false)
    }
}

/// Build 48 (owner, Nov 19, 2026): re-play the first-run
/// walkthrough from Settings ("Replay Tutorial" — renamed from
/// "Take the Tour" in build 54, the owner's words; "Take the Tour"
/// reads as first-time, "Replay Tutorial" reads as on-demand).
/// Auto-show is OFF (build 73, owner Nov 24, 2026 — "keep it off
/// for now"), so the tour shows only on demand from this row —
/// it starts again any time, from the beginning. Dismisses
/// Settings, lands on Home, and starts the tour after a short
/// delay so the cover is gone first. Replay works regardless of
/// the "Show on first open" toggle, and completing/skipping a
/// replay still marks the tour seen (existing `finish()`
/// behaviour). Build 54: the toggle to disable the auto-show
/// lives in this card. Build 64 (F-40): the Home Layout
/// (Simple / Classic) switch that used to sit above this card
/// is gone — Simple is the Home, no decision to make (the
/// per-device `homeLayout` default is `.simple`; the stored
/// value stays respected for anyone who had picked Classic,
/// they just cannot switch anymore).
private struct ReplayTutorialSettingsCard: View {
    @ObservedObject var appState: AppViewModel
    let onBack: () -> Void

    var body: some View {
        SettingsCard(title: "Replay Tutorial") {
            Text("A quick walk through the app — your spending number, charity, adding, transactions, and funds.")
                .font(.system(size: 15))
                .foregroundStyle(DesignTokens.muted)
            // Build 54 (owner, Nov 21, 2026): the auto-show
            // toggle — default ON (reversed Nov 26, 2026; build
            // 73 had turned it OFF, owner Nov 24, 2026: "keep it
            // off for now"), per device (UserDefaults,
            // `hb-tour-auto-show`, same per-device UserDefaults
            // pattern).
            // When OFF, the tour never auto-shows on first Home
            // entry; the button below still replays it on demand.
            Toggle("Show on first open", isOn: $appState.tourAutoShow)
                .font(.system(size: 15))
                .accessibilityIdentifier("settings.tourAutoShowToggle")
            Button("Replay Tutorial") {
                onBack()
                appState.selectedTab = .home
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    appState.tour.start()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("settings.replayTutorial")
        }
    }
}

/// Build 43 (owner, Nov 17, 2026 — item 13): Privacy · Terms on
/// their OWN card, below the last Settings card — not a bare link at
/// the bottom of the Account & Household card. Same destinations as
/// the auth footer and the old location.
private struct PrivacyTermsSettingsCard: View {
    var body: some View {
        // Build 69 (owner, Nov 24, 2026): "Privacy · Terms"
        // appeared twice — a heading AND the link row below it.
        // The card has no title now; the link row is the one entry.
        SettingsCard {
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
