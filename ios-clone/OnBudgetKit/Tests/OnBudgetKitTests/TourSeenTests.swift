import XCTest
@testable import OnBudgetKit

/// Walkthrough one-time flag (build 50, Nov 20, 2026 — tutorial
/// one-time fix): the tour showed on EVERY app open because the
/// build-48 "seen" key folded in the session user UUID, which can
/// be nil or change while the session store is swapped — the flag
/// written at Skip/Done time was read back under a different key.
/// The stable key is per household, per device, and must not
/// depend on the session at all. A dedicated UserDefaults suite
/// keeps these tests off the real defaults.
final class TourSeenTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.onbudget.ios.tourSeenTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testStableKeyDoesNotDependOnUserId() {
        // The bug: the old key changed when the session user id
        // changed (or was nil during a store swap), so the flag
        // was never found again. The stable key is identical for
        // any user id — including nil.
        let household = UUID()
        XCTAssertEqual(
            TourSeen.key(householdId: household),
            TourSeen.key(householdId: household))
        XCTAssertNotEqual(
            TourSeen.legacyKey(userId: UUID(), householdId: household),
            TourSeen.legacyKey(userId: nil, householdId: household))
    }

    func testTourDoesNotRetriggerAfterBeingSeen() {
        // Mark seen as one user, then check as a DIFFERENT user
        // (and as signed-out) — the session-store swap that made
        // the tour re-trigger. The tour must still read as seen.
        let household = UUID()
        let firstUser = UUID()
        let secondUser = UUID()
        XCTAssertFalse(TourSeen.hasSeen(householdId: household, userId: firstUser, defaults: defaults))
        TourSeen.markSeen(householdId: household, userId: firstUser, defaults: defaults)
        XCTAssertTrue(TourSeen.hasSeen(householdId: household, userId: firstUser, defaults: defaults))
        XCTAssertTrue(TourSeen.hasSeen(householdId: household, userId: secondUser, defaults: defaults))
        XCTAssertTrue(TourSeen.hasSeen(householdId: household, userId: nil, defaults: defaults))
    }

    func testLegacyFlagIsHonoured() {
        // A flag written before build 50 under the legacy
        // composite key still counts as seen — the owner already
        // skipped the tour once, under the old key.
        let household = UUID()
        let user = UUID()
        defaults.set(true, forKey: TourSeen.legacyKey(userId: user, householdId: household))
        XCTAssertTrue(TourSeen.hasSeen(householdId: household, userId: user, defaults: defaults))
    }

    func testTourSeenIsPerHousehold() {
        // A new household gets the tour once too — the flag for
        // one household must not leak into another.
        let first = UUID()
        let second = UUID()
        TourSeen.markSeen(householdId: first, defaults: defaults)
        XCTAssertTrue(TourSeen.hasSeen(householdId: first, defaults: defaults))
        XCTAssertFalse(TourSeen.hasSeen(householdId: second, defaults: defaults))
    }
}
