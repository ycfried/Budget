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
/// The Settings hub's subpages (Nov 26, 2026 — internal, not
/// private: the shell drives the cover's NavigationStack path to
/// `.connections` for the tour's Connect steps).
enum SettingsSubpage: Hashable, CaseIterable {
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
        // Build 111 (owner, Nov 27, 2026): the back row + title
        // are PINNED above the ScrollView now, not its first rows.
        // They used to scroll with the content — and the opaque
        // TopSafeAreaStrip overlay (which kept scrolled content
        // off the clock) painted above all scroll content, so a
        // scrolled page's back button slid behind the top bar,
        // invisible and unreachable; on the Household & Members
        // subpage the edge swipe was dead too, so there was no
        // way back at all. The header keeps the exact at-rest
        // spacing (16pt top pad, 20pt gaps); scrolled content
        // passes behind its opaque background instead of under
        // the strip, so the strip itself is gone. Same treatment
        // on every subpage scaffold below (build 74 already did
        // "ScrollViews under pinned headers" for the sheets).
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                }
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 20)
            .background(DesignTokens.background)
            ScrollView {
                // Build 74: the hub — one row per area, each
                // pushing its subpage. The section cards live on
                // the subpages now, not here. No top padding here:
                // the header's 20pt bottom pad is already the gap
                // below the title (a full .padding() would double
                // it to 36pt).
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
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
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
            SettingsSubpageScaffold(title: page.title, toast: toast, tour: appState.tour) {
                ProfileSettingsView(context: context, toast: toast, hideCardTitle: true)
            }
        case .household:
            SettingsSubpageScaffold(title: page.title, toast: toast, tour: appState.tour) {
                MembersSettingsView(context: context, toast: toast, hideCardTitle: true)
            }
        case .connections:
            SettingsSubpageScaffold(title: page.title, toast: toast, tour: appState.tour) {
                ConnectedAccountsView(context: context, toast: toast, plaidLauncher: plaidLauncher)
                    // Walkthrough anchor (Nov 26, 2026): the Bank
                    // Connection card — the tour's Connect step
                    // points here (Plaid). The scaffold carries
                    // the matching `.id`, so the step scrolls it
                    // into view when it sits below the fold.
                    .tourAnchor(.bankConnection, tour: appState.tour)
                    .id(TourAnchor.bankConnection)
                EmailAlertsView(context: context, toast: toast)
                    // Walkthrough anchor (Nov 26, 2026): the Email
                    // Alerts card — the optional second layer.
                    .tourAnchor(.emailAlerts, tour: appState.tour)
                    .id(TourAnchor.emailAlerts)
            }
        case .notifications:
            SettingsSubpageScaffold(title: page.title, toast: toast, tour: appState.tour) {
                NotificationsSettingsView(context: context, toast: toast, hideCardTitle: true)
            }
        case .app:
            SettingsSubpageScaffold(title: page.title, toast: toast, tour: appState.tour) {
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
/// The toast overlay rides along, so a confirmation fired on a
/// subpage still shows. The header is pinned above the ScrollView
/// (build 111): scrolled content passes behind its opaque
/// background, never through the clock, exactly as on the hub.
private struct SettingsSubpageScaffold<Content: View>: View {
    let title: String
    let toast: ToastState
    /// The walkthrough state (Nov 26, 2026 — the Connections
    /// steps): the scaffold observes it directly so the
    /// scroll-to onChange below fires on step change — the
    /// scaffold holds no @ObservedObject of its own otherwise.
    /// Every subpage passes `appState.tour`; the scroll-to
    /// guard only fires for the Settings steps.
    @ObservedObject var tour: TourState
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Build 111 (owner, Nov 27, 2026): the back row + title
        // are PINNED above the ScrollView — same fix as the hub
        // above. They used to be the ScrollView's first rows, so
        // the back button scrolled up behind the opaque
        // TopSafeAreaStrip overlay and could not be seen or
        // tapped; with the edge swipe also dead on this stack,
        // the Household & Members page had no way back at all.
        // The header keeps the exact at-rest spacing (16pt top
        // pad, 20pt gaps) and its opaque background is what
        // scrolled content passes behind now, so the strip is
        // gone. The tour's scroll-to still works: the
        // ScrollViewReader wraps the ScrollView below.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    BackButton { dismiss() }
                    Spacer()
                }
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 20)
            .background(DesignTokens.background)
            // Nov 26, 2026 (tour): the ScrollViewReader lets the
            // tour scroll its current target into view on step
            // change — the Connections cards can sit below the fold
            // on a small phone. The sheet-based helper gates on the
            // step belonging to Settings (the Settings steps have
            // no tab).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                    }
                    // No top padding: the header's 20pt bottom pad
                    // is already the gap below the title.
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .onChange(of: tour.stepIndex) { _, _ in
                    scrollTourSheetAnchorIntoView(proxy, tour: tour, sheet: .settings)
                }
            }
        }
        .toastOverlay(toast)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        // Build 111: explicit swipe-right-to-pop fallback — the
        // system pop gesture did nothing on this stack despite
        // `.enableSwipeBack()` above. Fires only when the system
        // gesture is disabled; never double-pops.
        .popSwipeBack()
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
