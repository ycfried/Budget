import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OnBudgetCore

final class ReadValidationWindowTests: XCTestCase, @unchecked Sendable {
    private let id = "11111111-1111-4111-8111-111111111111"
    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: String]? = nil) throws -> URLRequest {
        var url = URLComponents(string: "https://fixture.invalid")!
        url.path = path; url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        return request
    }
    private func table(_ relation: ReadRelation, range: String = "0-99", select: String? = nil) throws -> URLRequest {
        var value = try request("/rest/v1/\(relation.rawValue)", query: [
            .init(name: "select", value: select ?? relation.columns),
            .init(name: relation == .households ? "id" : "household_id", value: "eq.\(id)"),
            .init(name: "order", value: "created_at.asc,id.asc")])
        value.setValue(range, forHTTPHeaderField: "Range")
        value.setValue("items", forHTTPHeaderField: "Range-Unit")
        value.setValue("count=exact", forHTTPHeaderField: "Prefer")
        return value
    }
    private func rejected(_ window: ReadValidationWindow, _ request: URLRequest) async {
        do { try await window.admit(request); XCTFail("Must reject") } catch {}
        do { try await window.admit(self.request("/auth/v1/user")); XCTFail("Must stop permanently") }
        catch { XCTAssertEqual(error as? ConnectionError, .windowStopped) }
    }
    func testExactFullWindowAndOneRefreshThenStops() async throws {
        let window = ReadValidationWindow()
        try await window.admit(request("/auth/v1/token", method: "POST", query: [.init(name: "grant_type", value: "password")], body: ["email": "owner@example.test", "password": "synthetic-password"]))
        for _ in 0..<15 {
            try await window.admit(request("/auth/v1/user"))
            try await window.admit(request("/rest/v1/household_members", query: [.init(name: "select", value: "household_id,user_id,role,display_name"), .init(name: "user_id", value: "eq.\(id)")]))
        }
        try await window.admit(request("/functions/v1/compute-week", method: "POST", body: ["household_id": id]))
        for relation in ReadRelation.allCases { try await window.admit(table(relation)) }
        try await window.admit(request("/auth/v1/token", method: "POST", query: [.init(name: "grant_type", value: "refresh_token")], body: ["refresh_token": "synthetic-refresh"]))
        await rejected(window, try request("/auth/v1/user"))
    }
    func testEachCollectionReadOnlyOnce() async throws {
        let window = ReadValidationWindow()
        try await window.admit(table(.transactions))
        await rejected(window, try table(.transactions))
    }
    func testSecondSignInAndSecondRefreshRejected() async throws {
        for grant in ["password", "refresh_token"] {
            let window = ReadValidationWindow()
            let body = grant == "password" ? ["email": "owner@example.test", "password": "synthetic-password"] : ["refresh_token": "synthetic-refresh"]
            let value = try request("/auth/v1/token", method: "POST", query: [.init(name: "grant_type", value: grant)], body: body)
            try await window.admit(value)
            await rejected(window, value)
        }
    }
    func testNextPageAndOversizedPageDenied() async throws {
        for range in ["100-199", "0-499", "0-100"] { await rejected(ReadValidationWindow(), try table(.transactions, range: range)) }
    }
    func testWildcardComputedColumnsAndDuplicateQueryRejected() async throws {
        for select in ["*", "id,unexpected_function()", "access_token_encrypted"] {
            await rejected(ReadValidationWindow(), try table(.transactions, select: select))
        }
        await rejected(ReadValidationWindow(), try request("/auth/v1/user", query: [.init(name: "x", value: "1"), .init(name: "x", value: "2")]))
    }
    func testFinancialMutationAndUnexpectedWeekInputsDenied() async throws {
        for path in ["/rest/v1/rpc/allocate_fund", "/functions/v1/week-close", "/functions/v1/plaid-sync", "/functions/v1/delete-account", "/functions/v1/gmail-poll"] {
            await rejected(ReadValidationWindow(), try request(path, method: "POST", body: [:]))
        }
        await rejected(ReadValidationWindow(), try request("/functions/v1/compute-week", method: "POST", body: ["household_id": id, "D": "0"]))
    }
    func testExplicitStopCannotReset() async throws {
        let window = ReadValidationWindow()
        await window.stop()
        await rejected(window, try request("/auth/v1/user"))
    }
    func testConcurrentAdmissionAllowsOneCollectionRequest() async throws {
        let window = ReadValidationWindow()
        let value = try table(.transactions)
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 { group.addTask { do { try await window.admit(value); return true } catch { return false } } }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(admitted, 1)
    }
}
