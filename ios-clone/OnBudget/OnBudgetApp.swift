import SwiftUI
import WidgetKit

/// OnBudget native iOS clone — app entry point.
/// Clone basis: live web v66 (branch ios-clone-v66). The app uses
/// the same live backend as the web app (same Supabase project,
/// Edge Functions, RPCs, auth). No mocks in shipped code, no
/// WKWebView wrapper.
@main
struct OnBudgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Bottom tab bar on iPad too (owner, Nov 11 2026): iPadOS 18+
        // renders a plain TabView's tabs as a segmented control at the
        // TOP in the regular size class — the "Home / Transactions /
        // Funds segmented pill" the owner circled on his iPad. On
        // iPhone (compact) the same code already renders the bottom
        // tab bar. This default restores the traditional bottom tab
        // bar (the Liquid Glass version on iPadOS 26); it is read by
        // the system when the tab bar is created, so it must be
        // registered here, before any UI loads. It is an undocumented
        // system default: if a future iPadOS removes it, the app falls
        // back to the top segmented control — navigation still works,
        // only the placement changes. Alternatives rejected: forcing
        // `.horizontalSizeClass` to `.compact` (public API, but it can
        // glitch the navigation hierarchy and shrinks the tab bar to a
        // small centred pill on iPadOS 26) and a hand-rolled tab bar
        // (loses the system tab bar's behaviour and the existing UI
        // tests' `tabBars` queries).
        UserDefaults.standard.register(defaults: ["UseFloatingTabBar": false])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                // Widget timelines (owner, Nov 15, 2026 — the XL
                // widget sat on its placeholder and never loaded):
                // Home refresh already reloads timelines after a
                // successful load, but a widget added while the app
                // was closed — or a Home refresh that failed — never
                // got that signal. Reload on launch and on every
                // foreground too, so a stuck widget gets a fresh
                // timeline the next time the app opens. WidgetKit
                // coalesces the calls; the snapshot itself is
                // untouched (a failed load writes nothing).
                // Build 43: schedule the background widget refresh
                // alongside, so a missed or failed schedule is
                // repaired every time the app opens.
                .task {
                    WidgetCenter.shared.reloadAllTimelines()
                    WidgetBackgroundRefreshTask.schedule()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        WidgetCenter.shared.reloadAllTimelines()
                        WidgetBackgroundRefreshTask.schedule()
                        // Plaid refresh on open (build 50, owner
                        // Nov 20, 2026): foregrounding the app also
                        // pulls fresh bank transactions — throttled
                        // to once per 15 minutes, silent,
                        // best-effort (see HomeViewModel
                        // syncBankOnOpenIfDue). The hourly cron
                        // stays as the backstop.
                        Task { await appState.homeViewModel?.syncBankOnOpenIfDue() }
                    }
                }
                .onOpenURL { url in
                    // Deep links on the `onbudget` scheme (registered
                    // in ios-clone/OnBudget/Info.plist):
                    // - onbudget://reset-password?code=… → recovery
                    // - onbudget://email-confirmed#access_token=… →
                    //   sign-up confirmation (adopts the session)
                    // - onbudget://gmail-callback?gmail=connected|failed
                    //   → recorded on AppViewModel. The live Gmail
                    //   connect needs no forwarding: the active
                    //   ASWebAuthenticationSession completes by itself.
                    // - onbudget://home → the widget (build 40, owner
                    //   Nov 16, 2026): tapping the widget always
                    //   opens the HOME main page.
                    if url.host == "gmail-callback" {
                        Task { @MainActor in _ = appState.handleGmailDeepLink(url) }
                    } else if url.host == "home" {
                        appState.goHome()
                    } else if url.host == "reset-password" {
                        Task { await appState.handleResetDeepLink(url) }
                    } else if url.host == "email-confirmed" {
                        Task { await appState.handleEmailConfirmationDeepLink(url) }
                    }
                }
        }
    }
}
