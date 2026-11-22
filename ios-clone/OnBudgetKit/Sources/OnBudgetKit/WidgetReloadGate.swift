// OnBudgetKit — WidgetReloadGate.swift
//
// Build 54 (owner, Nov 21, 2026): gate WidgetKit timeline reloads
// on the snapshot actually having changed, so the app stops burning
// its WidgetKit reload budget on redundant reloads. The app reloads
// on launch AND on every foreground — back-to-back, with the same
// snapshot — and on every Home/Funds refresh; WidgetKit budgets
// reloads, and a blown budget means later (real) reloads are
// ignored and the widget goes stale.
//
// The gate is a pure decision (this file): reload when no reload
// has happened yet, or when the stored snapshot actually changed.
// WidgetSnapshot is Equatable — numbers AND computedAt — so a
// refresh that writes a genuinely new snapshot (new numbers, or
// the same numbers freshly computed with a new "As of" time)
// still reloads; only a byte-identical snapshot is skipped. The
// state (which snapshot the last reload used) lives in the app
// (AppViewModel), which owns the WidgetCenter call; the widget
// extension's own reloads (sync tap, background refresh) are
// user- / schedule-initiated and are not gated here.

import Foundation

public enum WidgetReloadGate {
    /// Whether a timeline reload is needed for `current`, given the
    /// snapshot the previous reload used. A nil `lastReloaded`
    /// means no reload has happened yet in this process — reload.
    /// Otherwise reload only when the snapshot actually changed.
    public static func shouldReload(current: WidgetSnapshot?, lastReloaded: WidgetSnapshot?) -> Bool {
        guard let last = lastReloaded else { return true }
        return current != last
    }
}
