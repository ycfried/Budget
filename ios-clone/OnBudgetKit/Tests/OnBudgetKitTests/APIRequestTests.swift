// OnBudgetKitTests — APIRequestTests.swift
//
// Unit tests for request construction: every RPC name + exact
// parameter names, every PostgREST query shape, every Edge Function
// invocation, and the GoTrue auth requests. Fixtures only — no
// network. The stub transport returns canned responses so the full
// call path (token attachment, status handling) is exercised too.
//
// Source of truth for every expectation: the call sites in live.js
// (v66, origin/main 872ae11) and the SQL / Edge Function sources
// cited in the API files.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OnBudgetKit

// MARK: - Stub transport

final class StubTransport: HTTPTransport {
    var handler: (URLRequest) -> (Data, HTTPURLResponse)
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return handler(request)
    }

    static func json(_ object: Any, status: Int = 200, url: URL = URL(string: "https://example.com")!) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    static func raw(_ string: String, status: Int = 200, url: URL = URL(string: "https://example.com")!) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(string.utf8), response)
    }
}

func testConfiguration() -> SupabaseConfiguration {
    SupabaseConfiguration(
        baseURL: URL(string: "https://tnkhvdkmwmwiogiienee.supabase.co")!,
        anonKey: "sb_publishable_P2phsf7AYX38dbmxOEZKzQ_uw168MZP"
    )
}

func testTokenProvider(_ token: String = "test-jwt") -> () async throws -> String {
    { token }
}

func jsonBody(of request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return [:]
    }
    return json
}

// MARK: - RPC request construction

final class RPCRequestTests: XCTestCase {
    private var rpcs: RPCClient!

    override func setUp() {
        super.setUp()
        rpcs = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: StubTransport(handler: { _ in StubTransport.raw("") })
        )
    }

    func testReclassifySendsExactNameAndParams() throws {
        let id = UUID()
        let request = try rpcs.makeRequest(name: "reclassify_transaction", params: [
            "txn_id": id.uuidString, "new_kind": "refund", "reason": "Amex cashback",
        ])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/reclassify_transaction")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), testConfiguration().anonKey)
        let body = jsonBody(of: request)
        XCTAssertEqual(body["txn_id"] as? String, id.uuidString)
        XCTAssertEqual(body["new_kind"] as? String, "refund")
        XCTAssertEqual(body["reason"] as? String, "Amex cashback")
    }

    func testExcludeRestoreDeleteUseExactParamNames() throws {
        let id = UUID()
        for (name, params) in [
            ("exclude_transaction", ["txn_id": id.uuidString, "reason": "duplicate"]),
            ("restore_transaction", ["txn_id": id.uuidString]),
            ("delete_transaction", ["p_transaction_id": id.uuidString]),
            ("mark_transaction_charity", ["p_transaction_id": id.uuidString]),
        ] as [(String, [String: Any])] {
            let request = try rpcs.makeRequest(name: name, params: params)
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/\(name)", name)
            XCTAssertEqual(jsonBody(of: request) as NSDictionary, params as NSDictionary, name)
        }
    }

    func testLinkRefundUsesPParamsAndReturnsPurchaseId() async throws {
        let refundId = UUID()
        let purchaseId = UUID()
        let transport = StubTransport(handler: { _ in
            StubTransport.raw("\"\(purchaseId.uuidString)\"")
        })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let returned: UUID = try await client.linkRefund(pRefundId: refundId, pPurchaseId: purchaseId)
        XCTAssertEqual(returned, purchaseId)
        let body = jsonBody(of: transport.requests[0])
        XCTAssertEqual(body["p_refund_id"] as? String, refundId.uuidString)
        XCTAssertEqual(body["p_purchase_id"] as? String, purchaseId.uuidString)
    }

    func testApproveAndAllocateSendsNullOverrideWhenAbsent() throws {
        let request = try rpcs.makeRequest(name: "approve_and_allocate", params: [
            "p_request_id": UUID().uuidString,
            "p_amount_cents": 5000,
            "p_override_reason": NSNull(),
        ])
        let body = jsonBody(of: request)
        XCTAssertTrue(body["p_override_reason"] is NSNull)
        XCTAssertEqual(body["p_amount_cents"] as? Int, 5000)
    }

    func testResolveDuplicateCandidateParams() throws {
        let request = try rpcs.makeRequest(name: "resolve_duplicate_candidate", params: [
            "p_candidate_id": UUID().uuidString,
            "p_action": "merge",
            "p_note": "",
            "p_remember_alias": true,
        ])
        let body = jsonBody(of: request)
        XCTAssertEqual(body["p_action"] as? String, "merge")
        XCTAssertEqual(body["p_remember_alias"] as? Bool, true)
    }

    func testJoinHouseholdNullBodyDecodesToNil() async throws {
        let transport = StubTransport(handler: { _ in StubTransport.raw("null") })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let result = try await client.joinHouseholdByCode(code: "BADCODE")
        XCTAssertNil(result)
        XCTAssertEqual(jsonBody(of: transport.requests[0])["code"] as? String, "BADCODE")
    }

    func testCreateHouseholdPassesPName() async throws {
        let householdId = UUID()
        let transport = StubTransport(handler: { _ in
            StubTransport.raw("\"\(householdId.uuidString)\"")
        })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let returned = try await client.createHousehold(pName: "Friedman Household")
        XCTAssertEqual(returned, householdId)
        XCTAssertEqual(jsonBody(of: transport.requests[0])["p_name"] as? String, "Friedman Household")
    }

    func testAddFundMoneyParams() throws {
        let request = try rpcs.makeRequest(name: "add_fund_money", params: [
            "p_household_id": UUID().uuidString,
            "p_amount_cents": 10000,
            "p_note": "top up",
            "p_client_key": "key-1",
        ])
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/add_fund_money")
        XCTAssertEqual(jsonBody(of: request)["p_client_key"] as? String, "key-1")
    }

    func testCharityGiftParams() throws {
        let request = try rpcs.makeRequest(name: "record_charity_gift", params: [
            "p_household_id": UUID().uuidString,
            "p_merchant": "TOIREMORG",
            "p_amount_cents": 200,
            "p_date": "2026-11-03",
            "p_card_suffix": "0000",
            "p_note": "",
            "p_dedupe_hash": "abc123",
            "p_client_key": "gift-1",
        ])
        let body = jsonBody(of: request)
        XCTAssertEqual(body["p_merchant"] as? String, "TOIREMORG")
        XCTAssertEqual(body["p_card_suffix"] as? String, "0000")
    }

    func testWeeklyOverrideLoopWritesOneRowPerWeek() async throws {
        let transport = StubTransport(handler: { _ in StubTransport.raw("") })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        // 2026-11-08 is a Sunday; 3 weeks → 11-08, 11-15, 11-22.
        try await client.setWeeklyAllowanceOverride(
            pHouseholdId: UUID(), firstWeekStart: "2026-11-08",
            pAllowanceCents: 40000, weeks: 3
        )
        XCTAssertEqual(transport.requests.count, 3)
        let starts = transport.requests.map { jsonBody(of: $0)["p_week_start"] as? String }
        XCTAssertEqual(starts, ["2026-11-08", "2026-11-15", "2026-11-22"])
        XCTAssertTrue(transport.requests.allSatisfy {
            jsonBody(of: $0)["p_allowance_cents"] as? Int == 40000
        })
    }
}

// MARK: - PostgREST query construction

final class PostgrestQueryTests: XCTestCase {
    func testTransactionsPageQueryMatchesLiveJS() {
        let householdId = UUID()
        let query = PostgrestQuery(
            table: "transactions",
            columns: "*",
            filters: [.householdId(householdId), .onOrAfterNov1()],
            orders: [PostgrestOrder("date", ascending: false)],
            limit: 101
        )
        let request = query.buildRequest(configuration: testConfiguration(), accessToken: "jwt")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/rest/v1/transactions")
        XCTAssertEqual(items["select"], "*")
        XCTAssertEqual(items["household_id"], "eq.\(householdId.uuidString)")
        XCTAssertEqual(items["date"], "gte.2026-11-01")
        XCTAssertEqual(items["order"], "date.desc")
        XCTAssertEqual(items["limit"], "101")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
    }

    func testFetchPageProbeReturnsHasMore() async throws {
        // 101 rows back for a page of 100 → hasMore true, 100 rendered.
        let row: [String: Any] = [
            "id": UUID().uuidString, "household_id": UUID().uuidString,
            "date": "2026-11-02", "merchant": "AMAZON", "amount_cents": 1059,
            "card_suffix": "1005", "source": "plaid", "state": "verified",
            "kind": "charge", "fund_allocation_cents": 0, "excluded": false,
            "exclude_reason": "", "late": false, "dedupe_hash": "h",
            "created_at": "2026-11-02T00:00:00Z",
        ]
        let transport = StubTransport(handler: { _ in
            StubTransport.json(Array(repeating: row, count: 101))
        })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let (rows, hasMore): ([Transaction], Bool) = try await client.fetchPage(
            PostgrestQuery(table: "transactions", columns: "*",
                           filters: [.householdId(UUID())],
                           orders: [PostgrestOrder("date", ascending: false)]),
            pageSize: 100
        )
        XCTAssertEqual(rows.count, 100)
        XCTAssertTrue(hasMore)
        // The probe asked for 101.
        let limit = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "limit" })?.value
        XCTAssertEqual(limit, "101")
    }

    func testFetchAllPagesWalks1000RowPages() async throws {
        struct Row: Decodable { let n: Int }
        var offsets: [String] = []
        let transport = StubTransport(handler: { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            offsets.append(items.first(where: { $0.name == "offset" })?.value ?? "?")
            let offset = Int(offsets.last ?? "0") ?? 0
            let count = offset == 0 ? 1000 : 3
            let rows = (0..<count).map { ["n": offset + $0] }
            return StubTransport.json(rows)
        })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let rows: [Row] = try await client.fetchAllPages(PostgrestQuery(
            table: "transactions", columns: "n",
            orders: [PostgrestOrder("created_at", ascending: true)]
        ))
        XCTAssertEqual(rows.count, 1003)
        XCTAssertEqual(offsets, ["0", "1000"])
    }

    func testInFilterAndIlikeRendering() {
        let query = PostgrestQuery(
            table: "transactions",
            columns: "id,merchant,amount_cents,date",
            filters: [
                .in("kind", ["charge", "fund_charge"]),
                .ilike("merchant", "%AMAZON%"),
            ]
        )
        let request = query.buildRequest(configuration: testConfiguration(), accessToken: "jwt")
        let raw = request.url!.absoluteString
        XCTAssertTrue(raw.contains("kind=in.(charge,fund_charge)"), raw)
        XCTAssertTrue(raw.contains("merchant=ilike.%25AMAZON%25"), raw)
    }
}

// MARK: - Households-table reads (phone feedback, Nov 11, 2026)
//
// The `households` table's primary key is `id` — there is NO
// `household_id` column on it. The five reads below used to filter
// with `.householdId` (`household_id=eq.…`), so every one of them
// failed live with "column households.household_id does not exist":
// the Budget card showed the raw DB error, the invite code read
// "No invite code is set up", the auto-sync toggle read OFF while
// syncs ran, the Extra Fund never loaded, and Home's allowance flag
// came back nil (blank allowance/spent). These tests pin the filter
// to `id=eq.…` at the real call sites, through the stub transport.
// The email-connections read is pinned here too: its select omitted
// `household_id` while the model declares it non-optional, so the
// whole list failed to decode ("Could not load email connections.").

final class HouseholdReadsTests: XCTestCase {
    private func queryItems(of request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func clientReturning(_ object: Any) -> (PostgrestClient, StubTransport) {
        let transport = StubTransport(handler: { _ in StubTransport.json(object) })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        return (client, transport)
    }

    private func assertFiltersById(_ request: URLRequest, householdId: UUID, file: StaticString = #filePath, line: UInt = #line) {
        let items = queryItems(of: request)
        XCTAssertEqual(items["id"], "eq.\(householdId.uuidString)", file: file, line: line)
        XCTAssertNil(items["household_id"], "households-table reads must not filter on household_id", file: file, line: line)
    }

    func testHouseholdNameFiltersById() async throws {
        let householdId = UUID()
        let (client, transport) = clientReturning([[
            "id": householdId.uuidString, "name": "Friedman Household",
            "base_allowance_cents": 500000, "fund_shortfall_cents": 0,
            "auto_sync_enabled": true, "created_at": "2026-11-01T00:00:00Z",
        ]])
        let name = try await client.householdName(householdId: householdId)
        XCTAssertEqual(name, "Friedman Household")
        XCTAssertEqual(transport.requests.count, 1)
        assertFiltersById(transport.requests[0], householdId: householdId)
    }

    func testHouseholdAllowanceFiltersById() async throws {
        let householdId = UUID()
        let (client, transport) = clientReturning([[
            "base_allowance_cents": 500000, "allowance_set_at": "2026-11-06T00:00:00Z",
        ]])
        let allowance = try await client.householdAllowance(householdId: householdId)
        XCTAssertEqual(allowance.baseAllowanceCents, 500000)
        XCTAssertTrue(allowance.allowanceExplicitlySet)
        assertFiltersById(transport.requests[0], householdId: householdId)
    }

    func testAutoSyncEnabledFiltersById() async throws {
        let householdId = UUID()
        let (client, transport) = clientReturning([["auto_sync_enabled": true]])
        let enabled = try await client.autoSyncEnabled(householdId: householdId)
        XCTAssertTrue(enabled)
        assertFiltersById(transport.requests[0], householdId: householdId)
    }

    func testInviteCodeFiltersById() async throws {
        let householdId = UUID()
        let (client, transport) = clientReturning([["invite_code": "PJM2HG"]])
        let code = try await client.inviteCode(householdId: householdId)
        XCTAssertEqual(code, "PJM2HG")
        assertFiltersById(transport.requests[0], householdId: householdId)
    }

    func testFundShortfallFiltersById() async throws {
        let householdId = UUID()
        let (client, transport) = clientReturning([["fund_shortfall_cents": 0]])
        let shortfall = try await client.fundShortfallCents(householdId: householdId)
        XCTAssertEqual(shortfall, 0)
        assertFiltersById(transport.requests[0], householdId: householdId)
    }

    func testEmailConnectionsSelectIncludesHouseholdId() async throws {
        let householdId = UUID()
        let (client, transport) = clientReturning([[
            "id": "11111111-1111-1111-1111-111111111111",
            "household_id": householdId.uuidString,
            "provider": "gmail", "email_address": "ycfried1@gmail.com",
            "status": "active", "last_poll_at": "2026-11-11T18:00:00Z",
            "last_error": NSNull(), "created_at": "2026-11-02T00:00:00Z",
            "connected_at": "2026-11-02T00:00:00Z",
        ]])
        let rows = try await client.emailConnections(householdId: householdId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].householdId, householdId)
        XCTAssertEqual(rows[0].emailAddress, "ycfried1@gmail.com")
        let items = queryItems(of: transport.requests[0])
        XCTAssertEqual(items["household_id"], "eq.\(householdId.uuidString)")
        let selected = (items["select"] ?? "").split(separator: ",").map(String.init)
        XCTAssertTrue(selected.contains("household_id"), "select must include household_id or the row cannot decode: \(items["select"] ?? "")")
    }
}

// MARK: - Edge Function request construction

final class EdgeFunctionRequestTests: XCTestCase {
    private var functions: EdgeFunctionsClient!

    override func setUp() {
        super.setUp()
        functions = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: StubTransport(handler: { _ in StubTransport.raw("{}") })
        )
    }

    func testComputeWeekSendsOnlyHouseholdId() throws {
        let request = try functions.makeRequest(name: "compute-week", body: [
            "household_id": UUID().uuidString,
        ])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/functions/v1/compute-week")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), testConfiguration().anonKey)
        let body = jsonBody(of: request)
        XCTAssertNil(body["D"])
        XCTAssertNil(body["T"])
        XCTAssertNotNil(body["household_id"])
    }

    func testAllFunctionNames() throws {
        for name in ["compute-week", "week-close", "plaid-link", "plaid-exchange",
                     "plaid-sync", "plaid-disconnect", "plaid-account-disconnect",
                     "plaid-webhook-register", "gmail-oauth-start", "gmail-poll",
                     "gmail-disconnect", "delete-account"] {
            let request = try functions.makeRequest(name: name, body: [:])
            XCTAssertEqual(request.url?.path, "/functions/v1/\(name)", name)
        }
    }

    func testPlaidExchangeBody() throws {
        let request = try functions.makeRequest(name: "plaid-exchange", body: [
            "household_id": UUID().uuidString,
            "public_token": "public-sandbox-xxx",
            "institution_name": "American Express",
        ])
        let body = jsonBody(of: request)
        XCTAssertEqual(body["public_token"] as? String, "public-sandbox-xxx")
        XCTAssertEqual(body["institution_name"] as? String, "American Express")
    }
}

// MARK: - Auth request construction

final class AuthRequestTests: XCTestCase {
    func testSignInRequest() throws {
        let request = try SupabaseClient.authRequest(
            configuration: testConfiguration(),
            path: "token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            method: "POST",
            accessToken: nil,
            jsonBody: ["email": "a@example.com", "password": "secret123"]
        )
        XCTAssertEqual(request.url?.path, "/auth/v1/token")
        XCTAssertEqual(request.url?.query, "grant_type=password")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = jsonBody(of: request)
        XCTAssertEqual(body["email"] as? String, "a@example.com")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testSignUpCarriesFullNameMetadata() throws {
        let request = try SupabaseClient.authRequest(
            configuration: testConfiguration(),
            path: "signup",
            method: "POST",
            accessToken: nil,
            jsonBody: ["email": "a@example.com", "password": "secret123",
                       "data": ["full_name": "Shuki Friedman"]]
        )
        let body = jsonBody(of: request)
        let data = body["data"] as? [String: Any]
        XCTAssertEqual(data?["full_name"] as? String, "Shuki Friedman")
    }

    func testUpdateUserUsesPUTWithBearer() throws {
        let request = try SupabaseClient.authRequest(
            configuration: testConfiguration(),
            path: "user",
            method: "PUT",
            accessToken: "jwt",
            jsonBody: ["password": "newpassword1"]
        )
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
    }
}
