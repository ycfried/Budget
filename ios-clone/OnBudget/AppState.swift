// STAGE — AppState.swift
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
import WidgetKit
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
    /// Carried Debt (build 29) — a third fund card on the Funds page.
    case debt
    /// Spending (build 30) — the weekly budget fund, moved from
    /// Settings. Its card heads the Spending fund container.
    case spending
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
    /// Sign-up confirmation destination (owner, Nov 12, 2026):
    /// the confirmation email links here, so tapping it opens the
    /// app and confirms the address in place. Must be allow-listed
    /// in Supabase Auth → URL Configuration → Redirect URLs, next
    /// to `onbudget://reset-password`.
    public static let emailConfirmed = URL(string: "onbudget://email-confirmed")!
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
    /// The in-app walkthrough's live state (build 48, owner Nov 19,
    /// 2026): the first-run tour, ~11 steps, one element at a time.
    /// Owned here so Home, Transactions, Funds, the shell and
    /// Settings all read the same tour. The overlay lives on the
    /// shell; the trigger lives on Home; the replay row lives in
    /// Settings.
    @Published public var tour = TourState()
    /// Whether the walkthrough has been seen for this household
    /// on this device (build 50, Nov 20, 2026 — tutorial
    /// one-time fix): the STABLE per-household, per-device flag
    /// (`TourSeen`, OnBudgetKit), plus the legacy composite key
    /// for a flag written before build 50. The old `tourKey`
    /// folded in the session user UUID, which can be nil during a
    /// session-store swap — the flag was then read back under a
    /// different key and the tour showed on every open.
    public var tourSeen: Bool {
        tour.hasSeen(householdId: householdId, userId: client.currentSession?.user.id)
    }
    /// Mark the walkthrough seen for this household on this
    /// device (build 50): under the stable key AND the legacy
    /// composite key. Called on ANY dismissal — Skip, Done, or
    /// finishing the last step.
    public func markTourSeen() {
        tour.markSeen(householdId: householdId, userId: client.currentSession?.user.id)
    }

    /// The snapshot the app last reloaded widget timelines for
    /// (build 54 — reload gate): WidgetKit budgets reloads, so
    /// the app only reloads when the snapshot actually changed.
    /// In-memory only, per process; a fresh launch always reloads
    /// once (nil last snapshot). The widget extension's own reloads
    /// (sync tap, background refresh) are user- / schedule-
    /// initiated and are not gated here.
    private var lastWidgetReloadSnapshot: WidgetSnapshot?

    /// Reload widget timelines only when the stored snapshot
    /// actually changed since the last reload (build 54,
    /// WidgetReloadGate). Call this instead of
    /// WidgetCenter.shared.reloadAllTimelines() from launch,
    /// foreground, Home refresh and Funds rename paths — the
    /// launch + foreground pair used to fire back-to-back with the
    /// same snapshot, and foregrounding with no new data reloaded
    /// every time. A genuinely new snapshot (new numbers, or the
    /// same numbers freshly computed with a new "As of" time)
    /// still reloads; only a byte-identical snapshot is skipped.
    public func reloadWidgetTimelinesIfSnapshotChanged() {
        let current = WidgetSnapshotStore.read()
        guard WidgetReloadGate.shouldReload(current: current, lastReloaded: lastWidgetReloadSnapshot) else { return }
        lastWidgetReloadSnapshot = current
        WidgetCenter.shared.reloadAllTimelines()
    }
    /// Tab-reset suppression (owner, Nov 16, 2026 — build 40): a
    /// USER tab tap resets that tab to its top-level main page
    /// (Transactions pops its NavigationStack path, Funds collapses
    /// any expanded card), but a PROGRAMMATIC tab change — Home
    /// "See All", a recent-row jump, the Weekly sheet's "Show
    /// Transactions", Home's "Set Your Weekly Allowance" — must NOT
    /// reset, because it intentionally lands on a sub-view (the
    /// jump, the week filter, the expanded Spending card). Each
    /// programmatic setter sets this flag before changing
    /// `selectedTab`; the shell's onChange consumes it (clears it
    /// and skips the reset). It is set only by those setters and
    /// read only by the shell — never set by a user tap.
    public var suppressNextTabReset = false
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
    /// The household's custom fund names (build 37 — fund rename,
    /// owner Nov 16, 2026): `households.fund_names`, a map from fund
    /// key (spending / fund / charity / debt) to the custom name as
    /// typed. The ONE source every view reads from — Funds, Home,
    /// Transactions filters, buttons, widget — so a rename updates
    /// everywhere at once. Loaded at boot alongside the household
    /// name; [:] until then, and [:] when the migration is not
    /// applied yet (defaults shown). Updated in place by a rename.
    @Published public var fundNames: [String: String] = [:]

    /// The household's custom fund icons (build 41 — customizable
    /// fund icons, owner Nov 16, 2026): `households.fund_icons`, a
    /// map from fund key (spending / fund / charity / debt) to the
    /// SF Symbol name as picked. The ONE source every view reads
    /// from — Funds, Home — so an icon change updates everywhere
    /// at once. Loaded at boot alongside the fund names; [:] until
    /// then, and [:] when the migration is not applied yet
    /// (default icons shown). Updated in place by an icon change.
    /// (The widget renders no fund icons, so it reads no icons.)
    @Published public var fundIcons: [String: String] = [:]

    /// How each fund shows on the simpler Home (build 46 — owner
    /// Nov 18, 2026): `households.fund_prominence`, a map from fund
    /// key to "hero" / "card" / "quiet". The ONE source Home reads
    /// from, loaded at boot alongside the fund names and icons;
    /// [:] until then, and [:] when the migration is not applied
    /// yet (the mockup defaults show). Updated in place by a
    /// prominence change.
    @Published public var fundProminence: [String: String] = [:]

    /// Which funds are hidden from Home (build 47 — owner, Nov
    /// 19, 2026): `households.fund_hidden`, a map from fund key
    /// to true. Only Savings and Overspent (Past) can be hidden;
    /// Spending and Tzedaka are built in and always show. The ONE
    /// source Home reads from, loaded at boot alongside the fund
    /// prominence; [:] until then, and [:] when the migration is
    /// not applied yet (every fund shows). Updated in place by a
    /// hide/show change. Hiding never touches the fund's
    /// prominence, so showing it again puts it back where it was.
    @Published public var fundHidden: [String: Bool] = [:]

    /// Which Home layout shows (build 46 — owner Nov 18, 2026):
    /// the simpler mockup layout is the default; the previous
    /// layout stays available as `.classic` so it can be restored
    /// if the owner changes his mind. A per-device preference
    /// (UserDefaults, not household data — each member picks their
    /// own layout). The Settings screen offers the switch.
    public enum HomeLayout: String {
        case simple
        case classic
    }
    @Published public var homeLayout: HomeLayout = {
        let raw = UserDefaults.standard.string(forKey: "hb-home-layout") ?? ""
        return HomeLayout(rawValue: raw) ?? .simple
    }() {
        didSet {
            UserDefaults.standard.set(homeLayout.rawValue, forKey: "hb-home-layout")
        }
    }

    /// Whether the first-run walkthrough auto-shows on first
    /// entry to Home (build 54, owner Nov 21, 2026): a per-device
    /// preference (UserDefaults, not household data — each member
    /// picks on their own device), same pattern as `homeLayout`.
    /// Default ON. When OFF, `maybeStartTour` never auto-starts
    /// the tour; the "Replay Tutorial" row in Settings still
    /// starts it on demand. The Settings screen offers the toggle,
    /// inside the tour card.
    @Published public var tourAutoShow: Bool = {
        // UserDefaults bool(forKey:) returns false for a missing
        // key, so read the stored object and default to true
        // when absent — a fresh install auto-shows the tour.
        UserDefaults.standard.object(forKey: "hb-tour-auto-show") as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(tourAutoShow, forKey: "hb-tour-auto-show")
        }
    }

    /// The Home dashboard's view model, owned here (not by HomeView)
    /// so boot can preload it behind the loading screen (owner,
    /// Nov 15, 2026). Created once the household is known
    /// (`boot()` / `enterHousehold()`), cleared on sign-out.
    public var homeViewModel: HomeViewModel?

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

    /// Handoff from the Home Tzedaka sheet (build 65, owner Nov
    /// 23, 2026): open Transactions pre-filtered to the Tzedaka
    /// rows behind the sheet's numbers — gifts given plus income
    /// rows that accrued charity, all time. Cleared by the
    /// Transactions screen once consumed.
    @Published public var pendingTzedakaFilter = false

    /// Handoff from Home "See All" (audit H-P2-8): open Transactions
    /// with search/filters cleared first, like the recent-row jump.
    /// Cleared by the Transactions screen once consumed.
    @Published public var pendingClearTransactionFilters = false

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
        // previews) is used as-is. The store is MIRRORED to the App
        // Group (build 40, Nov 16, 2026 — widget sync): every
        // session save also writes to the shared container, so the
        // widget extension can read the session and fetch fresh
        // numbers on a sync tap. Reads still come from the real
        // store, so the app's auth behavior is unchanged.
        self.client = client ?? SupabaseClient(store: MirroredSessionStore(inner: BiometricUnlock.sessionStoreForLaunch()))
        self.biometricUnlock = biometricUnlock
        // Push notifications (Nov 16, 2026): the coordinator owns the
        // permission prompt, the token, and tap routing. The closures
        // capture self weakly; the coordinator is a singleton, so the
        // AppViewModel is never retained by it.
        PushNotificationCoordinator.shared.routeToScreen = { [weak self] screen, householdId in
            guard let self else { return }
            self.routeToNotificationScreen(screen, householdId: householdId)
        }
        PushNotificationCoordinator.shared.registerToken = { [weak self] hex, unregister in
            guard let self else { return }
            await self.registerPushToken(hex: hex, unregister: unregister)
        }
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
            fundNames = (try? await client.postgrest.householdFundNames(householdId: membership.householdId)) ?? [:]
            fundIcons = (try? await client.postgrest.householdFundIcons(householdId: membership.householdId)) ?? [:]
            fundProminence = (try? await client.postgrest.householdFundProminence(householdId: membership.householdId)) ?? [:]
            fundHidden = (try? await client.postgrest.householdFundHidden(householdId: membership.householdId)) ?? [:]
            ownerId = try? await client.postgrest.householdOwnerId(householdId: membership.householdId)
            // Preload the dashboard behind the loading screen
            // (owner, Nov 15, 2026): start the Home load now and
            // hold the branded loading screen until it is ready or
            // ~1.5s pass, whichever first, so Home arrives ready
            // instead of skeleton-filled. (Owner, Nov 15, 2026 —
            // build 34: the ~2s hold was "a bit too long", "the
            // tiniest amount shorter" — 1.5s. The preload keeps
            // running in the background if the timeout wins, so the
            // data still arrives after Home appears; the shimmer
            // skeletons stay as the fallback for anything still
            // loading. The loading screen itself still appears
            // immediately on launch — this only extends it.)
            let home = HomeViewModel(client: client, appState: self, householdId: membership.householdId)
            homeViewModel = home
            Task { await home.refresh() }
            // Plaid refresh on open (build 50, owner Nov 20, 2026):
            // the app also pulls fresh bank transactions when it
            // opens — throttled to once per 15 minutes, silent,
            // best-effort (see syncBankOnOpenIfDue). Fired here so
            // a fresh launch syncs even before Home appears; Home's
            // own .task and the foreground hook are the other two
            // triggers, and the throttle makes them cheap no-ops
            // when one already ran.
            Task { await home.syncBankOnOpenIfDue() }
            let preloadDeadline = Date().addingTimeInterval(1.5)
            while Date() < preloadDeadline {
                if home.isLoaded { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            phase = .app
            selectedTab = .home
            Task { await setupPushNotifications() }
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
        fundNames = (try? await client.postgrest.householdFundNames(householdId: id)) ?? [:]
        fundIcons = (try? await client.postgrest.householdFundIcons(householdId: id)) ?? [:]
        fundProminence = (try? await client.postgrest.householdFundProminence(householdId: id)) ?? [:]
        fundHidden = (try? await client.postgrest.householdFundHidden(householdId: id)) ?? [:]
        // A freshly created household is owned by its creator; a
        // freshly joined one learns its owner on the next boot.
        if role == .admin {
            ownerId = client.currentSession?.user.id
        }
        // Own the Home view model here too (same as boot's preload,
        // minus the loading-screen hold — the user is already past
        // it). HomeView reuses it instead of creating its own.
        let home = HomeViewModel(client: client, appState: self, householdId: id)
        homeViewModel = home
        Task { await home.refresh() }
        phase = .app
        selectedTab = .home
        Task { await setupPushNotifications() }
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
        // The widget must never show the previous user's numbers.
        WidgetSnapshotStore.delete()
        householdId = nil
        homeViewModel = nil
        role = nil
        ownerId = nil
        householdName = nil
        toast = nil
        bootError = nil
        authNotice = nil
        expandedCard = nil
        pendingTransactionJump = nil
        pendingWeekFilter = nil
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
            // Audit A-P2-2: the message names the device's actual
            // biometry kind, so Touch ID hardware never sees "Face ID".
            return .failed(error.userMessage(for: biometricUnlock.biometryKind))
        } catch {
            refreshBiometricUnlockAvailability()
            return .failed("\(biometricUnlock.biometryKind.displayName) did not work. Sign in with your password.")
        }
    }

    // MARK: - Navigation handoffs

    /// Settings (CLONE_SPEC §2.2): not a tab — opened from the
    /// profile menu as a full-screen cover over the current tab.
    /// The tab underneath is left alone so dismissing Settings
    /// returns to where the user was.
    public func openSettings() {
        showSettings = true
    }

    /// Open the Funds tab on the Spending fund (build 30): the
    /// Budget card moved out of Settings, so Home's "Set Your
    /// Weekly Allowance" (never-set state) lands here instead of
    /// on a Settings Budget card (owner decision #27, re-pointed).
    public func openSpendingFund() {
        openFund(.spending)
    }

    /// Open the Funds tab on a fund (build 46 — the simpler Home's
    /// cards and quiet rows navigate to their fund, like the
    /// Spending hero's "Set Your Weekly Allowance" lands on
    /// Spending): expands that fund's card and selects Funds.
    public func openFund(_ section: FundSectionID) {
        expandedCard = section.expandedCard
        suppressNextTabReset = true
        selectedTab = .funds
    }

    /// Dismiss Settings (full-screen cover, no tab bar): also
    /// clears any root toast so it cannot linger over the next
    /// screen (audit X-P2-13, Nov 12 2026). Sign-out clears the
    /// toast itself and never routes through here, so the
    /// account-deleted notice still survives sign-out.
    public func dismissSettings() {
        toast = nil
        showSettings = false
    }

    /// Widget entry (owner, Nov 16, 2026 — build 40): tapping the
    /// widget always opens the HOME main page — never a fund, a
    /// sub-view, or wherever the app was last left. This matches the
    /// Home-on-load rule (fresh launch opens Home). It clears any
    /// expanded fund card and selects Home; the shell's tab-change
    /// reset pops the Transactions path when the tab actually
    /// changes. NOT suppressed — a widget tap is a user navigation
    /// to the main page, not a programmatic landing on a sub-view.
    public func goHome() {
        expandedCard = nil
        selectedTab = .home
    }

    /// Recent-row tap (live.js:1040-1110): clear Transactions
    /// filters/search first (the Transactions screen does this when
    /// it consumes the jump), open Transactions, expand the row.
    public func jumpToTransaction(_ id: UUID) {
        pendingTransactionJump = id
        pendingWeekFilter = nil
        pendingTzedakaFilter = false
        suppressNextTabReset = true
        selectedTab = .transactions
    }

    /// Home "See All" (audit H-P2-8): clear Transactions
    /// filters/search first — same as the recent-row jump — then
    /// open Transactions. Without the clear, See All could land on
    /// a filtered list.
    public func showAllTransactions() {
        pendingClearTransactionFilters = true
        pendingWeekFilter = nil
        pendingTzedakaFilter = false
        pendingTransactionJump = nil
        suppressNextTabReset = true
        selectedTab = .transactions
    }

    // MARK: - Push notifications (Nov 16, 2026)

    /// Register (or unregister) the APNs device token with the
    /// server. Best-effort and silent: push is an addition to the
    /// app, never a blocker.
    private func registerPushToken(hex: String, unregister: Bool) async {
        guard let householdId else { return }
        do {
            try await client.functions.registerPushToken(
                householdId: householdId,
                deviceToken: hex,
                environment: PushNotificationCoordinator.shared.currentEnvironment,
                unregister: unregister
            )
        } catch {
            // Silent: push registration is best-effort.
        }
    }

    /// Unregister the device token (sign-out / account deletion).
    /// Called through SettingsContext.unregisterPushToken.
    public func unregisterPushToken() async {
        guard let hex = PushNotificationCoordinator.shared.lastDeviceTokenHex else { return }
        await registerPushToken(hex: hex, unregister: true)
    }

    /// Push setup, once the household is known and Home is showing:
    /// ask permission (once), re-register the token when already
    /// authorized, and consume a cold-start notification tap. Runs
    /// as a detached Task so boot returns immediately.
    private func setupPushNotifications() async {
        let coordinator = PushNotificationCoordinator.shared
        coordinator.isAppReady = true
        await coordinator.requestPermissionIfNeeded()
        await coordinator.reregisterIfAuthorized()
        if let pending = coordinator.pendingPayload {
            coordinator.pendingPayload = nil
            routeToNotificationScreen(pending.screen, householdId: pending.householdId)
        }
    }

    /// Route a notification tap. Drops the tap when not in the app,
    /// when no household is loaded, or when the payload's household
    /// is not the signed-in user's household. Tab taps land on main
    /// pages (the standing navigation rule); the Settings screen is
    /// the full-screen cover.
    public func routeToNotificationScreen(_ screen: NotificationScreen, householdId: UUID?) {
        guard phase == .app, let currentHouseholdId = householdId else { return }
        if let payloadHouseholdId = householdId, payloadHouseholdId != currentHouseholdId { return }
        switch screen {
        case .week, .statement:
            goHome()
        case .purchases:
            showAllTransactions()
        case .money:
            selectedTab = .funds
        case .settings:
            showSettings = true
        }
    }

    /// Weekly sheet "Show Transactions": Transactions filtered to the
    /// current week (live.js:3457-3500).
    public func showTransactionsForWeek(_ weekStart: String) {
        pendingWeekFilter = weekStart
        pendingTzedakaFilter = false
        pendingTransactionJump = nil
        suppressNextTabReset = true
        selectedTab = .transactions
    }

    /// Tzedaka sheet "Show Transactions" (build 65, owner Nov 23,
    /// 2026): Transactions pre-filtered to the Tzedaka rows behind
    /// the sheet's numbers — gifts given plus income rows that
    /// accrued charity, all time (not one week, not spending).
    public func showTzedakaTransactions() {
        pendingTzedakaFilter = true
        pendingWeekFilter = nil
        pendingTransactionJump = nil
        suppressNextTabReset = true
        selectedTab = .transactions
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
            let values = AuthLinkFragment.parse(fragment)
            if let access = values["access_token"], let refresh = values["refresh_token"] {
                do {
                    try await client.adoptSessionFromTokens(
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

    /// Handles `onbudget://email-confirmed#access_token=…&refresh_token=…&type=signup`
    /// — the sign-up confirmation link, when the app requested it
    /// with `redirect_to=onbudget://email-confirmed` (owner, Nov 12,
    /// 2026: confirmations turned back on). The verify itself already
    /// happened on Supabase's server when the link was fetched, so
    /// the email is confirmed even if this handler fails — the user
    /// can then just sign in. Success adopts the session and boots
    /// straight in; failure re-validates the stored session with
    /// `boot()` (audit A-P1-1) instead of forcing `.auth`, so a
    /// signed-in user who tapped a stale link stays in the app and
    /// only a truly dead session lands on Auth, with a plain message.
    public func handleEmailConfirmationDeepLink(_ url: URL) async {
        guard url.scheme == "onbudget", url.host == "email-confirmed" else { return }
        if let fragment = url.fragment {
            let values = AuthLinkFragment.parse(fragment)
            if let access = values["access_token"], let refresh = values["refresh_token"] {
                do {
                    try await client.adoptSessionFromTokens(
                        accessToken: access, refreshToken: refresh,
                        expiresIn: Double(values["expires_in"] ?? "") ?? 3600)
                    showToast("Email confirmed.", kind: .success)
                    await boot()
                    return
                } catch {
                    // Fall through to the plain message below — the
                    // email may already be confirmed, so the message
                    // says to just sign in.
                }
            }
        }
        authNotice = "This confirmation link could not be used. If your email is already confirmed, just sign in."
        // Audit A-P1-1: re-validate instead of forcing `.auth` — a
        // signed-in user who tapped a stale link goes back into the
        // app; only a dead/absent session lands on Auth.
        await boot()
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

    /// Informational messages default to `.info` (brand blue);
    /// success must be explicit (audit SH-P2-1, Nov 12 2026 — the
    /// old `.success` default turned plain information green).
    public func showToast(_ message: String, kind: ToastStyle.Kind = .info) {
        toast = Toast(message: message, kind: kind)
    }
}
