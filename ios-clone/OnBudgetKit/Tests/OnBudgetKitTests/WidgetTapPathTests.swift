// OnBudgetKitTests — WidgetTapPathTests.swift
//
// Build 54 (owner, Nov 21, 2026): the iPad widget's sync button
// tap did nothing — it did not even open the app — and removing +
// re-adding the widget fresh changed nothing, so the cause is in
// code. The fix has three pure, testable pieces, pinned here:
//
// 1. The deep link (WidgetSyncDeepLink): onbudget://widget-sync is
//    the fallback the app handles (OnBudgetApp.onOpenURL) — the
//    widget's whole-widget link stays onbudget://home.
// 2. The reload gate (WidgetReloadGate): launch + foreground used
//    to reload back-to-back with the same snapshot, burning the
//    WidgetKit reload budget — reload only when the snapshot
//    actually changed.
// 3. The failed mark (WidgetSyncStateStore.needsShortTimelineEntry):
//    a .failed state gets the same prompt re-render as a success,
//    so the red mark actually appears (build 51 had it getting no
//    short entry).
//
// What these tests CANNOT prove: that a real tap on the owner's
// iPad reaches the intent. WidgetKit tap delivery is only
// verifiable on a real device by the owner — do not claim the
// test proves tap delivery.

import Foundation
import Testing
@testable import OnBudgetKit

@Suite("Widget tap path (build 54)")
struct WidgetTapPathTests {
    private func snapshot(availableCents: Int = 12_000, computedAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(
            weekStart: "Nov 16",
            availableCents: availableCents,
            charityRemainingCents: 500,
            spentCents: 3_000,
            charityGivenCents: 200,
            charityCommittedCents: 700,
            computedAt: computedAt
        )
    }

    // MARK: - Deep link routing

    @Test("widget-sync URL is recognised")
    func widgetSyncURLRecognised() {
        #expect(WidgetSyncDeepLink.isWidgetSync(URL(string: "onbudget://widget-sync")!))
        #expect(WidgetSyncDeepLink.url == URL(string: "onbudget://widget-sync")!)
    }

    @Test("home and other URLs are not widget-sync")
    func otherURLsNotWidgetSync() {
        #expect(!WidgetSyncDeepLink.isWidgetSync(URL(string: "onbudget://home")!))
        #expect(!WidgetSyncDeepLink.isWidgetSync(URL(string: "onbudget://reset-password")!))
        #expect(!WidgetSyncDeepLink.isWidgetSync(URL(string: "https://getstag.us")!))
        #expect(!WidgetSyncDeepLink.isWidgetSync(URL(string: "onbudget://widget-sync-extra")!))
    }

    // MARK: - Reload gate

    @Test("no prior reload always reloads (first launch)")
    func noPriorReloadReloads() {
        #expect(WidgetReloadGate.shouldReload(current: snapshot(), lastReloaded: nil))
    }

    @Test("identical snapshot does not reload")
    func identicalSnapshotDoesNotReload() {
        let current = snapshot()
        #expect(!WidgetReloadGate.shouldReload(current: current, lastReloaded: current))
    }

    @Test("changed numbers reload")
    func changedNumbersReload() {
        let last = snapshot(availableCents: 12_000)
        let current = snapshot(availableCents: 11_500)
        #expect(WidgetReloadGate.shouldReload(current: current, lastReloaded: last))
    }

    @Test("same numbers, freshly computed, reload (the As of time moved)")
    func freshComputeReloads() {
        let last = snapshot(computedAt: Date(timeIntervalSince1970: 1_000_000))
        let current = snapshot(computedAt: Date(timeIntervalSince1970: 1_000_060))
        #expect(WidgetReloadGate.shouldReload(current: current, lastReloaded: last))
    }

    // MARK: - Failed mark gets a short timeline entry

    @Test("failed state gets a short entry so the red mark appears")
    func failedGetsShortEntry() {
        #expect(WidgetSyncStateStore.needsShortTimelineEntry(state: .failed, at: nil))
        #expect(WidgetSyncStateStore.needsShortTimelineEntry(state: .failed, at: Date()))
    }

    @Test("syncing and recent success also get a short entry; idle does not")
    func syncingAndSuccessShortEntry() {
        let now = Date()
        #expect(WidgetSyncStateStore.needsShortTimelineEntry(state: .syncing, at: nil, now: now))
        #expect(WidgetSyncStateStore.needsShortTimelineEntry(state: .succeeded, at: now, now: now))
        #expect(!WidgetSyncStateStore.needsShortTimelineEntry(state: .idle, at: nil, now: now))
    }

    @Test("stale success gets no short entry")
    func staleSuccessNoShortEntry() {
        let now = Date()
        let stale = now.addingTimeInterval(-WidgetSyncStateStore.clearAfter - 1)
        #expect(!WidgetSyncStateStore.needsShortTimelineEntry(state: .succeeded, at: stale, now: now))
    }
}
