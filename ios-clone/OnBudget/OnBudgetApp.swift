import SwiftUI
import WidgetKit
import OnBudgetKit

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
        // Build 65: the `UseFloatingTabBar` = false default is
        // GONE — it existed only to force a plain TabView's tabs
        // to the bottom tab bar on iPad (owner, Nov 11 2026: the
        // top segmented pill "throws me off"). Build 65 removes
        // the app's last TabView (AppShellView switches on
        // `selectedTab` and renders one PageSelectControl), so no
        // TabView reads this default any more and the bottom tab
        // bar itself is gone. History: build 64's
        // `.tabViewStyle(.tabBarOnly)` did not hold — the
        // duplicate page select was still seen on Home and Funds
        // — hence the removal rather than another TabView tweak.
        // Build 57 (owner, Nov 22, 2026 — no more guessed icons):
        // clear the retired guessed-icon data (remembered guesses
        // + cleared-guess list) left by builds 52–53, so a device
        // that remembered THE Timepiece's clock cannot resurface
        // it. Idempotent — safe on every launch.
        TransactionIconLookup.clearStaleGuessedIconData()
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
                    // Build 54: gated — reload only when the stored
                    // snapshot actually changed (launch always
                    // reloads once; see AppViewModel).
                    appState.reloadWidgetTimelinesIfSnapshotChanged()
                    WidgetBackgroundRefreshTask.schedule()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        appState.reloadWidgetTimelinesIfSnapshotChanged()
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
                    // - onbudget://widget-sync → the widget sync
                    //   fallback (build 54, owner Nov 21, 2026):
                    //   the widget button's primary path is the
                    //   in-place intent, but the owner's iPad tap
                    //   never reached it — opening the app through
                    //   this URL runs a snapshot refresh + timeline
                    //   reload, so the widget updates. Lands on
                    //   Home, like onbudget://home.
                    if url.host == "gmail-callback" {
                        Task { @MainActor in _ = appState.handleGmailDeepLink(url) }
                    } else if url.host == "home" {
                        appState.goHome()
                    } else if url.host == "widget-sync" {
                        appState.goHome()
                        Task {
                            _ = await WidgetSnapshotRefresher.refreshSnapshot()
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                    } else if url.host == "reset-password" {
                        Task { await appState.handleResetDeepLink(url) }
                    } else if url.host == "email-confirmed" {
                        Task { await appState.handleEmailConfirmationDeepLink(url) }
                    }
                }
        }
    }
}
