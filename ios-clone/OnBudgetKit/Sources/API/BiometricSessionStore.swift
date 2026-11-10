// OnBudgetKit — BiometricSessionStore.swift
//
// Face ID unlock (native v1, owner-approved Nov 9, 2026): the
// biometric-protected copy of the Supabase session.
//
// Why a second store exists at all: the shipped default session
// store (`UserDefaultsSessionStore`, SupabaseClient.swift) keeps the
// session JSON in UserDefaults in plaintext. A Face ID gate is
// meaningless on top of that — `boot()` would read the plaintext
// session and walk straight into Home without asking for a face.
// So opting in MOVES the session: the client swaps its store to this
// one (see `SupabaseClient.replaceSessionStore`), the old
// UserDefaults copy is cleared, and every later save (sign-in,
// token refresh, password change) lands in the Keychain instead.
// Opting out swaps back and deletes the Keychain item. Sign-out and
// a refused refresh clear the session through the same `setSession`
// path, so the Keychain item is deleted by those flows too — no
// separate cleanup call is needed anywhere.
//
// The item is a single generic-password entry (one signed-in account
// per device — there is no account switch without sign-out first):
//   service "com.onbudget.app.biometric-session", account
//   "supabase-session", payload = the `AuthSession` JSON (access +
//   refresh tokens, never the password).
// Access control is `.biometryCurrentSet` on
// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: reading requires a
// biometric match, and adding/removing an enrolled face or finger
// invalidates the item, so a changed enrolment can never unlock an
// old session. The item is NOT synchronizable — it never leaves
// this device (no `kSecAttrSynchronizable`).
//
// Platform split: the `BiometricKeychain` protocol is the seam.
// `KeychainBiometricStore` is the real SecItem implementation
// (Apple platforms only); on Linux (the package also compiles
// there) it is a stub that reports nothing stored, so the feature
// is simply unavailable and every test below still compiles. The
// coordinator logic in BiometricUnlock.swift is platform-neutral
// and is tested against mocks of this protocol — no real biometrics
// or Keychain is ever needed in tests.
//
// Keychain behaviour the code relies on (Apple docs, SecItem):
//   - Writing an item with an access control does NOT prompt.
//   - Deleting an item does NOT require authentication.
//   - Reading with `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`
//     never prompts: `errSecInteractionNotAllowed` means "an item
//     exists but needs authentication", which is exactly how
//     `exists()` proves an item is there without showing Face ID.
//   - Reading with a just-evaluated `LAContext` passed as
//     `kSecUseAuthenticationContext` reuses that authentication and
//     does NOT prompt a second time.
//   - `errSecAuthFailed` on a `.biometryCurrentSet` read means the
//     enrolment changed since the item was written.

import Foundation

// MARK: - Keychain seam

/// Raw Keychain access for the biometric session item. Data-level
/// only — the store above owns the `AuthSession` encoding. The
/// `authenticatedContext` of `load` is the `LAContext` that just
/// passed `evaluatePolicy` (as `Any?`, so this protocol stays
/// compilable where LocalAuthentication does not exist); nil means
/// "do not prompt, return nil when authentication would be needed".
public protocol BiometricKeychain: AnyObject {
    /// True when a protected item exists. Never prompts: an item
    /// that needs authentication still counts as existing (its
    /// status is `errSecInteractionNotAllowed`), and an invalidated
    /// item counts too (`errSecAuthFailed`) so the unlock flow can
    /// run, detect the invalidation, and clean it up.
    func exists() -> Bool
    /// The stored bytes, or nil when there is no item / the item
    /// cannot be read without prompting. Throws
    /// `.biometricsChanged` when the enrolment changed since the
    /// item was written, `.keychainError` for anything else.
    func load(authenticatedContext: Any?) throws -> Data?
    /// Write (or delete, when `data` is nil). Throws
    /// `.biometricsChanged` / `.keychainError` on failure.
    func save(_ data: Data?) throws
    /// Delete the item, if any. Never throws and never prompts.
    func delete()
}

// MARK: - Live Keychain implementation (Apple platforms)

#if canImport(Security)
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The real SecItem store. Stateless apart from its service /
/// account names, so any number of instances share one item.
public final class KeychainBiometricStore: BiometricKeychain {
    public let service: String
    public let account: String

    public init(
        service: String = "com.onbudget.app.biometric-session",
        account: String = "supabase-session"
    ) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func exists() -> Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecSuccess: readable (should not happen for a protected
        // item, but counts). errSecInteractionNotAllowed: an item
        // exists and needs authentication. errSecAuthFailed: an
        // item exists but its enrolment changed. Anything else
        // (notably errSecItemNotFound) means no item.
        return status == errSecSuccess
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
    }

    public func load(authenticatedContext: Any?) throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #if canImport(LocalAuthentication)
        if let context = authenticatedContext as? LAContext {
            // Reuse the just-evaluated context: no second prompt.
            query[kSecUseAuthenticationContext as String] = context
        } else {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        #else
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            // No authenticated context was supplied (or it was not
            // accepted): the item exists but cannot be read without
            // prompting. The non-prompting caller treats this as
            // "no readable session"; the unlock flow never hits it,
            // because it always supplies a context.
            if authenticatedContext == nil { return nil }
            throw BiometricUnlockError.keychainError(
                "Face ID approved the unlock but the saved session could not be read.")
        case errSecAuthFailed:
            throw BiometricUnlockError.biometricsChanged
        default:
            throw BiometricUnlockError.keychainError(
                "Could not read the saved Face ID session (\(status)).")
        }
    }

    public func save(_ data: Data?) throws {
        // Delete-then-add: updating in place would keep a stale
        // access control after an enrolment change, and deleting
        // needs no authentication.
        delete()
        guard let data else { return }
        let accessControl = try makeAccessControl()
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = accessControl
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed { throw BiometricUnlockError.biometricsChanged }
            throw BiometricUnlockError.keychainError(
                "Could not save the Face ID session (\(status)).")
        }
    }

    public func delete() {
        _ = SecItemDelete(baseQuery() as CFDictionary)
    }

    /// `.biometryCurrentSet`: a biometric match is required to read,
    /// and any enrolment change invalidates the item. Adding an item
    /// with this flag fails when no biometrics are enrolled — which
    /// is why `BiometricUnlock.enable` evaluates the policy first.
    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            throw BiometricUnlockError.keychainError(
                "Could not create the Face ID access control.")
        }
        return accessControl
    }
}

#else

/// No Security framework (Linux CI): biometrics are unavailable and
/// nothing is ever stored. The coordinator treats this exactly like
/// "no Face ID on this device".
public final class KeychainBiometricStore: BiometricKeychain {
    public init() {}
    public func exists() -> Bool { false }
    public func load(authenticatedContext: Any?) throws -> Data? {
        throw BiometricUnlockError.notAvailable
    }
    public func save(_ data: Data?) throws {
        throw BiometricUnlockError.notAvailable
    }
    public func delete() {}
}

#endif

// MARK: - SessionStore over the Keychain

/// A `SessionStore` (SupabaseClient.swift) whose bytes live in the
/// biometric Keychain item. `load()` is the plain protocol read: it
/// never prompts, so at app launch it returns nil for a protected
/// item (the client starts session-less and the auth screen offers
/// Face ID). `loadAuthenticated` is the unlock path, given the
/// `LAContext` that just passed evaluation.
public final class BiometricSessionStore: SessionStore {
    public let keychain: BiometricKeychain

    public init(keychain: BiometricKeychain = KeychainBiometricStore()) {
        self.keychain = keychain
    }

    public func load() -> AuthSession? {
        guard let data = try? keychain.load(authenticatedContext: nil) else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession?) {
        try? saveThrowing(session)
    }

    /// Throwing save, so the opt-in flow can tell the user when the
    /// Keychain refused the item instead of silently losing it.
    public func saveThrowing(_ session: AuthSession?) throws {
        if let session {
            let data = try JSONEncoder().encode(session)
            try keychain.save(data)
        } else {
            try keychain.save(nil)
        }
    }

    /// Unlock-path read: decodes the session with the authenticated
    /// context. A corrupt payload is a Keychain error — the item is
    /// unusable and the caller deletes it.
    public func loadAuthenticated(authenticatedContext: Any?) throws -> AuthSession? {
        guard let data = try keychain.load(authenticatedContext: authenticatedContext) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw BiometricUnlockError.keychainError(
                "The saved Face ID session could not be read.")
        }
    }
}
