/// OnBudgetKit — shared Swift module for the OnBudget native iOS clone.
///
/// Pure Swift + SwiftUI design tokens, helpers and configuration.
/// No screens live here; screens live in the OnBudget app target.
/// The macOS platform entry in Package.swift exists only so the
/// package can be unit-tested with `swift test` on a Mac runner —
/// the shipped app is iOS-only.
public enum OnBudgetKit {
    /// Scaffold version. Bumped by the screen builders as milestones land.
    public static let version = "0.1.0-scaffold"
}
