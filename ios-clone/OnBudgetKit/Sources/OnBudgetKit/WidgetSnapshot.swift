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
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let weekStart: String
    public let availableCents: Int
    public let charityRemainingCents: Int
    public let computedAt: Date

    public init(
        weekStart: String,
        availableCents: Int,
        charityRemainingCents: Int,
        computedAt: Date
    ) {
        self.weekStart = weekStart
        self.availableCents = availableCents
        self.charityRemainingCents = charityRemainingCents
        self.computedAt = computedAt
    }

    /// Stale 1 hour after computation, or when computedAt is in the
    /// future. The widget labels stale snapshots; it never hides the
    /// staleness.
    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(computedAt) > 3600 || computedAt > date
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
