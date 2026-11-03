import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OnBudgetCore

private let syntheticUser = "11111111-1111-4111-8111-111111111111"
private let syntheticHousehold = "22222222-2222-4222-8222-222222222222"
private let householdUUID = UUID(uuidString: syntheticHousehold)!
private func authData(expiry: Int = 4_102_444_800, user: String = syntheticUser) -> Data {
    Data("{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_at\":\(expiry),\"user\":{\"id\":\"\(user)\"}}".utf8)
}
private func savedSession(expiry: Int, origin: String = "https://fixture.invalid") throws -> Data {
    let auth = try JSONDecoder().decode(APIValue.self, from: authData(expiry: expiry))
    return try JSONEncoder().encode(APIValue.object(["origin": .string(origin), "session": auth]))
}
private actor FixtureReadTransport: ReadHTTPTransport {
    var requests: [URLRequest] = []
    var pageData = Data("[]".utf8)
    var range = "*/0"
    var status = 200
    var role = "admin"
    var memberUser = syntheticUser
    var loginExpiry = 4_102_444_800
    var refreshUser = syntheticUser
    var weekData = Data(#"{"week_start":"2026-11-01","available_cents":null,"carried_debt_cents":123,"future":true}"#.utf8)
    func setupPage(_ json: String, range: String) { pageData = Data(json.utf8); self.range = range }
    func setStatus(_ value: Int) { status = value }
    func setRole(_ value: String) { role = value }
    func setMemberUser(_ value: String) { memberUser = value }
    func setExpiry(_ value: Int) { loginExpiry = value }
    func setRefreshUser(_ value: String) { refreshUser = value }
    func execute(_ request: URLRequest) throws -> ReadHTTPResponse {
        requests.append(request)
        if status != 200 { return ReadHTTPResponse(status: status, data: Data("sensitive server error".utf8)) }
        switch request.url!.path {
        case "/auth/v1/token":
            let refreshing = request.url!.query!.contains("refresh_token")
            return .init(status: 200, data: authData(expiry: refreshing ? 4_102_444_800 : loginExpiry, user: refreshing ? refreshUser : syntheticUser))
        case "/auth/v1/user": return .init(status: 200, data: Data("{\"id\":\"\(syntheticUser)\"}".utf8))
        case "/rest/v1/household_members":
            return .init(status: 200, data: Data("[{\"household_id\":\"\(syntheticHousehold)\",\"user_id\":\"\(memberUser)\",\"role\":\"\(role)\",\"display_name\":null}]".utf8))
        case "/functions/v1/compute-week": return .init(status: 200, data: weekData)
        default: return .init(status: 206, data: pageData, contentRange: range)
        }
    }
}

final class NativeReadClientTests: XCTestCase, @unchecked Sendable {
    private func configuration() throws -> ReadBackendConfiguration {
        try .init(origin: URL(string: "https://fixture.invalid")!, publicKey: "synthetic-public-key")
    }
    private func client(_ transport: FixtureReadTransport, vault: MemorySessionVault = .init(), time: TimeInterval = 1_700_000_000) throws -> NativeReadClient {
        NativeReadClient(configuration: try configuration(), transport: transport, vault: vault, now: { Date(timeIntervalSince1970: time) })
    }
    private func signIn(_ client: NativeReadClient) async throws {
        try await client.signIn(email: "person@example.test", password: "synthetic-password")
    }
    func testDefaultTransportCannotConnect() async throws {
        let client = NativeReadClient(configuration: try configuration(), vault: MemorySessionVault())
        do { try await signIn(client); XCTFail("Must remain closed") }
        catch { XCTAssertEqual(error as? ConnectionError, .approvalRequired) }
    }
    func testConfigurationRejectsUnsafeOriginsAndHeaderInjection() throws {
        for origin in ["http://fixture.invalid", "https://user:pass@fixture.invalid", "https://fixture.invalid/path", "https://fixture.invalid?x=1", "https://fixture.invalid#x"] {
            XCTAssertThrowsError(try ReadBackendConfiguration(origin: URL(string: origin)!, publicKey: "synthetic"))
        }
        XCTAssertThrowsError(try ReadBackendConfiguration(origin: URL(string: "https://fixture.invalid")!, publicKey: "bad\r\nkey"))
        XCTAssertEqual(String(describing: try configuration()), "ReadBackendConfiguration(redacted)")
    }
    func testSignInRequestAndVerifiedMembershipNotChosenRole() async throws {
        let transport = FixtureReadTransport()
        let vault = MemorySessionVault()
        let client = try client(transport, vault: vault)
        try await signIn(client)
        let membership = try await client.memberships()
        XCTAssertEqual(membership.first?.knownRole, .admin)
        XCTAssertNil(membership.first?.displayName)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/auth/v1/token", "/auth/v1/user", "/rest/v1/household_members"])
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
        XCTAssertFalse(String(data: try XCTUnwrap(vault.load()), encoding: .utf8)!.contains("synthetic-password"))
        let session = try JSONDecoder().decode(NativeAuthSession.self, from: authData())
        XCTAssertEqual(String(reflecting: session), "NativeAuthSession(redacted)")
    }
    func testInvalidCredentialsNeverReachTransport() async throws {
        let transport = FixtureReadTransport()
        let client = try client(transport)
        do { try await client.signIn(email: "bad", password: "short"); XCTFail() } catch {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
    func testUnknownRoleVisibleButCannotAuthorizeReads() async throws {
        let transport = FixtureReadTransport()
        await transport.setRole("future-role")
        let client = try client(transport)
        try await signIn(client)
        let memberships = try await client.memberships()
        XCTAssertEqual(memberships.first?.role, "future-role")
        XCTAssertNil(memberships.first?.knownRole)
        do { _ = try await client.week(household: householdUUID); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .forbidden) }
    }
    func testForeignMembershipIdentityRejected() async throws {
        let transport = FixtureReadTransport()
        await transport.setMemberUser("33333333-3333-4333-8333-333333333333")
        let client = try client(transport)
        try await signIn(client)
        do { _ = try await client.memberships(); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .identityChanged) }
    }
    func testForeignHouseholdNeverRequested() async throws {
        let transport = FixtureReadTransport()
        let client = try client(transport)
        try await signIn(client)
        do { _ = try await client.page(.transactions, household: UUID()); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .forbidden) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/rest/v1/transactions" })
    }
    func testWeekPreservesNullAndUnknownWithoutComputingDebt() async throws {
        let transport = FixtureReadTransport()
        let client = try client(transport)
        try await signIn(client)
        let week = try await client.week(household: householdUUID)
        XCTAssertEqual(week.availableCents, .null)
        XCTAssertEqual(week.carriedDebtCents, .value(123))
        XCTAssertEqual(week.raw.field("outgoing_debt_cents"), .missing)
        XCTAssertEqual(week.raw.field("future"), .value(.bool(true)))
        let captured = await transport.requests
        let request = try XCTUnwrap(captured.last)
        XCTAssertEqual(request.url?.path, "/functions/v1/compute-week")
        XCTAssertEqual(request.httpMethod, "POST")
        let payload = try JSONDecoder().decode(APIRecord.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(payload.field("household_id"), .value(.string(householdUUID.uuidString)))
        XCTAssertEqual(payload.field("D"), .missing)
    }
    func testPagesUseExplicitColumnsRangeAndDoNotClaimComplete() async throws {
        let transport = FixtureReadTransport()
        await transport.setupPage("[{\"id\":\"row\",\"household_id\":\"\(syntheticHousehold)\",\"amount_cents\":null}]", range: "0-0/3")
        let client = try client(transport)
        try await signIn(client)
        let page = try await client.page(.fundLedger, household: householdUUID, limit: 1)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.nextOffset, 1)
        XCTAssertEqual(page.rows[0].field("amount_cents"), .null)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "0-0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "count=exact")
        XCTAssertFalse(request.url!.absoluteString.contains("select=*"))
    }
    func testInvalidRangesNeverBecomeCompleteEmptyLists() async throws {
        for range in ["*/unknown", "0-0/*", "1-1/2", "*/1"] {
            let transport = FixtureReadTransport()
            await transport.setupPage("[]", range: range)
            let client = try client(transport)
            try await signIn(client)
            do { _ = try await client.page(.transactions, household: householdUUID); XCTFail(range) }
            catch { XCTAssertEqual(error as? ConnectionError, .incompletePage) }
        }
    }
    func testCrossHouseholdResponseRowsRejected() async throws {
        let transport = FixtureReadTransport()
        await transport.setupPage("[{\"household_id\":\"33333333-3333-4333-8333-333333333333\"}]", range: "0-0/1")
        let client = try client(transport)
        try await signIn(client)
        do { _ = try await client.page(.transactions, household: householdUUID); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .forbidden) }
    }
    func testEveryRelationUsesGETAndExcludesVaultMailAndMutationEndpoints() async throws {
        let transport = FixtureReadTransport()
        let client = try client(transport)
        try await signIn(client)
        for relation in ReadRelation.allCases { _ = try await client.page(relation, household: householdUUID) }
        let requests = await transport.requests
        XCTAssertTrue(requests.filter { $0.url!.path.hasPrefix("/rest/") }.allSatisfy { $0.httpMethod == "GET" })
        for forbidden in ["week-close", "plaid-sync", "delete-account", "gmail", "/rpc/", "/plaid_items?"] {
            XCTAssertFalse(requests.contains { $0.url!.absoluteString.contains(forbidden) })
        }
    }
    func testHTTPFailuresSanitizedWithoutAutomaticRetry() async throws {
        for (status, expected) in [(401, ConnectionError.unauthorized), (403, .forbidden), (429, .failed(429)), (500, .failed(500))] {
            let transport = FixtureReadTransport()
            await transport.setStatus(status)
            let client = try client(transport)
            do { try await signIn(client); XCTFail() }
            catch { XCTAssertEqual(error as? ConnectionError, expected); XCTAssertFalse(error.localizedDescription.contains("sensitive")) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }
    func testExpiredSessionRestoresByRefreshingAndValidatingIdentity() async throws {
        let transport = FixtureReadTransport()
        let vault = MemorySessionVault()
        vault.save(try savedSession(expiry: 1_600_000_000))
        let client = try client(transport, vault: vault)
        try await client.restore()
        let requests = await transport.requests
        XCTAssertTrue(requests[0].url!.query!.contains("grant_type=refresh_token"))
        XCTAssertEqual(requests[1].url?.path, "/auth/v1/user")
        try await client.signOutLocally()
        XCTAssertNil(vault.load())
        do { _ = try await client.validatedUser(); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .unauthorized) }
    }
    func testRefreshCannotChangeUser() async throws {
        let transport = FixtureReadTransport()
        await transport.setRefreshUser("33333333-3333-4333-8333-333333333333")
        let vault = MemorySessionVault()
        vault.save(try savedSession(expiry: 1_600_000_000))
        let client = try client(transport, vault: vault)
        do { try await client.restore(); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .identityChanged) }
        XCTAssertNil(vault.load())
    }
    func testCancelledSignInNeverSendsRequestOrPersists() async throws {
        let transport = FixtureReadTransport()
        let vault = MemorySessionVault()
        let client = try client(transport, vault: vault)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.signIn(email: "person@example.test", password: "synthetic-password")
        }
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(vault.load())
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
}

@MainActor
final class NativeReadStoreTests: XCTestCase {
    func testDefaultStoreLockedAndNoSampleFallback() async {
        let store = NativeReadStore()
        XCTAssertFalse(store.configured)
        await store.signIn(email: "person@example.test", password: "synthetic-password")
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.signedIn)
        XCTAssertTrue(store.memberships.isEmpty)
        XCTAssertNil(store.week)
    }
    func testExplicitSelectionReadAndLogoutIsolation() async throws {
        let transport = FixtureReadTransport()
        let config = try ReadBackendConfiguration(origin: URL(string: "https://fixture.invalid")!, publicKey: "synthetic-public-key")
        let client = NativeReadClient(configuration: config, transport: transport, vault: MemorySessionVault())
        let store = NativeReadStore(client: client)
        await store.signIn(email: "person@example.test", password: "synthetic-password")
        XCTAssertTrue(store.signedIn)
        XCTAssertNil(store.selectedHousehold)
        store.select(UUID())
        XCTAssertNil(store.selectedHousehold)
        store.select(householdUUID)
        await store.loadWeek()
        XCTAssertNotNil(store.week)
        await store.signOut()
        XCTAssertFalse(store.signedIn)
        XCTAssertNil(store.week)
        XCTAssertNil(store.page)
        XCTAssertNil(store.selectedHousehold)
        XCTAssertTrue(store.memberships.isEmpty)
    }
}

extension NativeReadClientTests {
    func testConcurrentReadsShareOneRefresh() async throws {
        let transport = FixtureReadTransport()
        await transport.setExpiry(1_700_000_030)
        let client = try client(transport)
        try await signIn(client)
        try await withThrowingTaskGroup(of: NativeUser.self) { group in
            for _ in 0..<8 { group.addTask { try await client.validatedUser() } }
            for try await user in group { XCTAssertEqual(user.id.uuidString.lowercased(), syntheticUser) }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.query?.contains("grant_type=refresh_token") == true }.count, 1)
    }
    func testCorruptSavedSessionPurged() async throws {
        let vault = MemorySessionVault()
        vault.save(Data("invalid stored data".utf8))
        let client = try client(FixtureReadTransport(), vault: vault)
        do { try await client.restore(); XCTFail() } catch {}
        XCTAssertNil(vault.load())
    }
    func testLateSignInCannotRestoreAfterLocalLogout() async throws {
        let transport = PausedAuthTransport()
        let vault = MemorySessionVault()
        let client = NativeReadClient(configuration: try configuration(), transport: transport, vault: vault)
        let login = Task { try await client.signIn(email: "person@example.test", password: "synthetic-password") }
        await transport.waitUntilStarted()
        try await client.signOutLocally()
        await transport.finish()
        do { try await login.value; XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .identityChanged) }
        XCTAssertNil(vault.load())
    }
}
private actor PausedAuthTransport: ReadHTTPTransport {
    private var response: CheckedContinuation<ReadHTTPResponse, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func execute(_ request: URLRequest) async -> ReadHTTPResponse {
        await withCheckedContinuation { continuation in
            response = continuation; waiting?.resume(); waiting = nil
        }
    }
    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish() { response?.resume(returning: .init(status: 200, data: authData())); response = nil }
}

extension NativeReadClientTests {
    func testGuardedExecutorClosedBeforeAnyNetworkCall() async throws {
        let transport = try GuardedReadTransport(origin: URL(string: "https://fixture.invalid")!)
        do { _ = try await transport.execute(URLRequest(url: URL(string: "https://fixture.invalid/auth/v1/user")!)); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .approvalRequired) }
    }
    func testExecutorPolicyRejectsForeignOriginsAndAllFinancialWrites() throws {
        // Validate only; never execute a request with this test-only permission value.
        let transport = try GuardedReadTransport(origin: URL(string: "https://fixture.invalid")!, ownerApprovedConnection: true)
        for path in ["/functions/v1/week-close", "/functions/v1/delete-account", "/functions/v1/plaid-sync", "/functions/v1/gmail-poll", "/rest/v1/rpc/allocate_fund", "/rest/v1/transactions", "/auth/v1/signup", "/auth/v1/recover", "/auth/v1/logout"] {
            var request = URLRequest(url: URL(string: "https://fixture.invalid\(path)")!)
            request.httpMethod = "POST"
            XCTAssertThrowsError(try transport.validate(request))
        }
        for url in ["https://other.invalid/auth/v1/user", "http://fixture.invalid/auth/v1/user", "https://fixture.invalid:444/auth/v1/user", "https://fixture.invalid/rest/v1/plaid_items"] {
            XCTAssertThrowsError(try transport.validate(URLRequest(url: URL(string: url)!)))
        }
        for url in ["https://fixture.invalid/auth/v1/user", "https://fixture.invalid/rest/v1/transactions"] {
            XCTAssertNoThrow(try transport.validate(URLRequest(url: URL(string: url)!)))
        }
    }
}

extension NativeReadClientTests {
    func testConfigurationRejectsPrivilegedKeyKinds() throws {
        let origin = URL(string: "https://fixture.invalid")!
        XCTAssertThrowsError(try ReadBackendConfiguration(origin: origin, publicKey: "sb_secret_synthetic-not-a-real-key"))
        let payload = Data(#"{"role":"service_role"}"#.utf8).base64EncodedString()
        XCTAssertThrowsError(try ReadBackendConfiguration(origin: origin, publicKey: "synthetic.\(payload).synthetic"))
    }
}

extension NativeReadClientTests {
    func testSavedTokensNeverSentToDifferentOrigin() async throws {
        let transport = FixtureReadTransport()
        let vault = MemorySessionVault()
        vault.save(try savedSession(expiry: 4_102_444_800, origin: "https://other.invalid"))
        let client = try client(transport, vault: vault)
        do { try await client.restore(); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionError, .invalidConfiguration) }
        XCTAssertNil(vault.load())
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
}

extension NativeReadStoreTests {
    func testFailedRefreshDoesNotDisplayPriorSummaryAsCurrent() async throws {
        let transport = FixtureReadTransport()
        let config = try ReadBackendConfiguration(origin: URL(string: "https://fixture.invalid")!, publicKey: "synthetic-public-key")
        let client = NativeReadClient(configuration: config, transport: transport, vault: MemorySessionVault())
        let store = NativeReadStore(client: client)
        await store.signIn(email: "person@example.test", password: "synthetic-password")
        store.select(householdUUID)
        await store.loadWeek()
        XCTAssertNotNil(store.week)
        await transport.setStatus(500)
        await store.loadWeek()
        XCTAssertNil(store.week)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.loading)
        XCTAssertFalse(store.error!.contains("sensitive"))
    }
}
