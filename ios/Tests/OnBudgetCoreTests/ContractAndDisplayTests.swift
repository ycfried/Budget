import XCTest
@testable import OnBudgetCore

final class ContractAndDisplayTests: XCTestCase {
    let response = #"{"week_start":"2026-11-01","base_available_cents":35000,"temp_cents":5000,"carried_debt_cents":2500,"charges_cents":18750,"available_cents":21250,"week_locked":false,"pending_refund_excluded_cents":1500}"#
    func testComputeWeekDirectAndEnvelope() throws {
        let direct = try BackendContracts.decodeWeek(Data(response.utf8))
        let wrapped = try BackendContracts.decodeWeek(Data("{\"result\":\(response)}".utf8))
        XCTAssertEqual(direct, wrapped)
        XCTAssertEqual(direct.carriedDebtCents, 2_500) // incoming D, no max(0,D-B) transformation
        XCTAssertEqual(direct.availableCents, 21_250)
        XCTAssertThrowsError(try BackendContracts.decodeWeek(Data(#"{"error":"unauthorized"}"#.utf8)))
    }
    func testRequestNeverSendsDebtOrLegacyCredits() throws {
        let data = try JSONEncoder().encode(BackendContracts.ComputeWeekRequest(householdID: "synthetic-household"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["household_id"])
    }
    func testApproveUsesCurrentRPCArgumentNames() throws {
        let data = try JSONEncoder().encode(BackendContracts.ApproveRequest(requestID: "synthetic-request", amountCents: 500))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["request_id"] as? String, "synthetic-request")
        XCTAssertEqual(object["amount_cents"] as? Int, 500)
        XCTAssertNil(object["p_request_id"])
    }
    func testFiltersAndSearchAndSort() {
        let rows = Fixtures.snapshot().purchases
        var query = PurchaseQuery()
        query.filter = .pending
        XCTAssertEqual(query.apply(to: rows).count, 3)
        query.filter = .review
        XCTAssertEqual(query.apply(to: rows).map(\.id), ["sample-3"])
        query.filter = .all; query.search = "maple"
        XCTAssertEqual(query.apply(to: rows).count, 2)
        query.search = ""; query.card = "2222"; query.month = "2026-11"
        XCTAssertEqual(query.apply(to: rows).map(\.id), ["sample-2"])
        query.card = "All"; query.month = "All"; query.sort = .amount
        XCTAssertEqual(query.apply(to: rows).first?.id, "sample-3")
    }
    func testReversedIsNeverPostedAndUnknownIsVisible() throws {
        let reversed = try XCTUnwrap(Fixtures.snapshot().purchases.last)
        XCTAssertEqual(reversed.stateLabel, "Reversed")
        let data = try JSONEncoder().encode(reversed)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8)).replacingOccurrences(of: "reversed", with: "new_state")
        let unknown = try JSONDecoder().decode(Purchase.self, from: Data(text.utf8))
        XCTAssertEqual(unknown.stateLabel, "Unknown (new_state)")
    }
    func testWidgetPrivacyAndStaleness() throws {
        let widget = WidgetSnapshot(available: Money(cents: -2_500), fundAvailable: Money(cents: 100), computedAt: Fixtures.instant, isSample: true)
        XCTAssertFalse(widget.isStale(at: Fixtures.instant))
        XCTAssertTrue(widget.isStale(at: Fixtures.instant.addingTimeInterval(3601)))
        XCTAssertTrue(widget.isStale(at: Fixtures.instant.addingTimeInterval(-1)))
        let data = try JSONEncoder().encode(widget)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), widget)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["merchant", "token", "household", "bank", "email"] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testHistoryExportCarriesServerValues() {
        let text = HistoryExport.csv(Fixtures.snapshot().history)
        XCTAssertTrue(text.contains("Allowance cents"))
        XCTAssertTrue(text.contains("37500"))
        XCTAssertTrue(text.contains("Revised after a late posted charge"))
    }
}
