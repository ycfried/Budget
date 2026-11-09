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
                    // Password-reset deep link:
                    // onbudget://reset-password?code=…
                    Task { await appState.handleResetDeepLink(url) }
                }
        }
    }
}
