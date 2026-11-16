// OnBudgetKit — WidgetSnapshot.swift
//
// Home-screen widget data (native build 17, owner-approved Nov 12, 2026):
// the two numbers the widget shows, written by the app into the shared
// App Groups container and read by the widget extension. The widget
// NEVER signs in to Supabase itself — it only ever reads this snapshot.
//
// Sources of truth (same numbers the Home screen shows):
//   - availableCents = WeekResult.availableCents from the compute-week
//     Edge Function — what's left to spend this week (may be negative).
//   - charityRemainingCents = CharitySummary.remainingCents
//     (committed − given) — what's left to give.
//   - spentCents = WeekResult.chargesCents — what's been spent this
//     week (large / extra-large widget donut, build 28; the spent
//     line it fed in build 26 is gone).
//   - charityGivenCents / charityCommittedCents (build 35) — the
//     charity green bar on every size: given / committed, the share
//     of the charity obligation fulfilled. Optional so snapshots
//     written before build 35 still decode; a missing figure reads
//     as a modest fixed accent fill, never an invented number.
// The app writes the snapshot at the end of HomeViewModel.refresh()
// when BOTH loads succeeded, and deletes it on sign-out, so the widget
// can never show another user's numbers. A failed load writes nothing:
// the previous snapshot stays and goes stale instead.
//
// Freshness: a snapshot is stale 1 hour after it was computed, or when
// its computedAt is in the future (clock skew). The widget shows the
// update time and labels stale numbers as possibly out of date — it
// NEVER presents a stale number as if it were live.
//
// Pure Foundation — no SwiftUI, no WidgetKit, no network — so the
// widget extension (APPLICATION_EXTENSION_API_ONLY) can link this
// module and the package tests can cover the encode/decode + staleness
// rules. Group id is a plain constant (single source of truth for the
// app target, the widget target, and both entitlements files).

import Foundation

/// The two widget numbers, as the Home screen shows them.
/// No session, household identifiers, merchant, or bank fields.
/// `spentCents` (build 26) feeds the large / extra-large donut;
/// optional so snapshots written before build 26 still decode.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let weekStart: String
    public let availableCents: Int
    public let charityRemainingCents: Int
    public let spentCents: Int?
    public let charityGivenCents: Int?
    public let charityCommittedCents: Int?
    public let computedAt: Date

    public init(
        weekStart: String,
        availableCents: Int,
        charityRemainingCents: Int,
        spentCents: Int? = nil,
        charityGivenCents: Int? = nil,
        charityCommittedCents: Int? = nil,
        computedAt: Date
    ) {
        self.weekStart = weekStart
        self.availableCents = availableCents
        self.charityRemainingCents = charityRemainingCents
        self.spentCents = spentCents
        self.charityGivenCents = charityGivenCents
        self.charityCommittedCents = charityCommittedCents
        self.computedAt = computedAt
    }

    /// Stale 1 hour after computation, or when computedAt is in the
    /// future. The widget labels stale snapshots; it never hides the
    /// staleness.
    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(computedAt) > 3600 || computedAt > date
    }

    /// Spent share of the weekly allowance for the donut (build 28):
    /// spent / (spent + available), clamped 0...1; nil when the
    /// snapshot carries no spent figure (pre-build-26 snapshots).
    /// Over budget (available < 0) reads as fully spent (1.0) — the
    /// ring is full red. A zero allowance with no spending reads 0.
    public var spentFraction: Double? {
        guard let spent = spentCents else { return nil }
        if availableCents < 0 { return 1.0 }
        let allowance = spent + availableCents
        guard allowance > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(spent) / Double(allowance)))
    }

    /// Share of the charity obligation fulfilled (build 35): given /
    /// committed, clamped 0...1; nil when the snapshot carries no
    /// charity figures (pre-build-35 snapshots) or when nothing is
    /// committed yet. The widget uses a modest fixed accent fill in
    /// that case — never an invented given figure.
    public var charityGivenFraction: Double? {
        guard let given = charityGivenCents,
              let committed = charityCommittedCents,
              committed > 0 else { return nil }
        return min(1.0, max(0.0, Double(given) / Double(committed)))
    }
}

/// Read/write of the snapshot in the shared App Groups container.
/// `defaults` is injectable so tests can use a throwaway suite instead
/// of the real group container; production callers omit it.
public enum WidgetSnapshotStore {
    public static let groupID = "group.com.onbudget.ios"
    public static let key = "widgetSnapshot"

    public static func write(_ snapshot: WidgetSnapshot, to defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: groupID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store?.set(data, forKey: key)
    }

    public static func read(from defaults: UserDefaults? = nil) -> WidgetSnapshot? {
        let store = defaults ?? UserDefaults(suiteName: groupID)
        guard let data = store?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public static func delete(from defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: groupID)
        store?.removeObject(forKey: key)
    }
}
