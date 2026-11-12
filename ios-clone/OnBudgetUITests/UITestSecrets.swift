// OnBudget — UITestSecrets.swift
//
// Compile-time carrier for the Supabase service-role key the UI
// tests need to confirm fresh accounts via the Auth Admin API
// (email confirmation is ON, owner Nov 12, 2026).
//
// The UI test runner inherits neither the xcodebuild shell's
// environment nor the Mac runner's $HOME (it runs inside the
// simulator), so the key must travel inside the test bundle: the
// simulator workflow overwrites this file with a generated copy
// carrying the real key before building (see
// .github/workflows/ios-clone-simulator.yml, "Write UI-test
// service key source").
//
// The committed copy MUST stay empty: never put a real key here,
// never commit a key. A developer without the secret still builds
// fine — the helper then fails fast naming the missing secret.
enum UITestSecrets {
    /// Service-role key, or "" when not supplied (local builds).
    static let serviceRoleKey = ""
}
