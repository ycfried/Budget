// OnBudget — AppState.swift
//
// App shell state: boot flow, session, household membership, tab
// selection, toasts, and the handoffs between screens (recent-row
// jump, weekly-sheet week filter, password-reset deep link).
//
// Boot flow (live.js:2339-2395): getSession → no session shows Auth;
// loadMembership → no membership shows Household; otherwise stay on
// the full-screen loading view while the first refresh runs, then
// show the app. Home on EVERY fresh load (live.js:3042-3049) — the
// saved view is never read on boot. A refresh never scrolls; a tab
// tap scrolls to top.
//
// Clone basis: live web v66. API calls are OnBudgetKit only.

import SwiftUI
import OnBudgetKit

/// The app shell: loading / auth / household / app (live.js:349-368).
public enum AppPhase: Equatable {
    case loading
    case auth
    case household
    case app
    /// "Your sign-in expired" + Sign In Again (live.js tx-list auth
    /// failure; OnBudgetError.sessionExpired).
    case sessionExpired
}

/// Tabs. The web has 3 tabs + Settings via the profile menu
/// (CLONE_SPEC §2.2); the task brief for this build specifies a
/// 4-tab bar — Home, Transactions, Funds, Settings — so Settings is
/// a tab here as well as a profile-menu destination.
public enum AppTab: String, CaseIterable {
    case home = "Home"
    case transactions = "Transactions"
    case funds = "Funds"
    case settings = "Settings"
}

/// Which stat card is expanded. Home and Funds share one expanded
/// card at a time (live.js:3530-3600).
public enum ExpandedCard: Equatable {
    case charity
    case fund
}

/// The password-reset deep link. The native app passes this URL as
/// `redirectTo` on the reset request (API_CLIENT.md ambiguity 5);
/// it must be allow-listed in Supabase Auth → URL Configuration →
/// Redirect URLs, and the `onbudget` scheme registered in the Xcode
/// target (URL Types) before the link can open the app. Until then
/// the web reset.html flow remains the fallback.
public enum AppDeepLinks {
    public static let resetPassword = URL(string: "onbudget://reset-password")!
}

@MainActor
public final class AppViewModel: ObservableObject {

    public let client: SupabaseClient

    @Published public var phase: AppPhase = .loading
    @Published public var selectedTab: AppTab = .home
    @Published public var toast: Toast?

    /// The signed-in user's membership, once known.
    @Published public var householdId: UUID?
    @Published public var role: HouseholdRole?
    @Published public var householdName: String?

    /// One-open-at-a-time stat-card expansion, shared by Home and
    /// Funds (live.js:3530-3600).
    @Published public var expandedCard: ExpandedCard?

    /// Handoff to the Transactions screen (owned by another builder):
    /// a recent-row tap jumps there with this transaction expanded.
    /// Cleared by the Transactions screen once consumed.
    @Published public var pendingTransactionJump: UUID?

    /// Handoff from the Weekly sheet: open Transactions filtered to
    /// the current week (live.js:3457-3500). Cleared by the
    /// Transactions screen once consumed.
    @Published public var pendingWeekFilter: String?

    /// Deep-link password reset in progress (a recovery code arrived
    /// via onbudget://reset-password?code=…).
    @Published public var pendingResetCode: String?
    @Published public var resetLinkError: String?

    /// Week-close runs once per session, admin only (live.js:724).
    private var weekCloseAttempted = false

    public init(client: SupabaseClient = SupabaseClient()) {
        self.client = client
    }

    public var isAdmin: Bool { role == .admin }

    public var displayName: String {
        client.currentSession?.user.displayName
            ?? client.currentSession?.user.email
            ?? "Household member"
    }

    // MARK: - Boot

    /// Boot (live.js:2339-2395). Always lands on Home.
    public func boot() async {
        phase = .loading
        selectedTab = .home
        guard let session = client.currentSession else {
            phase = .auth
            return
        }
        do {
            // Refresh a stale token before reading membership; a
            // refused refresh funnels to the expired state.
            _ = try await client.validAccessToken()
        } catch let error as OnBudgetError where error == .sessionExpired {
            phase = .sessionExpired
            return
        } catch {
            phase = .sessionExpired
            return
        }
        do {
            let membership = try await client.postgrest.loadMembership(userId: session.user.id)
            guard let membership else {
                phase = .household
                return
            }
            householdId = membership.householdId
            role = membership.role
            householdName = try? await client.postgrest.householdName(householdId: membership.householdId)
            phase = .app
            selectedTab = .home
        } catch let error as OnBudgetError where error == .sessionExpired {
            phase = .sessionExpired
        } catch {
            // A membership read error is surfaced, never silent
            // (live.js:371-389): show the household screen with the
            // error as a toast rather than stranding on loading.
            toast = Toast(message: (error as? OnBudgetError)?.userMessage
                          ?? "Could not load your household. Try again.", kind: .error)
            phase = .household
        }
    }

    /// After create/join household: set membership directly from the
    /// RPC result (the web does NOT re-read membership here — the
    /// Nov 1 bug was re-reading too early and stranding the user).
    public func enterHousehold(id: UUID, role: HouseholdRole) async {
        householdId = id
        self.role = role
        householdName = try? await client.postgrest.householdName(householdId: id)
        phase = .app
        selectedTab = .home
    }

    /// Week-close: admin only, once per session (live.js:724). A
    /// no-op close (weeks_closed 0) changes nothing; a real close
    /// returns true so the caller reloads week figures. Failures are
    /// silent here — the next boot retries — and never block Home.
    public func runWeekCloseIfDue() async -> Bool {
        guard isAdmin, let householdId, !weekCloseAttempted else { return false }
        weekCloseAttempted = true
        do {
            let result = try await client.functions.weekClose(householdId: householdId)
            return result.weeksClosed > 0
        } catch {
            return false
        }
    }

    // MARK: - Sign out / session expiry

    /// Sign-out (live.js:2601-2615): clears the session even if the
    /// network call fails, clears the auth fields' owner state, and
    /// lands on the sign-in panel (never stranded on the name step).
    public func signOut() async {
        await client.signOut()
        householdId = nil
        role = nil
        householdName = nil
        expandedCard = nil
        pendingTransactionJump = nil
        pendingWeekFilter = nil
        weekCloseAttempted = false
        selectedTab = .home
        phase = .auth
    }

    /// Any screen that catches `.sessionExpired` routes here.
    public func showSessionExpired() {
        phase = .sessionExpired
    }

    public func signInAgain() {
        phase = .auth
    }

    // MARK: - Navigation handoffs

    /// Recent-row tap (live.js:1040-1110): clear Transactions
    /// filters/search first (the Transactions screen does this when
    /// it consumes the jump), open Transactions, expand the row.
    public func jumpToTransaction(_ id: UUID) {
        pendingTransactionJump = id
        pendingWeekFilter = nil
        selectedTab = .transactions
    }

    /// Weekly sheet "Show Transactions": Transactions filtered to the
    /// current week (live.js:3457-3500).
    public func showTransactionsForWeek(_ weekStart: String) {
        pendingWeekFilter = weekStart
        pendingTransactionJump = nil
        selectedTab = .transactions
    }

    // MARK: - Password-reset deep link

    /// Handles onbudget://reset-password?code=… (and the hash-style
    /// #access_token=… form). A bad code shows the reset page's exact
    /// message; the reset screen itself is ResetPasswordView.
    public func handleResetDeepLink(_ url: URL) async {
        guard url.scheme == "onbudget", url.host == "reset-password" else { return }
        if let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value {
            pendingResetCode = code
            resetLinkError = nil
            return
        }
        // Hash-style recovery link: #access_token=…&refresh_token=…
        if let fragment = url.fragment {
            var values: [String: String] = [:]
            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
            }
            if let access = values["access_token"], let refresh = values["refresh_token"] {
                do {
                    try await client.adoptRecoverySession(
                        accessToken: access, refreshToken: refresh,
                        expiresIn: Double(values["expires_in"] ?? "") ?? 3600)
                    pendingResetCode = "fragment"
                    resetLinkError = nil
                } catch {
                    resetLinkError = "This reset link could not be used. Request a new one from the sign-in screen."
                }
                return
            }
        }
        resetLinkError = "This reset link could not be used. Request a new one from the sign-in screen."
    }

    /// Exchange a PKCE recovery code for a session, then hand the
    /// ResetPasswordView a live recovery session.
    public func exchangeResetCode() async -> Bool {
        guard let code = pendingResetCode, code != "fragment" else { return pendingResetCode == "fragment" }
        do {
            _ = try await client.exchangeRecoveryCode(code)
            return true
        } catch {
            resetLinkError = "This reset link could not be used. Request a new one from the sign-in screen."
            pendingResetCode = nil
            return false
        }
    }

    // MARK: - Toasts

    public func showToast(_ message: String, kind: ToastStyle.Kind = .success) {
        toast = Toast(message: message, kind: kind)
    }
}
