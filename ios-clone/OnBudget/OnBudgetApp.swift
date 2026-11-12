import SwiftUI

/// OnBudget native iOS clone — app entry point.
/// Clone basis: live web v66 (branch ios-clone-v66). The app uses
/// the same live backend as the web app (same Supabase project,
/// Edge Functions, RPCs, auth). No mocks in shipped code, no
/// WKWebView wrapper.
@main
struct OnBudgetApp: App {
    @StateObject private var appState = AppViewModel()

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
                    if url.host == "gmail-callback" {
                        Task { @MainActor in _ = appState.handleGmailDeepLink(url) }
                    } else if url.host == "reset-password" {
                        Task { await appState.handleResetDeepLink(url) }
                    } else if url.host == "email-confirmed" {
                        Task { await appState.handleEmailConfirmationDeepLink(url) }
                    }
                }
        }
    }
}
