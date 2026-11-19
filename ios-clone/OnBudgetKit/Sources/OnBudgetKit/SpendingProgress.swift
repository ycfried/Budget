import Foundation

/// Spending progress math (build 46, Nov 18, 2026): the fraction of
/// the weekly capacity already spent, for the Home hero's progress
/// circle (and anywhere else a spent-vs-capacity ring or bar is
/// drawn). One place, so the hero and the widget can never drift
/// apart again.
///
/// Semantics (the hero's, kept exactly): over budget the fraction
/// is 1 — a full ring; a zero or negative capacity with no charges
/// is 0, never a divide-by-zero and never a negative arc.
public enum SpendingProgress {
    /// True when the charges exceed the capacity — the over-budget
    /// state (full ring, red fill, "Over budget" line).
    public static func isOverBudget(chargesCents: Int, capacityCents: Int) -> Bool {
        chargesCents > capacityCents
    }

    /// Spent fraction in 0...1, capped at 1 when over budget.
    public static func fraction(chargesCents: Int, capacityCents: Int) -> Double {
        if chargesCents > capacityCents { return 1 }
        guard capacityCents > 0 else { return 0 }
        return Double(chargesCents) / Double(capacityCents)
    }
}
