import XCTest
@testable import OnBudgetCore

final class TransactionContractTests: XCTestCase {
    private func decode(state: String, source: String = "plaid", kind: String = "charge", excluded: Bool = false, prior: String? = nil) throws -> TransactionRow {
        var object: [String: Any] = ["id": "synthetic-row", "date": "2026-11-03", "merchant": "Sample merchant", "amount_cents": 1234,
            "card_suffix": "1111", "source": source, "state": state, "kind": kind, "excluded": excluded, "fund_allocation_cents": 0]
        if let prior { object["pre_exclusion_state"] = prior }
        return try JSONDecoder().decode(TransactionRow.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testLegacyProvisionalMappingPreservesBankVersusAlertDistinction() throws {
        XCTAssertEqual(try decode(state: "provisional").purchase().state, .pending)
        XCTAssertEqual(try decode(state: "provisional", source: "amex_alert").purchase().state, .provisional)
        XCTAssertEqual(try decode(state: "provisional", source: "manual").purchase().state, .provisional)
        XCTAssertEqual(try decode(state: "verified").purchase().state, .posted)
    }
    func testLegacyReversedExcludedFlagDoesNotHideReversal() throws {
        let purchase = try decode(state: "reversed", excluded: true).purchase()
        XCTAssertEqual(purchase.state, .reversed)
        XCTAssertEqual(purchase.stateLabel, "Reversed")
    }
    func testUnknownStateAndKindAreRetainedAndVisible() throws {
        let row = try decode(state: "future_server_state", kind: "future_server_kind")
        let purchase = row.purchase()
        XCTAssertEqual(purchase.state, .unknown("future_server_state"))
        XCTAssertEqual(purchase.kind, .unknown("future_server_kind"))
        XCTAssertEqual(purchase.stateLabel, "Unknown (future_server_state)")
        XCTAssertEqual(row.state, "future_server_state")
    }
    func testExclusionRestoresExplicitPriorWithoutDateHeuristic() throws {
        let row = try decode(state: "excluded", excluded: true, prior: "provisional")
        XCTAssertEqual(row.purchase().priorState, .pending)
        let missing = try decode(state: "excluded", excluded: true)
        XCTAssertNil(missing.purchase().priorState)
    }
    func testEveryNewStateHasDistinctFilter() throws {
        let states: [(String, PurchaseFilter)] = [("provisional", .provisional), ("pending", .pending), ("posted", .posted), ("needs_review", .review),
            ("excluded", .excluded), ("reversed", .reversed), ("voided", .voided), ("quarantined", .quarantined)]
        for (state, filter) in states {
            let purchase = try decode(state: state, source: "manual").purchase()
            XCTAssertTrue(filter.includes(purchase), state)
            for (_, other) in states where other != filter { XCTAssertFalse(other.includes(purchase), "\(state) matched \(other)") }
        }
    }
    func testInvalidDateAndFractionalCentsFailClosed() throws {
        let encoded = try JSONEncoder().encode(decode(state: "pending"))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(TransactionRow.self, from: Data(text.replacingOccurrences(of: "2026-11-03", with: "2026-02-30").utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(TransactionRow.self, from: Data(text.replacingOccurrences(of: "1234", with: "12.34").utf8)))
    }
}
