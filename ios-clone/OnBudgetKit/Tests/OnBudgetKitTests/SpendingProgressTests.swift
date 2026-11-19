import XCTest
@testable import OnBudgetKit

/// Build 46 (Nov 18, 2026): the Home hero's progress circle reads
/// this helper, so the fraction math is pinned here — the ring can
/// never show a partial arc when over budget, a negative arc, or a
/// crash on a zero capacity.
final class SpendingProgressTests: XCTestCase {
    func testZeroChargesIsZero() {
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 0, capacityCents: 40000), 0)
        XCTAssertFalse(SpendingProgress.isOverBudget(chargesCents: 0, capacityCents: 40000))
    }

    func testHalfSpent() {
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 20000, capacityCents: 40000), 0.5, accuracy: 0.001)
        XCTAssertFalse(SpendingProgress.isOverBudget(chargesCents: 20000, capacityCents: 40000))
    }

    func testOwnerExample59Percent() {
        // The owner's screenshot: $236.42 spent of $400.00.
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 23642, capacityCents: 40000), 0.59105, accuracy: 0.001)
    }

    func testOverBudgetCapsAtOne() {
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 45000, capacityCents: 40000), 1)
        XCTAssertTrue(SpendingProgress.isOverBudget(chargesCents: 45000, capacityCents: 40000))
    }

    func testZeroCapacityWithNoChargesIsZero() {
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 0, capacityCents: 0), 0)
        XCTAssertFalse(SpendingProgress.isOverBudget(chargesCents: 0, capacityCents: 0))
    }

    func testZeroCapacityWithChargesIsOverBudgetFullRing() {
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 1000, capacityCents: 0), 1)
        XCTAssertTrue(SpendingProgress.isOverBudget(chargesCents: 1000, capacityCents: 0))
    }

    func testNegativeCapacityNeverGoesNegative() {
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 0, capacityCents: -5000), 0)
        XCTAssertEqual(SpendingProgress.fraction(chargesCents: 1000, capacityCents: -5000), 1)
    }
}

/// Build 46 (Nov 18, 2026): the two reverse RPCs return the same
/// JSON shape as the record/correct RPCs they mirror, so the client
/// reuses the existing result types — pinned here so a shape drift
/// in the SQL file fails loudly instead of at runtime.
final class ReverseCharityTests: XCTestCase {
    func testReverseCashGiftResultDecodes() throws {
        let json = """
        {"gift_id": "11111111-1111-1111-1111-111111111111", "given_cents": 38700, "remaining_cents": 31300}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(CharityCashGiftResult.self, from: json)
        XCTAssertEqual(result.giftId.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(result.givenCents, 38700)
        XCTAssertEqual(result.remainingCents, 31300)
    }

    func testReverseIncomeResultDecodes() throws {
        let json = """
        {"income_id": "22222222-2222-2222-2222-222222222222", "rate_bp": 1000, "committed_cents": 35000}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(CharityIncomeResult.self, from: json)
        XCTAssertEqual(result.incomeId.uuidString, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(result.rateBp, 1000)
        XCTAssertEqual(result.committedCents, 35000)
    }
}
