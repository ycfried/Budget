// OnBudgetKit — RememberedEmail.swift
//
// The sign-in email Remember me saves (owner, Nov 12, 2026): when
// Remember me is ticked, the email is saved locally so the sign-in
// screen opens with it already filled in — the owner was at the
// sign-in screen with biometrics available and still faced an empty
// Email field. Unticking clears the saved email immediately.
//
// An email address is not a secret, so plain UserDefaults is fine.
// The password is NEVER stored here — it lives only in the
// Keychain-backed biometric session flow. The saved email is never
// logged anywhere.

import Foundation

/// The locally remembered sign-in email. Injectable `UserDefaults`
/// (and key) so tests use an isolated suite instead of `.standard`.
public struct RememberedEmail {
    /// Versioned like the session-store key, so a future migration
    /// can be detected.
    public static let defaultsKey = "onbudget.rememberedEmail.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The saved email, if one was remembered. Nil when nothing was
    /// saved, or when the stored value is blank.
    public func load() -> String? {
        guard let stored = defaults.string(forKey: key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return stored
    }

    /// Saves `email` (trimmed). A blank value clears instead, so the
    /// store never holds an empty string.
    public func save(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear()
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    /// Forgets the saved email. Unticking Remember me calls this
    /// immediately — it does not just stop saving.
    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
