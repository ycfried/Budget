/// OnBudgetKit — shared Swift module for the OnBudget native iOS clone.
///
/// Pure Swift + SwiftUI design tokens, helpers and configuration.
/// No screens live here; screens live in the OnBudget app target.
/// The macOS platform entry in Package.swift exists only so the
/// package can be unit-tested with `swift test` on a Mac runner —
/// the shipped app is iOS-only.
///
/// NOTE (compile-fixes, Nov 9, 2026): this namespace type used to
/// be named `OnBudgetKit`, but a top-level type with the same name
/// as its module shadows the module in qualified lookups, so
/// `OnBudgetKit.MoneyFormat` (and every other `OnBudgetKit.X`)
/// resolved to the enum instead of the module and failed to
/// compile. It is renamed `OnBudgetKitInfo` so the module name
/// stays usable for qualification everywhere.
public enum OnBudgetKitInfo {
    /// Scaffold version. Bumped by the screen builders as milestones land.
    public static let version = "0.1.0-scaffold"
}
