// OnBudgetKit — BiometricUnlock.swift
//
// Face ID unlock (native v1, owner-approved Nov 9, 2026): opt-in
// biometric unlock for returning users. Sign-in STAYS email +
// password (Supabase auth); this only lets a returning user skip
// typing the password after opting in. Default OFF, never
// auto-enabled, and the password is never stored anywhere.
//
// Flow:
//   Opt in (Settings → "Unlock with Face ID", only shown when
//     biometrics are enrolled): evaluate Face ID once to prove the
//     user can authenticate, then move the live session into the
//     biometric Keychain store (`BiometricSessionStore`,
//     `.biometryCurrentSet`) and clear the UserDefaults copy. From
//     then on every save — sign-in, token refresh, password change
//     — lands in the Keychain, because the client keeps that store
//     until the user opts out or signs out.
//   Unlock (next launch, auth screen): the auth screen offers
//     "Unlock with Face ID" only when a protected session exists
//     AND biometrics can evaluate. Tapping it evaluates Face ID,
//     reads the Keychain item with the just-evaluated LAContext (so
//     there is no second prompt), restores the session into the
//     client, and checks the token refreshes. On success the caller
//     boots into the app; on any failure the password screen stays.
//   Opt out (toggle off): swaps the client back to the UserDefaults
//     store and deletes the Keychain item. No biometric prompt is
//     needed to turn it off.
//   Fallbacks (never lock the user out; the password screen is
//     always the fallback — never the device passcode, so the
//     policy is `.deviceOwnerAuthenticationWithBiometrics`, not
//     `.deviceOwnerAuthentication`):
//     - user cancels the prompt → stay on the password screen.
//     - Face ID locked out (too many failures) → password screen.
//     - enrolment changed → the Keychain item is invalidated; the
//       unlock deletes it, swaps the client back to UserDefaults,
//       and shows the password screen. The user re-opts in after
//       signing in — it is never silently re-enabled.
//     - stored refresh refused → the session is dead; the item is
//       dropped and the password screen shows.
//     - biometrics removed / not enrolled any more → the stale item
//       is deleted, store swapped back, password screen.
//     - refresh fails for another reason (e.g. offline) → the item
//       is KEPT and the user can retry Face ID or use the password.
//
// UI-test safety: the unlock button only appears when a protected
// session exists AND the user opted in. The UI tests never opt in,
// and the simulator has no enrolled biometrics, so the Face ID
// prompt can never fire during those flows.
//
// Testability: `BiometricAuthenticator` (LAContext) and
// `BiometricKeychain` are protocols; the coordinator takes both as
// constructor arguments, so unit tests inject fakes and never need
// real biometrics or a Keychain.

import Foundation

// MARK: - Errors

/// Every way the Face ID flow can end, with the exact text the UI
/// shows. `userMessage` is written for the auth screen's inline
/// error box / Settings toast — never a raw OSStatus.
public enum BiometricUnlockError: Error, Equatable {
    /// The user cancelled the Face ID prompt. Silent: the UI stays
    /// on the password screen with no error.
    case cancelled
    /// Face ID did not recognise the user (or the context was
    /// invalid). Retryable from the same button.
    case failed
    /// Too many failed Face ID attempts; biometrics are locked until
    /// the device passcode unlocks them. The app never asks for the
    /// device passcode — the password screen is the fallback.
    case lockout
    /// The device has no biometric hardware.
    case notAvailable
    /// Biometrics are not set up on this device.
    case notEnrolled
    /// The biometric enrolment changed since opt-in, so the Keychain
    /// item was invalidated. The item is deleted; the user signs in
    /// with the password and re-opts in if they still want it.
    case biometricsChanged
    /// No protected session is stored (never opted in, or it was
    /// already deleted).
    case noStoredSession
    /// Tried to opt in with no signed-in session.
    case noSession
    /// The stored session's refresh was refused — the session is dead.
    case sessionExpired
    /// The stored session could not be refreshed for another reason
    /// (e.g. offline). The item is kept; retry or use the password.
    case refreshFailed(String)
    /// A Keychain operation failed for a reason above. Carries a
    /// human-readable detail (never a bare OSStatus).
    case keychainError(String)

    public var userMessage: String {
        switch self {
        case .cancelled:
            return "Face ID was cancelled. Sign in with your password."
        case .failed:
            return "Face ID did not recognise you. Try again, or sign in with your password."
        case .lockout:
            return "Face ID is locked after too many attempts. Sign in with your password."
        case .notAvailable:
            return "This device does not have Face ID."
        case .notEnrolled:
            return "Face ID is not set up on this device. Set it up in Settings, then turn on Face ID unlock here."
        case .biometricsChanged:
            return "Your Face ID enrolment changed, so the saved unlock was removed. Sign in with your password, then turn Face ID unlock back on in Settings."
        case .noStoredSession:
            return "No Face ID unlock is set up. Sign in with your password."
        case .noSession:
            return "Sign in first, then turn on Face ID unlock in Settings."
        case .sessionExpired:
            return "Your saved sign-in expired. Sign in with your password."
        case .refreshFailed(let message):
            return message
        case .keychainError(let message):
            return message
        }
    }
}

// MARK: - Biometry kind

public enum BiometryKind: Equatable {
    case faceID
    case touchID
    case none
}

// MARK: - Authenticator seam (LAContext)

/// The biometric prompt. The real implementation wraps LAContext
/// (Apple platforms only); tests inject a fake. `evaluate` must
/// throw `BiometricUnlockError` (mapped from LAError by the real
/// implementation) so the coordinator never sees platform types.
public protocol BiometricAuthenticator: AnyObject {
    var biometryKind: BiometryKind { get }
    var canEvaluate: Bool { get }
    func evaluate(reason: String) async throws
    /// The LAContext that just passed `evaluate`, for the Keychain
    /// read to reuse (`kSecUseAuthenticationContext`) so there is no
    /// second prompt. Nil on platforms without LocalAuthentication
    /// and on fakes that have no context to pass.
    var lastAuthenticatedContext: Any? { get }
}

#if canImport(LocalAuthentication)
import LocalAuthentication

/// LAContext wrapper. Policy is deliberately
/// `.deviceOwnerAuthenticationWithBiometrics` — biometrics only,
/// never the device passcode (the app password screen is the
/// fallback for every failure).
public final class LAContextAuthenticator: BiometricAuthenticator {
    private var context: LAContext?

    public init() {}

    public var biometryKind: BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
        else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    public var canEvaluate: Bool { biometryKind != .none }

    public func evaluate(reason: String) async throws {
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            self.context = context
        } catch let error as LAError {
            throw BiometricUnlockError.fromLAError(error)
        } catch {
            throw BiometricUnlockError.failed
        }
    }

    public var lastAuthenticatedContext: Any? { context }
}

extension BiometricUnlockError {
    /// LAError → coordinator error. Cancel variants stay silent
    /// (the UI shows no error for `.cancelled`).
    static func fromLAError(_ error: LAError) -> BiometricUnlockError {
        switch error.code {
        case .userCancel, .systemCancel, .appCancel:
            return .cancelled
        case .biometryLockout:
            return .lockout
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .authenticationFailed, .invalidContext:
            return .failed
        default:
            return .failed
        }
    }
}

#else

/// No LocalAuthentication (Linux CI): biometrics are unavailable.
public final class LAContextAuthenticator: BiometricAuthenticator {
    public init() {}
    public var biometryKind: BiometryKind { .none }
    public var canEvaluate: Bool { false }
    public func evaluate(reason: String) async throws {
        throw BiometricUnlockError.notAvailable
    }
    public var lastAuthenticatedContext: Any? { nil }
}

#endif

// MARK: - Coordinator

/// Owns the Face ID opt-in / unlock / opt-out state machine. Holds
/// no session itself — the session lives in the client's store (the
/// biometric Keychain store while enabled, the UserDefaults store
/// otherwise). Stateless apart from its injected keychain +
/// authenticator, so the app can hold one instance per screen and
/// the Keychain stays the source of truth.
public final class BiometricUnlock {
    public let keychain: BiometricKeychain
    public let authenticator: BiometricAuthenticator
    /// The biometric session store this coordinator migrates the
    /// client to on opt-in.
    public let store: BiometricSessionStore

    public init(
        keychain: BiometricKeychain = KeychainBiometricStore(),
        authenticator: BiometricAuthenticator = LAContextAuthenticator()
    ) {
        self.keychain = keychain
        self.authenticator = authenticator
        self.store = BiometricSessionStore(keychain: keychain)
    }

    /// True when a protected session is stored. Never prompts.
    public var isEnabled: Bool { keychain.exists() }

    public var biometryKind: BiometryKind { authenticator.biometryKind }

    public var canEvaluate: Bool { authenticator.canEvaluate }

    /// The label the UI shows ("Unlock with Face ID" /
    /// "Unlock with Touch ID"). `.none` falls back to Face ID
    /// wording; the button is hidden then anyway.
    public var label: String {
        biometryKind == .touchID ? "Unlock with Touch ID" : "Unlock with Face ID"
    }

    /// The store the app constructs its client with at launch: the
    /// biometric store when a protected session exists (its `load()`
    /// returns nil without prompting, so boot lands on the auth
    /// screen and offers Face ID), else the plain UserDefaults store.
    public static func sessionStoreForLaunch(
        keychain: BiometricKeychain = KeychainBiometricStore()
    ) -> SessionStore {
        keychain.exists()
            ? BiometricSessionStore(keychain: keychain)
            : UserDefaultsSessionStore()
    }

    // MARK: - Opt in / opt out

    /// Opt in: prove the user can authenticate with Face ID, then
    /// move the live session into the biometric Keychain store and
    /// clear the UserDefaults copy. Throws (and stores nothing)
    /// when there is no session, biometrics cannot evaluate, the
    /// user cancels, or the Keychain refuses the item.
    public func enable(client: SupabaseClient) async throws {
        guard let session = client.currentSession else {
            throw BiometricUnlockError.noSession
        }
        guard authenticator.canEvaluate else {
            throw BiometricUnlockError.notEnrolled
        }
        try await authenticator.evaluate(reason: "Turn on Face ID unlock for OnBudget.")
        try store.saveThrowing(session)
        client.replaceSessionStore(store)
    }

    /// Opt out: swap the client back to the UserDefaults store and
    /// delete the Keychain item. No biometric prompt — turning it
    /// off must never require proving a face. No-op when not
    /// enabled: swapping UserDefaults for a fresh UserDefaults
    /// store would clear the session key the new store just wrote.
    public func disable(client: SupabaseClient) {
        guard isEnabled else { return }
        client.replaceSessionStore(UserDefaultsSessionStore())
    }

    // MARK: - Unlock

    /// Unlock with Face ID: evaluate, read the protected session
    /// with the just-evaluated context, restore it into the client,
    /// and prove it still refreshes. Returns the restored session.
    /// Throws `BiometricUnlockError`; the caller shows the password
    /// screen for every failure (`.cancelled` stays silent).
    @discardableResult
    public func unlock(client: SupabaseClient) async throws -> AuthSession {
        guard isEnabled else {
            throw BiometricUnlockError.noStoredSession
        }
        guard authenticator.canEvaluate else {
            // Biometrics went away (removed / never enrolled now):
            // the stored item can never be read again. Drop it and
            // fall back to the password screen.
            dropStoredSession(client: client)
            throw BiometricUnlockError.notEnrolled
        }
        try await authenticator.evaluate(reason: "Unlock OnBudget with Face ID.")
        let session: AuthSession
        do {
            guard let loaded = try store.loadAuthenticated(
                authenticatedContext: authenticator.lastAuthenticatedContext)
            else {
                throw BiometricUnlockError.noStoredSession
            }
            session = loaded
        } catch {
            // The stored item is unusable (enrolment changed,
            // corrupt, or unreadable): drop it, fall back to the
            // password screen. The user re-opts in after signing in.
            dropStoredSession(client: client)
            throw error as? BiometricUnlockError ?? BiometricUnlockError.keychainError(
                "The saved Face ID session could not be read.")
        }
        client.restoreSession(session)
        do {
            _ = try await client.validAccessToken()
        } catch let error as OnBudgetError where error == .sessionExpired {
            // Refresh refused: the stored session is dead. The
            // client's own refresh path already cleared it; drop the
            // store back to UserDefaults so the password sign-in
            // does not silently re-create a protected item.
            dropStoredSession(client: client)
            throw BiometricUnlockError.sessionExpired
        } catch {
            // Refresh failed for another reason (e.g. offline): keep
            // the item and the restored in-memory session — the user
            // can retry Face ID or sign in with the password.
            throw BiometricUnlockError.refreshFailed(
                "Could not refresh your sign-in. Check your connection and try again, or sign in with your password.")
        }
        return session
    }

    /// Delete the protected item and swap the client back to the
    /// UserDefaults store. Used whenever the stored session proves
    /// unusable, so a dead item can never strand the user or
    /// silently re-enable itself on the next password sign-in. The
    /// swap runs only when the client is actually on the biometric
    /// store — swapping UserDefaults for a fresh UserDefaults store
    /// would clear the session key the new store just wrote.
    private func dropStoredSession(client: SupabaseClient) {
        keychain.delete()
        if client.store is BiometricSessionStore {
            client.replaceSessionStore(UserDefaultsSessionStore())
        }
    }
}
