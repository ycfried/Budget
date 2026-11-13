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
}
