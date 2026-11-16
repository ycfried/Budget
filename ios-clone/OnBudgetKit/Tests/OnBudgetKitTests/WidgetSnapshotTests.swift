// OnBudgetKitTests — WidgetSnapshotTests.swift
//
// Widget snapshot (build 17): encode/decode round-trip, the 1-hour
// staleness rule, and the shared-container store. No network; the
// store tests use a throwaway UserDefaults suite, never the real
// App Groups container.

import Foundation
import XCTest
@testable import OnBudgetKit

final class WidgetSnapshotTests: XCTestCase {
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.onbudget.ios.widget-snapshot-tests")
        testDefaults.removeObject(forKey: WidgetSnapshotStore.key)
    }

    override func tearDown() {
        testDefaults.removeObject(forKey: WidgetSnapshotStore.key)
        testDefaults = nil
        super.tearDown()
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 12345,
            charityRemainingCents: -250,
            computedAt: Date(timeIntervalSince1970: 1_763_000_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotIsNotStaleWithinAnHour() {
        let now = Date()
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 100,
            charityRemainingCents: 200,
            computedAt: now.addingTimeInterval(-3599)
        )
        XCTAssertFalse(snapshot.isStale(at: now))
    }

    func testSnapshotIsStaleAfterAnHour() {
        let now = Date()
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 100,
            charityRemainingCents: 200,
            computedAt: now.addingTimeInterval(-3601)
        )
        XCTAssertTrue(snapshot.isStale(at: now))
    }

    func testSnapshotFromTheFutureIsStale() {
        let now = Date()
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 100,
            charityRemainingCents: 200,
            computedAt: now.addingTimeInterval(60)
        )
        XCTAssertTrue(snapshot.isStale(at: now))
    }

    func testStoreWriteReadDelete() {
        XCTAssertNil(WidgetSnapshotStore.read(from: testDefaults))
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 12345,
            charityRemainingCents: 6789,
            computedAt: Date()
        )
        WidgetSnapshotStore.write(snapshot, to: testDefaults)
        XCTAssertEqual(WidgetSnapshotStore.read(from: testDefaults), snapshot)
        WidgetSnapshotStore.delete(from: testDefaults)
        XCTAssertNil(WidgetSnapshotStore.read(from: testDefaults))
    }

    func testStoreOverwritesStaleSnapshot() {
        let old = WidgetSnapshot(
            weekStart: "2026-11-01",
            availableCents: 1,
            charityRemainingCents: 2,
            computedAt: Date(timeIntervalSince1970: 0)
        )
        WidgetSnapshotStore.write(old, to: testDefaults)
        let fresh = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 9999,
            charityRemainingCents: 8888,
            computedAt: Date()
        )
        WidgetSnapshotStore.write(fresh, to: testDefaults)
        XCTAssertEqual(WidgetSnapshotStore.read(from: testDefaults), fresh)
    }

    // MARK: - Donut (build 28)

    private func snapshot(spent: Int?, available: Int) -> WidgetSnapshot {
        WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: available,
            charityRemainingCents: 0,
            spentCents: spent,
            computedAt: Date()
        )
    }

    func testSpentFractionIsSpentOverAllowance() {
        XCTAssertEqual(snapshot(spent: 10000, available: 30000).spentFraction, 0.25)
    }

    func testSpentFractionIsNilWithoutSpentFigure() {
        XCTAssertNil(snapshot(spent: nil, available: 30000).spentFraction)
    }

    func testSpentFractionOverBudgetIsFull() {
        XCTAssertEqual(snapshot(spent: 50000, available: -10000).spentFraction, 1.0)
    }

    func testSpentFractionZeroSpentIsZero() {
        XCTAssertEqual(snapshot(spent: 0, available: 40000).spentFraction, 0.0)
    }

    func testSpentFractionZeroAllowanceIsZero() {
        XCTAssertEqual(snapshot(spent: 0, available: 0).spentFraction, 0.0)
    }

    func testPlaceholderSnapshotSpentFractionIsSeventyPercent() {
        // The placeholder entry the widget shows before any timeline
        // arrives (OnBudgetWidget.Provider.placeholder): available
        // 17307, charity 4200, spent 40349 — the donut reads 70%.
        // Pins the sample data the owner saw on his iPad, so a
        // placeholder change is a deliberate edit, not drift.
        let placeholder = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 17307,
            charityRemainingCents: 4200,
            spentCents: 40349,
            computedAt: Date()
        )
        XCTAssertEqual(placeholder.spentFraction ?? -1, 40349.0 / 57656.0, accuracy: 0.001)
    }

    // MARK: - Charity bar (build 35)

    private func charitySnapshot(given: Int?, committed: Int?) -> WidgetSnapshot {
        WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 37000,
            charityRemainingCents: 66300,
            spentCents: 3000,
            charityGivenCents: given,
            charityCommittedCents: committed,
            computedAt: Date()
        )
    }

    func testCharityGivenFractionIsGivenOverCommitted() {
        XCTAssertEqual(charitySnapshot(given: 3000, committed: 10000).charityGivenFraction, 0.3)
    }

    func testCharityGivenFractionIsNilWithoutCharityFigures() {
        XCTAssertNil(charitySnapshot(given: nil, committed: nil).charityGivenFraction)
    }

    func testCharityGivenFractionIsNilWhenNothingCommitted() {
        XCTAssertNil(charitySnapshot(given: 0, committed: 0).charityGivenFraction)
    }

    func testCharityGivenFractionClampsAtFull() {
        XCTAssertEqual(charitySnapshot(given: 12000, committed: 10000).charityGivenFraction, 1.0)
    }

    func testSnapshotWithoutCharityFieldsStillDecodes() throws {
        // Pre-build-35 snapshots carry no charity fields: decoding
        // must succeed with nil figures, never fail the whole read.
        let json = """
        {"weekStart":"2026-11-08","availableCents":37000,"charityRemainingCents":66300,"spentCents":3000,"computedAt":1763000000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: json)
        XCTAssertNil(decoded.charityGivenCents)
        XCTAssertNil(decoded.charityCommittedCents)
        XCTAssertNil(decoded.charityGivenFraction)
        XCTAssertEqual(decoded.spentFraction, 3000.0 / 40000.0)
    }

    // MARK: - Timeline (build 36)

    // Build 35 returned a single entry expiring after 15 minutes,
    // so the widget fell back to the grey placeholder 4×/hour and
    // got stuck on it overnight. Build 36 returns 24 hourly
    // entries over the next day, so a valid entry always exists.

    func testTimelineHasTwentyFourHourlyEntries() {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let dates = WidgetTimeline.entryDates(from: start)
        XCTAssertEqual(dates.count, 24)
        XCTAssertEqual(WidgetTimeline.entryCount, 24)
        XCTAssertEqual(WidgetTimeline.entryInterval, 3600)
    }

    func testTimelineEntriesAreOneHourApart() {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let dates = WidgetTimeline.entryDates(from: start)
        XCTAssertEqual(dates.first, start)
        for index in 1..<dates.count {
            XCTAssertEqual(
                dates[index].timeIntervalSince(dates[index - 1]),
                3600, accuracy: 0.001,
                "entry \(index) must be exactly one hour after entry \(index - 1)"
            )
        }
    }

    func testTimelineSpansTwentyFourHours() {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let dates = WidgetTimeline.entryDates(from: start)
        // First entry now, last entry 23 hours later: the timeline
        // covers a full day (24 hourly slots, not a single expiry).
        XCTAssertEqual(dates.last?.timeIntervalSince(start), 23 * 3600, accuracy: 0.001)
    }

    func testTimelineReloadDateIsLastEntryDate() {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let dates = WidgetTimeline.entryDates(from: start)
        XCTAssertEqual(WidgetTimeline.reloadAfterDate(from: start), dates.last)
    }

    func testTimelineEntriesCarryTheSnapshot() {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 37000,
            charityRemainingCents: 4200,
            spentCents: 3000,
            computedAt: start
        )
        let entries = WidgetTimeline.entries(from: start, snapshot: snapshot)
        XCTAssertEqual(entries.count, 24)
        // Every entry carries the SAME snapshot (read once), so no
        // hour of the day shows different numbers than any other.
        XCTAssertTrue(entries.allSatisfy { $0.snapshot == snapshot })
        XCTAssertEqual(entries.map(\.date), WidgetTimeline.entryDates(from: start))
    }

    func testTimelineEntriesCarryNilSnapshotWhenNoneExists() {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let entries = WidgetTimeline.entries(from: start, snapshot: nil)
        XCTAssertEqual(entries.count, 24)
        XCTAssertTrue(entries.allSatisfy { $0.snapshot == nil })
    }

    func testTimelineStalenessAdvancesWithEntryDates() {
        // The view computes staleness from entry.date, so the hourly
        // entry dates must actually advance past the 1-hour rule —
        // a single far-future entry (or a .never policy) would never
        // go stale. A snapshot computed at `start` is fresh at the
        // first entry and stale from the second entry on.
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        let snapshot = WidgetSnapshot(
            weekStart: "2026-11-08",
            availableCents: 37000,
            charityRemainingCents: 4200,
            computedAt: start
        )
        let entries = WidgetTimeline.entries(from: start, snapshot: snapshot)
        XCTAssertFalse(snapshot.isStale(at: entries[0].date))
        XCTAssertTrue(snapshot.isStale(at: entries[1].date))
        XCTAssertTrue(snapshot.isStale(at: entries[23].date))
    }
}
