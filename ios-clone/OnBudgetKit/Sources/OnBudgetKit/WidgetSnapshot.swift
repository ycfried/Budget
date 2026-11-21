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
// update time ("As of 6:15PM", bottom-right, build 42) with an amber
// freshness dot when stale — it NEVER presents a stale number as if
// it were live.
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
    /// Custom fund names (build 37 — fund rename, owner Nov 16,
    /// 2026): the household's `fund_names` map (fund key → custom
    /// name as typed), so the widget shows a renamed fund's name
    /// too. Optional so snapshots written before build 37 still
    /// decode; a missing map means the default names.
    public let fundNames: [String: String]?
    public let computedAt: Date

    public init(
        weekStart: String,
        availableCents: Int,
        charityRemainingCents: Int,
        spentCents: Int? = nil,
        charityGivenCents: Int? = nil,
        charityCommittedCents: Int? = nil,
        fundNames: [String: String]? = nil,
        computedAt: Date
    ) {
        self.weekStart = weekStart
        self.availableCents = availableCents
        self.charityRemainingCents = charityRemainingCents
        self.spentCents = spentCents
        self.charityGivenCents = charityGivenCents
        self.charityCommittedCents = charityCommittedCents
        self.fundNames = fundNames
        self.computedAt = computedAt
    }

    /// The charity fund's display name (build 37 — fund rename):
    /// the custom name when stored, else "Charity". The custom name
    /// is shown exactly as typed. (The "available" label needs
    /// no fund name — it never says "Spending" — so only the
    /// charity label reads from the map.)
    public var charityDisplayName: String {
        if let custom = fundNames?["charity"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return "Charity"
    }

    /// The widget's charity figure label (build 37): "<Name> left"
    /// — "Charity left" by default, the custom name when renamed.
    public var charityLeftLabel: String {
        "\(charityDisplayName) left"
    }

    /// A copy of this snapshot with new fund names (build 40, Nov 16,
    /// 2026): when a fund is renamed, the app updates just the names
    /// in the stored snapshot — the numbers are unchanged by a rename
    /// — so the widget shows the new name on its next timeline
    /// reload without waiting for a Home refresh.
    public func withFundNames(_ names: [String: String]) -> WidgetSnapshot {
        WidgetSnapshot(
            weekStart: weekStart,
            availableCents: availableCents,
            charityRemainingCents: charityRemainingCents,
            spentCents: spentCents,
            charityGivenCents: charityGivenCents,
            charityCommittedCents: charityCommittedCents,
            fundNames: names,
            computedAt: computedAt
        )
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
    /// committed yet. The widget shows an EMPTY track in that case
    /// (build 53: the old `?? 0.25` faked a quarter fill when $0
    /// was committed) — no fill is ever faked.
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
    /// The household the widget syncs for (build 40, Nov 16, 2026 —
    /// widget sync): the widget extension needs the household id to
    /// call compute-week + the charity summary. Written by the app
    /// alongside the snapshot (the id is stable — it only changes
    /// on household switch / sign-out, both of which rewrite it).
    /// The snapshot itself carries no household identifier; this is
    /// a separate App Group key the widget extension reads.
    public static let householdIdKey = "widgetHouseholdId"

    public static func write(_ snapshot: WidgetSnapshot, to defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: groupID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store?.set(data, forKey: key)
    }

    public static func writeHouseholdId(_ id: UUID, to defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: groupID)
        store?.set(id.uuidString, forKey: householdIdKey)
    }

    public static func readHouseholdId(from defaults: UserDefaults? = nil) -> UUID? {
        let store = defaults ?? UserDefaults(suiteName: groupID)
        guard let string = store?.string(forKey: householdIdKey) else { return nil }
        return UUID(uuidString: string)
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

/// Widget sync feedback state (build 42, owner Nov 17, 2026).
///
/// WidgetKit renders widget views statically: a Button(intent:) has
/// no pressed-state binding and no @State that survives a tap, so
/// the button itself cannot animate mid-flight. The feedback is
/// therefore driven through the App Group: RefreshWidgetIntent
/// writes .syncing before it fetches (and reloads the timeline so
/// the button flips to a spinner), then writes .succeeded or
/// .failed when the fetch lands (and reloads again, so the button
/// flips to a checkmark — or a red refresh icon on failure). The
/// view reads this state live at render time. The success mark is
/// transient (15 seconds); the failure mark PERSISTS until the next
/// sync writes a new state (build 51, owner Nov 20, 2026) — the
/// old 15-second expiry made a failed tap look like nothing
/// happened, so the owner read it as "no button / no way to
/// refresh". A fresh snapshot written by the app (Home refresh)
/// clears the stored state. The Provider adds a short timeline
/// entry 20 seconds out while a transient state is live, so
/// WidgetKit re-renders and the success mark clears promptly
/// instead of lingering until the next hourly entry. The snapshot
/// itself is untouched — this is a separate App Group key, and a
/// failed sync leaves the last snapshot (and its numbers) in place.
public enum WidgetSyncState: String, Equatable, Sendable {
    case idle
    case syncing
    case succeeded
    case failed
}

public enum WidgetSyncStateStore {
    public static let key = "widgetSyncState"
    public static let dateKey = "widgetSyncStateAt"
    /// How long the success mark stays on the button. The failure
    /// mark has no window — it stays until the next sync writes a
    /// new state (see `isMarkVisible`).
    public static let transientWindow: TimeInterval = 15
    /// The short timeline entry the Provider adds while a transient
    /// state is live, so the mark clears promptly.
    public static let clearAfter: TimeInterval = 20

    /// Whether the button mark for the stored (state, date) is
    /// still visible at `now`. Success is transient (15 seconds);
    /// failure persists until the next sync writes a new state
    /// (build 51) — a failed tap must stay legible instead of
    /// expiring into the plain icon. Syncing shows until the intent
    /// writes its landed state.
    public static func isMarkVisible(state: WidgetSyncState, at date: Date?, now: Date = Date()) -> Bool {
        switch state {
        case .idle: return false
        case .syncing: return true
        case .succeeded:
            guard let date else { return false }
            return now.timeIntervalSince(date) < transientWindow
        case .failed: return true
        }
    }

    public static func write(_ state: WidgetSyncState, at date: Date = Date(), to defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: WidgetSnapshotStore.groupID)
        store?.set(state.rawValue, forKey: key)
        store?.set(date.timeIntervalSinceReferenceDate, forKey: dateKey)
    }

    public static func read(from defaults: UserDefaults? = nil) -> (state: WidgetSyncState, date: Date?) {
        let store = defaults ?? UserDefaults(suiteName: WidgetSnapshotStore.groupID)
        guard let raw = store?.string(forKey: key),
              let state = WidgetSyncState(rawValue: raw) else {
            return (.idle, nil)
        }
        let date: Date?
        if let number = store?.object(forKey: dateKey) as? NSNumber {
            date = Date(timeIntervalSinceReferenceDate: number.doubleValue)
        } else {
            date = nil
        }
        return (state, date)
    }

    public static func clear(from defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: WidgetSnapshotStore.groupID)
        store?.removeObject(forKey: key)
        store?.removeObject(forKey: dateKey)
    }
}

/// Widget timeline shape (build 36 — the build-35 15-minute backstop
/// was the bug, not the fix).
///
/// Build 35 returned a SINGLE timeline entry with policy
/// `.after(now + 15 min)`: the timeline expired 4×/hour, and every
/// expiry left a window in which WidgetKit had no valid entry and
/// rendered the placeholder — grey skeleton bars — until it got
/// around to calling `getTimeline` again. On an idle / throttled
/// device that window stretched indefinitely, so the widget got
/// stuck on grey bars overnight (owner, Nov 16, 2026: small + one
/// medium stuck on placeholder while another medium showed real
/// numbers).
///
/// The fix: a timeline of HOURLY entries spanning the next 24 hours,
/// each carrying the current snapshot, with policy `.after(last
/// entry date)`. There is always a valid entry, so WidgetKit never
/// falls back to the placeholder once a snapshot exists — a stale
/// snapshot keeps showing its last-known numbers with the amber dot
/// + "As of …" footer instead of grey bars. The entry dates
/// MUST advance hourly (a single far-future entry, or a `.never`
/// policy, would break staleness: the view computes `isStale(at:
/// entry.date)`, so a frozen entry date would never go stale).
/// Freshness still comes from the app: it calls
/// `reloadAllTimelines()` on launch, on every foreground, and on
/// every Home refresh, which re-reads the snapshot and rebuilds
/// this timeline.
///
/// Pure Foundation, so the package tests cover it; the Provider in
/// the widget target (no test target of its own) just maps these
/// entries onto `WidgetEntry`.
public struct WidgetTimelineEntry: Sendable {
    public let date: Date
    public let snapshot: WidgetSnapshot?

    public init(date: Date, snapshot: WidgetSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public enum WidgetTimeline {
    /// One entry per hour — 24 entries cover a full day.
    public static let entryCount = 24
    /// Entries are one hour apart, matching the snapshot's 1-hour
    /// staleness rule: the amber dot flips at the first hourly
    /// boundary after the snapshot goes stale.
    public static let entryInterval: TimeInterval = 3600

    /// The 24 hourly entry dates starting at `start` (inclusive):
    /// `start`, `start + 1h`, …, `start + 23h`.
    public static func entryDates(from start: Date) -> [Date] {
        (0..<entryCount).map { start.addingTimeInterval(TimeInterval($0) * entryInterval) }
    }

    /// The 24 hourly entries starting at `start`, each carrying the
    /// same snapshot (read once by the caller). A nil snapshot means
    /// the widget has never loaded one — the view then shows its
    /// "Open the app" empty state, never sample data.
    public static func entries(from start: Date, snapshot: WidgetSnapshot?) -> [WidgetTimelineEntry] {
        entryDates(from: start).map { WidgetTimelineEntry(date: $0, snapshot: snapshot) }
    }

    /// The reload-after date for a timeline starting at `start`: the
    /// LAST entry's date, so WidgetKit asks for a fresh timeline
    /// exactly when the last hourly entry becomes current.
    public static func reloadAfterDate(from start: Date) -> Date {
        start.addingTimeInterval(TimeInterval(entryCount - 1) * entryInterval)
    }
}
