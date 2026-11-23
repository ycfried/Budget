// OnBudgetKit — BiometricSessionStore.swift
//
// Face ID unlock (native v1, owner-approved Nov 9, 2026): the
// biometric-protected copy of the Supabase session.
//
// Why a second store exists at all: the shipped default session
// store (`KeychainSessionStore`, below) keeps the session JSON in
// the shared App Group Keychain item with NO biometric gate —
// `boot()` would read it and walk straight into Home without
// asking for a face. So opting in moves the APP-side session: the
// client swaps its store to this one (see
// `SupabaseClient.replaceSessionStore`), and every later app-side
// save (sign-in, token refresh, password change) lands in the
// biometric item instead. The shared Keychain copy stays — the
// mirror (`MirroredSessionStore`) keeps it in sync so the widget
// can still fetch fresh numbers — so Face ID gates opening the
// app, not the widget's numbers. Opting out swaps back to the
// default store and deletes the biometric item. Sign-out and a
// refused refresh clear the session through the same `setSession`
// path, so the Keychain item is deleted by those flows too — no
// separate cleanup call is needed anywhere.
//
// The item is a single generic-password entry (one signed-in account
// per device — there is no account switch without sign-out first):
//   service "com.onbudget.ios.biometric-session", account
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
        service: String = "com.onbudget.ios.biometric-session",
        account: String = "supabase-session"
    ) {
        self.service = service
        self.account = account
    }

    /// The device's biometry name for user-facing copy ("Face ID" /
    /// "Touch ID"), so Touch ID hardware never sees "Face ID" text
    /// (audit A-P2-2). Falls back to "Face ID" when the kind cannot
    /// be determined. Non-prompting: `canEvaluatePolicy` only reads
    /// the enrolment.
    private var biometryName: String {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
        else { return "Face ID" }
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
        #else
        return "Face ID"
        #endif
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
                "\(biometryName) approved the unlock but the saved session could not be read.")
        case errSecAuthFailed:
            throw BiometricUnlockError.biometricsChanged
        default:
            throw BiometricUnlockError.keychainError(
                "Could not read the saved \(biometryName) session (\(status)).")
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
                "Could not save the \(biometryName) session (\(status)).")
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
                "Could not create the \(biometryName) access control.")
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
    /// The device's biometry name for user-facing copy (audit
    /// A-P2-2): "Face ID" unless the caller knows the kind.
    public let biometryName: String

    public init(
        keychain: BiometricKeychain = KeychainBiometricStore(),
        biometryName: String = "Face ID"
    ) {
        self.keychain = keychain
        self.biometryName = biometryName
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
                "The saved \(biometryName) session could not be read.")
        }
    }
}

// MARK: - Default Keychain session store (F-17, build 64)

/// The DEFAULT session store: the session JSON in a single
/// generic-password Keychain item shared with the widget extension
/// through the App Group — never in plaintext UserDefaults, and
/// never behind a biometric prompt.
///
/// Why the widget can read this item: its access group is the App
/// Group identifier (`group.com.onbudget.ios`,
/// `WidgetSnapshotStore.groupID`) — the same identifier the app and
/// the widget already share. An app's effective Keychain
/// access-group list is its `keychain-access-groups` entitlement,
/// then its application identifier, then its
/// `com.apple.security.application-groups` entitlement, so the App
/// Group identifier is a valid `kSecAttrAccessGroup` with no
/// separate Keychain Sharing capability and no Team ID prefix on
/// the value (the prefix belongs on `keychain-access-groups`
/// entitlement values, not on App Group identifiers). Both targets
/// already carry the App Group entitlement
/// (`OnBudget.entitlements`, `OnBudgetWidget.entitlements`), so the
/// app and the widget read and write this one item.
///
/// Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// readable once the device has been unlocked after boot (so the
/// widget's background refresh can read it), never leaving the
/// device, never in a backup. There is deliberately NO biometric
/// access control on this item — that gate lives on the separate
/// `BiometricSessionStore` item, which guards opening the app UI;
/// the widget must be able to read the session without a face.
/// The item is NOT synchronizable — it never leaves this device.
///
/// One item, one account: there is no account switch without
/// sign-out first, exactly like the biometric item.
///
/// Platform split: the same seam as `KeychainBiometricStore` — the
/// real SecItem implementation on Apple platforms, a stub that
/// stores nothing on Linux (the package also compiles there), so
/// the feature is simply unavailable in Linux CI and every test
/// still compiles. The migration below verifies its Keychain write
/// before deleting the legacy copies, so on a platform where the
/// store holds nothing the legacy copies are left in place.
public final class KeychainSessionStore: SessionStore {
    public let service: String
    public let account: String
    /// The Keychain access group — the App Group identifier, shared
    /// with the widget extension (see the type doc above).
    public let accessGroup: String

    public init(
        service: String = "com.onbudget.ios.session",
        account: String = "supabase-session",
        accessGroup: String = WidgetSnapshotStore.groupID
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    /// Identifies the underlying Keychain item (access group +
    /// service + account). Two stores with the same identity point
    /// at the same item even when they are different objects —
    /// `SupabaseClient.replaceSessionStore` uses this so swapping
    /// between two wrappers of the same item can never delete the
    /// session the new store just wrote.
    public var storageIdentity: String { "\(accessGroup)\n\(service)\n\(account)" }

    public func load() -> AuthSession? {
        guard let data = Self.readItem(service: service, account: account, accessGroup: accessGroup) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession?) {
        if let session {
            guard let data = try? JSONEncoder().encode(session) else { return }
            Self.writeItem(data, service: service, account: account, accessGroup: accessGroup)
        } else {
            Self.deleteItem(service: service, account: account, accessGroup: accessGroup)
        }
    }

    /// True when the shared item holds a readable session. Never
    /// prompts (the item has no biometric access control). A
    /// corrupt item reads as absent — it is unrecoverable either
    /// way, and the caller falls back to sign-in.
    public func exists() -> Bool { load() != nil }

    // MARK: Migration from the legacy plaintext stores

    /// Moves any session still in the legacy plaintext stores into
    /// this shared Keychain item, then deletes both plaintext
    /// copies: the standard UserDefaults copy (the pre-build-64
    /// default) and the App Group UserDefaults mirror copy (build
    /// 40, widget sync). Returns the moved session, or the session
    /// already in the Keychain when there was one, or nil when
    /// there was nothing anywhere. Idempotent — safe to call on
    /// every launch; after the first run there are no legacy copies
    /// left to move, and a Keychain copy always wins over the
    /// plaintext ones (it is the freshest write). A failed Keychain
    /// write leaves the legacy copies in place so the next launch
    /// can retry instead of forcing a re-login.
    @discardableResult
    public static func migrateLegacyCopies() -> AuthSession? {
        let store = KeychainSessionStore()
        let standardLegacy = UserDefaultsSessionStore()
        let mirrorLegacy = UserDefaults(suiteName: WidgetSnapshotStore.groupID)
            .map { UserDefaultsSessionStore(defaults: $0) }
        if let existing = store.load() {
            standardLegacy.save(nil)
            mirrorLegacy?.save(nil)
            return existing
        }
        let legacy = standardLegacy.load() ?? mirrorLegacy?.load()
        guard let legacy else {
            standardLegacy.save(nil)
            mirrorLegacy?.save(nil)
            return nil
        }
        store.save(legacy)
        guard store.load() != nil else { return nil }
        standardLegacy.save(nil)
        mirrorLegacy?.save(nil)
        return legacy
    }

    /// The default store for a fresh client: runs the one-time
    /// legacy migration, then returns the shared Keychain store.
    public static func migrated() -> KeychainSessionStore {
        _ = migrateLegacyCopies()
        return KeychainSessionStore()
    }
}

#if canImport(Security)

extension KeychainSessionStore {
    fileprivate static func baseQuery(service: String, account: String, accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    fileprivate static func readItem(service: String, account: String, accessGroup: String) -> Data? {
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    fileprivate static func writeItem(_ data: Data, service: String, account: String, accessGroup: String) {
        // Delete-then-add: updating in place would keep a stale
        // accessibility / access group, and deleting needs no
        // authentication. A failed add leaves no item rather than a
        // half-written one; the migration verifies the write before
        // deleting the legacy copies.
        deleteItem(service: service, account: account, accessGroup: accessGroup)
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    fileprivate static func deleteItem(service: String, account: String, accessGroup: String) {
        _ = SecItemDelete(baseQuery(service: service, account: account, accessGroup: accessGroup) as CFDictionary)
    }
}

#else

extension KeychainSessionStore {
    /// No Security framework (Linux CI): the default store holds
    /// nothing, exactly like the `KeychainBiometricStore` stub
    /// above. The migration's write verification fails, so legacy
    /// copies are left alone on Linux too.
    fileprivate static func readItem(service: String, account: String, accessGroup: String) -> Data? { nil }
    fileprivate static func writeItem(_ data: Data, service: String, account: String, accessGroup: String) {}
    fileprivate static func deleteItem(service: String, account: String, accessGroup: String) {}
}

#endif
