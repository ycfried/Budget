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
/// (CLONE_SPEC §2.2) — Settings is NOT a tab. It is presented as a
/// full-screen cover from the profile menu (`showSettings`).
public enum AppTab: String, CaseIterable {
    case home = "Home"
    case transactions = "Transactions"
    case funds = "Funds"
}

/// Which stat card is expanded. Home and Funds share one expanded
/// card at a time (live.js:3530-3600).
public enum ExpandedCard: Equatable {
    case charity
    case fund
}

/// The outcome of a Face ID unlock attempt from the auth screen.
public enum BiometricUnlockOutcome {
    /// Face ID passed and the stored session is live; the caller boots.
    case unlocked
    /// The user cancelled the Face ID prompt. Silent — stay on the
    /// password screen with no error.
    case cancelled
    /// Face ID failed; the message goes in the auth screen's inline
    /// error box. The password screen is always the fallback.
    case failed(String)
}

/// The password-reset deep link. The native app passes this URL as
/// `redirectTo` on the reset request (API_CLIENT.md ambiguity 5);
/// it must be allow-listed in Supabase Auth → URL Configuration →
/// Redirect URLs. The `onbudget` scheme is registered in the Xcode
/// target (INFOPLIST_KEY_CFBundleURLTypes, Debug + Release) so the
/// link can open the app; until the dashboard entry is added the
/// web reset.html flow remains the fallback.
public enum AppDeepLinks {
    public static let resetPassword = URL(string: "onbudget://reset-password")!
    /// The native Gmail OAuth return URL. The server redirects here
    /// for native flows only (gmail-oauth-start encodes the client
    /// in the OAuth state; see GmailCallback in OnBudgetKit). The
    /// same `onbudget` scheme registration covers both deep links.
    public static let gmailCallback = URL(string: "onbudget://gmail-callback")!
}

@MainActor
public final class AppViewModel: ObservableObject {

    public let client: SupabaseClient

    /// Face ID unlock (native v1, owner-approved): opt-in biometric
    /// unlock for returning users. The coordinator holds no session
    /// itself — the Keychain is the source of truth — so the
    /// Settings toggle and the auth screen can each hold their own
    /// instance, but the app state keeps one for the auth screen.
    public let biometricUnlock: BiometricUnlock

    /// True when the auth screen may offer "Unlock with Face ID":
    /// a protected session exists AND biometrics can evaluate.
    /// Refreshed whenever the app lands on the auth screen and
    /// after sign-out; never true during the UI tests (they never
    /// opt in, and the simulator has no enrolled biometrics).
    @Published public var biometricUnlockAvailable = false

    @Published public var phase: AppPhase = .loading
    @Published public var selectedTab: AppTab = .home
    /// Settings is not a tab (CLONE_SPEC §2.2): the profile menu
    /// opens it as a full-screen cover over the current tab.
    @Published public var showSettings = false
    @Published public var toast: Toast?

    /// The signed-in user's membership, once known.
    @Published public var householdId: UUID?
    @Published public var role: HouseholdRole?
    /// The household's owner id (`households.owner_id`, the creator).
    /// Loaded at boot alongside the household name; nil until then,
    /// and nil when the household has no owner recorded.
    @Published public var ownerId: UUID?
    @Published public var householdName: String?

    /// Boot failure state (audit F-P1-1, Nov 11, 2026): when the
    /// membership read fails, the Household screen shows this
    /// persistently with a Retry — never a vanishing toast, and the
    /// choice panel stays hidden until membership is known absent.
    @Published public var bootError: String?
    /// One-shot notice for the sign-in screen (audit F-P1-2): a
    /// token-refresh failure that is NOT a dead session (offline,
    /// timeout) lands on Auth with this plain line instead of
    /// misdiagnosing "sign-in expired". Cleared when shown.
    @Published public var authNotice: String?
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

    /// Handoff from Settings Budget → Temporary Allowance (spec
    /// §10.4): switch to the Funds tab and open the Temporary
    /// Allowance form there. Cleared by FundsView once consumed.
    @Published public var pendingTemporaryAllowance = false

    /// Deep-link password reset in progress (a recovery code arrived
    /// via onbudget://reset-password?code=…).
    @Published public var pendingResetCode: String?
    @Published public var resetLinkError: String?

    /// Last Gmail OAuth callback received at the app level
    /// (`onbudget://gmail-callback?gmail=connected|failed`). The
    /// live connect flow does NOT go through here — an active
    /// `ASWebAuthenticationSession` completes on its own once the
    /// scheme is registered, and `GmailOAuthPresenter` reports it.
    /// This records a callback that arrives outside an active
    /// session so it is visible instead of silently dropped.
    /// Persisted (see `lastGmailCallbackDefaultsKey`): a callback
    /// delivered to one launch is still visible after the next
    /// launch, and the CI script can assert it from the app
    /// container after the tests.
    @Published public var gmailCallbackResult: GmailCallbackResult?

    /// UserDefaults key for the last recorded Gmail callback
    /// ("connected" / "failed"). Read by the CI script from the
    /// app's Preferences plist.
    static let lastGmailCallbackDefaultsKey = "onbudget.lastGmailCallback"

    /// Week-close runs once per session, admin only (live.js:724).
    private var weekCloseAttempted = false

    public init(
        client: SupabaseClient? = nil,
        biometricUnlock: BiometricUnlock = BiometricUnlock()
    ) {
        // The launch store is biometric when a protected session
        // exists (its load() returns nil without prompting, so boot
        // lands on the auth screen and offers Face ID), else the
        // plain UserDefaults store. An explicit client (tests,
        // previews) is used as-is.
        self.client = client ?? SupabaseClient(store: BiometricUnlock.sessionStoreForLaunch())
        self.biometricUnlock = biometricUnlock
        // A Gmail callback recorded by an earlier launch (e.g. the
        // CI script's simctl openurl, delivered to the previous app
        // instance) is still the last one received: restore it so
        // Settings → Email Alerts can show it.
        switch UserDefaults.standard.string(forKey: Self.lastGmailCallbackDefaultsKey) {
        case "connected": gmailCallbackResult = .connected
        case "failed": gmailCallbackResult = .failed
        default: break
        }
    }

    public var isAdmin: Bool { role == .admin }
    /// Owner = the household creator. The owner keeps role `.admin`
    /// (so every admin check keeps passing for the owner), and is
    /// identified by `ownerId` matching the signed-in user.
    public var isOwner: Bool {
        guard let ownerId, let userId = client.currentSession?.user.id else { return false }
        return ownerId == userId
    }

    /// The signed-in user's display name from auth metadata
    /// (`full_name`, then `name`) — nil when no name is set. NEVER
    /// the email: the web never uses the full email as a display name
    /// (live.js:490-505: stored member name → own metadata name →
    /// email prefix → "Household member"; the Profile name field is
    /// the metadata name or blank, live.js:548-552). The old fallback
    /// to the email put "ycfried1@gmail.com" in the Profile Name field
    /// and on the owner's own Members row (phone feedback, Nov 11,
    /// 2026) instead of the email-prefix fallback. Callers that need a
    /// non-empty label use the member-list resolution (which falls
    /// back to the prefix) or "Household member".
    public var displayName: String? {
        client.currentSession?.user.displayName
    }

    // MARK: - Boot

    /// Boot (live.js:2339-2395). Always lands on Home.
    public func boot() async {
        phase = .loading
        bootError = nil
        selectedTab = .home
        showSettings = false
        guard let session = client.currentSession else {
            phase = .auth
            refreshBiometricUnlockAvailability()
            return
        }
        do {
            // Refresh a stale token before reading membership. Only
            // a dead session is "sign-in expired" (audit F-P1-2):
            // offline / timeout / transport failures land on Auth
            // with a plain offline notice — a password cannot fix
            // them, and the user must not be told their sign-in died.
            _ = try await client.validAccessToken()
        } catch let error as OnBudgetError where error == .sessionExpired {
            phase = .sessionExpired
            return
        } catch let error as OnBudgetError {
            switch error {
            case .networkOffline, .timedOut, .networkError:
                authNotice = "You're offline. Check your connection and try again."
                phase = .auth
            default:
                phase = .sessionExpired
            }
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
            ownerId = try? await client.postgrest.householdOwnerId(householdId: membership.householdId)
            phase = .app
            selectedTab = .home
        } catch let error as OnBudgetError where error == .sessionExpired {
            phase = .sessionExpired
        } catch {
            // A membership read error is persistent, never silent and
            // never a vanishing toast (audit F-P1-1, live.js:371-389):
            // the Household screen shows this with a Retry, and the
            // choice panel stays hidden until membership is known
            // absent — the user may already belong to a household
            // whose read just failed. Raw server text never shows.
            bootError = "Could not load your household. Try again."
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
        // A freshly created household is owned by its creator; a
        // freshly joined one learns its owner on the next boot.
        if role == .admin {
            ownerId = client.currentSession?.user.id
        }
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
        ownerId = nil
        householdName = nil
        toast = nil
        bootError = nil
        authNotice = nil
        expandedCard = nil
        pendingTransactionJump = nil
        pendingWeekFilter = nil
        pendingTemporaryAllowance = false
        showSettings = false
        weekCloseAttempted = false
        selectedTab = .home
        phase = .auth
        refreshBiometricUnlockAvailability()
    }

    /// Any screen that catches `.sessionExpired` routes here.
    public func showSessionExpired() {
        phase = .sessionExpired
    }

    public func signInAgain() {
        phase = .auth
        refreshBiometricUnlockAvailability()
    }

    // MARK: - Face ID unlock

    /// Recompute whether the auth screen may offer Face ID unlock.
    /// Cheap and non-prompting (a Keychain existence check plus
    /// `canEvaluatePolicy`); call it whenever the auth screen may
    /// appear, never in a loop.
    public func refreshBiometricUnlockAvailability() {
        biometricUnlockAvailable = biometricUnlock.isEnabled && biometricUnlock.canEvaluate
    }

    /// Run the Face ID unlock from the auth screen. `.unlocked`
    /// means the stored session is live and the caller should boot;
    /// `.cancelled` stays silent; `.failed` carries the message for
    /// the auth screen's inline error box. The Face ID prompt only
    /// ever fires from this call — including the auth screen's
    /// once-per-appearance auto-prompt for opted-in returning users
    /// (owner, Nov 11, 2026) — never at boot, so the UI tests (which
    /// never opt in) can never see it.
    public func unlockWithBiometrics() async -> BiometricUnlockOutcome {
        do {
            _ = try await biometricUnlock.unlock(client: client)
            refreshBiometricUnlockAvailability()
            return .unlocked
        } catch let error as BiometricUnlockError {
            refreshBiometricUnlockAvailability()
            if error == .cancelled { return .cancelled }
            return .failed(error.userMessage)
        } catch {
            refreshBiometricUnlockAvailability()
            return .failed("Face ID did not work. Sign in with your password.")
        }
    }

    // MARK: - Navigation handoffs

    /// Settings (CLONE_SPEC §2.2): not a tab — opened from the
    /// profile menu (or a Home link) as a full-screen cover over
    /// the current tab. The tab underneath is left alone so
    /// dismissing Settings returns to where the user was.
    public func openSettings() {
        showSettings = true
    }

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

    /// Settings Budget "Open Temporary Allowance" (spec §10.4): the
    /// box itself lives on Funds — switch there and let FundsView
    /// open its Temporary Allowance form. Dismissing Settings first
    /// (the link lives inside the Settings cover) so the Funds tab
    /// is visible when the form opens.
    public func openTemporaryAllowance() {
        showSettings = false
        pendingTemporaryAllowance = true
        selectedTab = .funds
    }

    // MARK: - Deep links

    /// Handles onbudget://gmail-callback?gmail=connected|failed.
    /// Returns true when the URL was a Gmail callback (and records
    /// the outcome in `gmailCallbackResult`). No forwarding to
    /// `GmailOAuthPresenter` is needed or correct: the presenter
    /// owns the active `ASWebAuthenticationSession`, which completes
    /// by itself once the `onbudget` scheme is registered.
    public func handleGmailDeepLink(_ url: URL) -> Bool {
        guard let result = OnBudgetKit.GmailCallback.result(from: url) else { return false }
        gmailCallbackResult = result
        // Persist the record: the UI-test delivery happens in one
        // app instance and the CI script asserts it from the app
        // container after the tests, in a later instance.
        UserDefaults.standard.set(
            result == .connected ? "connected" : "failed",
            forKey: Self.lastGmailCallbackDefaultsKey
        )
        return true
    }

    /// Handles onbudget://reset-password?code=… (and the hash-style
    /// #access_token=… form). A bad code shows the reset page's exact
    /// message; the reset screen itself is ResetPasswordView.
    public func handleResetDeepLink(_ url: URL) async {
        guard url.scheme == "onbudget", url.host == "reset-password" else { return }
        if let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value {
            pendingResetCode = code
            resetLinkError = nil
            // Route to the reset screen: it only renders inside the
            // .auth branch, so without this the link is silently
            // swallowed when the user is already signed in (audit
            // F-P1-3). The recovery session replaces the current
            // session on exchange, so dropping the shell is coherent.
            phase = .auth
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
                phase = .auth
                return
            }
        }
        resetLinkError = "This reset link could not be used. Request a new one from the sign-in screen."
        phase = .auth
    }

    /// Exchange a PKCE recovery code for a session, then hand the
    /// ResetPasswordView a live recovery session.
    public func exchangeResetCode() async -> Bool {
        guard let code = pendingResetCode, code != "fragment" else { return pendingResetCode == "fragment" }
        do {
            _ = try await client.exchangeRecoveryCode(code)
            // PKCE codes are single-use: clear immediately so a
            // re-appearing view cannot re-exchange and overwrite the
            // form with an error (audit F-P2-3).
            pendingResetCode = nil
            return true
        } catch {
            resetLinkError = "This reset link could not be used. Request a new one from the sign-in screen."
            pendingResetCode = nil
            return false
        }
    }

    /// Clears the Gmail callback record (audit F-P1-7): the
    /// "Gmail return: Connected/Failed" line in Settings is a
    /// one-time delivery notice, not lasting state — it is cleared
    /// when the Email Alerts screen is left, after the live
    /// connection status has been re-read.
    public func clearGmailCallbackResult() {
        gmailCallbackResult = nil
        UserDefaults.standard.removeObject(forKey: Self.lastGmailCallbackDefaultsKey)
    }

    // MARK: - Toasts

    public func showToast(_ message: String, kind: ToastStyle.Kind = .success) {
        toast = Toast(message: message, kind: kind)
    }
}
