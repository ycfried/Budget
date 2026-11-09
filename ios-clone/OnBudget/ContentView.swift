import SwiftUI

/// App entry view. Switches the app shell (live.js:349-368):
/// loading / auth / household / app / session-expired. Home on
/// EVERY fresh load — boot always opens Home and never reads a
/// saved view. Clone basis: live web v66.
struct ContentView: View {
    @EnvironmentObject private var appState: AppViewModel

    var body: some View {
        Group {
            switch appState.phase {
            case .loading:
                LoadingView()
            case .auth:
                if appState.pendingResetCode != nil || appState.resetLinkError != nil {
                    ResetPasswordView()
                } else {
                    AuthView(appState: appState)
                }
            case .household:
                HouseholdView(appState: appState)
            case .app:
                AppShellView(appState: appState)
            case .sessionExpired:
                SessionExpiredView(appState: appState)
            }
        }
        .task {
            await appState.boot()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppViewModel())
}
