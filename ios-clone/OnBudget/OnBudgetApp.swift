import SwiftUI

/// OnBudget native iOS clone — app entry point.
/// Clone basis: live web v66 (branch ios-clone-v66). The app uses
/// the same live backend as the web app (same Supabase project,
/// Edge Functions, RPCs, auth). No mocks in shipped code, no
/// WKWebView wrapper.
@main
struct OnBudgetApp: App {
    @StateObject private var appState = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    // Deep links on the `onbudget` scheme (registered
                    // in ios-clone/OnBudget/Info.plist):
                    // - onbudget://reset-password?code=… → recovery
                    // - onbudget://gmail-callback?gmail=connected|failed
                    //   → recorded on AppViewModel. The live Gmail
                    //   connect needs no forwarding: the active
                    //   ASWebAuthenticationSession completes by itself.
                    if url.host == "gmail-callback" {
                        Task { @MainActor in _ = appState.handleGmailDeepLink(url) }
                    } else if url.host == "reset-password" {
                        Task { await appState.handleResetDeepLink(url) }
                    }
                }
        }
    }
}
