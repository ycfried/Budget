// OnBudgetKit — WidgetSnapshotRefresher.swift
//
// Widget snapshot refresh (build 40, owner Nov 16, 2026 — moved to
// the kit in build 43, owner Nov 17, 2026).
//
// The ONE fetch path for fresh widget numbers. Two callers share it:
//   - RefreshWidgetIntent (the widget's sync button) — fetches fresh
//     numbers on tap, and writes its own button state
//     (WidgetSyncStateStore spinner / checkmark) around the call.
//   - The background refresh task (build 43) — fetches fresh numbers
//     when iOS schedules it, and writes NO button state: the
//     spinner / checkmark is tap feedback only, and a background
//     run has no tap to feed back to.
//
// The fetch itself is unchanged (build 40): the app mirrors its
// session into the shared App Group container on every save
// (MirroredSessionStore), and writes the household id alongside the
// snapshot. The refresher builds a SupabaseClient on an
// App-Group-backed session store, calls compute-week + the charity
// summary (active income, verified gifts, cash gifts), and writes a
// new snapshot. The fund names ride along from the existing snapshot
// (a rename does not change the numbers, and the names are already
// pushed there on rename). When there is no session / no household
// id / the fetch fails (signed out, token expired, offline), it
// returns false and writes nothing — the widget keeps showing its
// last-known numbers with the stale dot, never a blank.
//
// Background refresh (build 43, owner Nov 17, 2026): the widget
// used to update only when the app was opened or the sync button
// was tapped. A BGAppRefreshTask now fetches fresh numbers in the
// background when iOS schedules it — a few times a day, based on
// usage and battery. That timing is iOS's, not ours: the
// earliestBeginDate below is a HINT only, and this is NOT a timer —
// nothing here runs on a fixed schedule, and no part of the app
// may describe it as one. The 24 hourly timeline entries stay as
// the fallback (the widget never goes blank), and the sync button
// stays as the on-demand path.

import Foundation

/// The background widget-refresh task's identity and timing. The
/// identifier is the single source of truth: the app target
/// registers and schedules it under this value, and the app's
/// Info.plist lists it under BGTaskSchedulerPermittedIdentifiers.
public enum WidgetBackgroundRefresh {
    /// The BGAppRefreshTask identifier, used everywhere (register,
    /// schedule, Info.plist). Must match exactly.
    public static let taskIdentifier = "com.onbudget.ios.widget-refresh"
    /// How far out the next run is requested: ~1 hour. A hint only —
    /// iOS decides when the task actually runs, and may run it later
    /// (or not at all) based on usage, battery, and how often the
    /// task has completed. Never a 5-minute timer.
    public static let requestInterval: TimeInterval = 3600

    /// The earliestBeginDate for the next run, ~1 hour from `date`.
    public static func nextBeginDate(from date: Date = Date()) -> Date {
        date.addingTimeInterval(requestInterval)
    }
}

/// Fetches fresh dashboard numbers and writes a new widget snapshot.
/// Returns false when there was nothing fresh to write (no session /
/// no household / fetch failed) — the caller reloads nothing in
/// that case and the last snapshot stands.
public enum WidgetSnapshotRefresher {
    @discardableResult
    public static func refreshSnapshot() async -> Bool {
        guard let householdId = WidgetSnapshotStore.readHouseholdId() else { return false }
        // The session mirrored into the App Group by the app
        // (MirroredSessionStore). No session → signed out (or the
        // app has never saved one) → nothing fresh to fetch.
        guard let groupDefaults = UserDefaults(suiteName: WidgetSnapshotStore.groupID) else { return false }
        let store = UserDefaultsSessionStore(defaults: groupDefaults)
        guard store.load() != nil else { return false }
        let client = SupabaseClient(store: store)
        do {
            let week = try await client.functions.computeWeek(householdId: householdId)
            async let income = client.postgrest.activeCharityIncome(householdId: householdId)
            async let given = client.postgrest.verifiedCharityGiftAmounts(householdId: householdId)
            let incomeRows = try await income
            let givenAmounts = try await given
            // Cash gifts (build 40): fault-tolerant — if the
            // charity_cash_gifts table does not exist yet (the SQL
            // not applied), the fetch throws and the gifts read as
            // empty rather than failing the whole sync.
            let cashGiftRows: [CharityCashGift]
            do {
                cashGiftRows = try await client.postgrest.charityCashGifts(householdId: householdId)
            } catch {
                cashGiftRows = []
            }
            let committed = incomeRows.filter { $0.status == "active" }.reduce(0) { $0 + $1.committedCents }
            let givenTotal = givenAmounts.reduce(0, +) + cashGiftRows.reduce(0) { $0 + $1.amountCents }
            // The fund names ride along from the existing snapshot
            // (a rename pushes them there immediately, and a Home
            // refresh rewrites them) — a sync must not drop them.
            let fundNames = WidgetSnapshotStore.read()?.fundNames
            WidgetSnapshotStore.write(WidgetSnapshot(
                weekStart: week.weekStart,
                availableCents: week.availableCents,
                charityRemainingCents: committed - givenTotal,
                spentCents: week.chargesCents,
                charityGivenCents: givenTotal,
                charityCommittedCents: committed,
                fundNames: fundNames,
                computedAt: Date()
            ))
            return true
        } catch {
            return false
        }
    }
}
