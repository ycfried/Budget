import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ConnectionError: Error, LocalizedError, Equatable, Sendable {
    case approvalRequired, invalidConfiguration, invalidResponse, unauthorized, forbidden, failed(Int), incompletePage, identityChanged
    public var errorDescription: String? {
        switch self {
        case .approvalRequired: "The first live connection has not been approved."
        case .invalidConfiguration: "The approved backend configuration is missing or invalid."
        case .invalidResponse: "The server response could not be verified."
        case .unauthorized: "Sign in again to continue."
        case .forbidden: "This account cannot read the requested household."
        case .failed: "The request failed. No automatic retry was made."
        case .incompletePage: "The server did not confirm that this page is complete."
        case .identityChanged: "The session changed. Discard this result."
        }
    }
}

/// Runtime-only values. Never load configuration from the existing web app.
public struct ReadBackendConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let origin: URL
    fileprivate let publicKey: String
    public init(origin: URL, publicKey: String) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, ["", "/"].contains(origin.path),
              !publicKey.isEmpty, !publicKey.hasPrefix("sb_secret_"),
              !publicKey.contains("\n"), !publicKey.contains("\r") else { throw ConnectionError.invalidConfiguration }
        let parts = publicKey.split(separator: ".")
        if parts.count == 3 {
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload),
                  let fields = try? JSONDecoder().decode(APIRecord.self, from: data),
                  fields.field("role") == .value(.string("anon")) else { throw ConnectionError.invalidConfiguration }
        }
        self.origin = origin; self.publicKey = publicKey
    }
    public var description: String { "ReadBackendConfiguration(redacted)" }
    public var debugDescription: String { description }
}
public struct ReadHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let contentRange: String?
    public init(status: Int, data: Data, contentRange: String? = nil) { self.status = status; self.data = data; self.contentRange = contentRange }
}
public protocol ReadHTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> ReadHTTPResponse
}

/// Default transport is closed. A later approval must explicitly change app
/// composition before the guarded URLSession executor can send an Auth request.
public struct ClosedLiveTransport: ReadHTTPTransport {
    public init() {}
    public func execute(_ request: URLRequest) async throws -> ReadHTTPResponse { throw ConnectionError.approvalRequired }
}

public struct NativeAuthSession: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let accessToken: String
    fileprivate let refreshToken: String
    public let expiresAt: TimeInterval
    public let user: NativeUser
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", user }
    public var description: String { "NativeAuthSession(redacted)" }
    public var debugDescription: String { description }
}
private struct StoredNativeSession: Codable {
    let origin: URL
    let session: NativeAuthSession
}
public struct NativeUser: Codable, Equatable, Sendable {
    public let id: UUID
}
public struct NativeMembership: Codable, Equatable, Sendable {
    public let householdID: UUID
    public let userID: UUID
    /// Unknown role preserved; never grants admin by default.
    public let role: String
    public let displayName: String?
    enum CodingKeys: String, CodingKey { case householdID = "household_id", userID = "user_id", role, displayName = "display_name" }
    public var knownRole: Role? { Role(rawValue: role) }
}
public protocol NativeSessionVault: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}
/// Tests and explicitly ephemeral sessions only. The app never substitutes this for Keychain.
public final class MemorySessionVault: NativeSessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init() {}
    public func load() -> Data? { lock.withLock { data } }
    public func save(_ value: Data) { lock.withLock { data = value } }
    public func clear() { lock.withLock { data = nil } }
}

public enum ReadRelation: String, CaseIterable, Sendable {
    case households, transactions, fundRequests = "fund_requests", fundLedger = "fund_ledger"
    case savingsLedger = "savings_ledger", weekCloses = "week_closes", surplusReleases = "surplus_releases"
    case restorations = "restoration_entries", heldRefunds = "held_refunds", audit = "audit_log"
    case temporaryIncreases = "temp_increases", bankItems = "plaid_items_public", bankAccounts = "plaid_accounts"
    // Gmail metadata is excluded from the first connection scope.
    var columns: String {
        switch self {
        case .households: "id,name,base_allowance_cents,fund_shortfall_cents,created_at"
        case .transactions: "id,household_id,date,merchant,amount_cents,card_suffix,source,state,kind,excluded,pre_exclusion_state,original_purchase_id,fund_allocation_cents,late,created_at"
        case .fundRequests: "id,household_id,transaction_id,requested_by,amount_cents,note,status,decided_by,decided_at,remainder_cents,created_at"
        case .fundLedger: "id,household_id,kind,amount_cents,week_start,request_id,note,created_by,created_at"
        case .savingsLedger: "id,household_id,kind,amount_cents,attested_by,note,actual_balance_cents,created_at"
        case .weekCloses: "id,household_id,week_start,surplus_cents,outgoing_debt_cents,base_allowance_cents,temp_increase_cents,late_adjustment_cents,created_at"
        case .surplusReleases: "id,household_id,week_start,surplus_cents,released_cents,status,release_date,created_at"
        case .restorations: "id,household_id,week_start,purchase_transaction_id,refund_transaction_id,restored_surplus_cents,debt_reduction_cents,fund_credit_cents,created_at"
        case .heldRefunds: "id,household_id,refund_transaction_id,purchase_transaction_id,held_cents,status,resolution_note,resolved_at,created_at"
        case .audit: "id,household_id,actor,actor_name,action,detail,created_at"
        case .temporaryIncreases: "id,household_id,week_start,amount_cents,note,created_by,created_at"
        case .bankItems: "id,household_id,institution_name,status,last_sync_at,created_at"
        case .bankAccounts: "id,household_id,name,mask,type,subtype,updated_at,created_at"
        }
    }
}
public struct NativeReadPage: Sendable {
    public let rows: [APIRecord]
    public let total: Int
    public let nextOffset: Int?
}

/// Authenticated READ adapter only. No financial mutation, provider, RPC,
/// account-deletion, signup or password-recovery entry point exists here.
public actor NativeReadClient {
    private let configuration: ReadBackendConfiguration
    private let transport: any ReadHTTPTransport
    private let vault: any NativeSessionVault
    private let now: @Sendable () -> Date
    private var session: NativeAuthSession?
    private var generation = 0
    private var authenticating = false
    private var refresh: Task<NativeAuthSession, any Error>?
    public init(configuration: ReadBackendConfiguration, transport: any ReadHTTPTransport = ClosedLiveTransport(),
                vault: any NativeSessionVault, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.transport = transport; self.vault = vault; self.now = now
    }
    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], token: String? = nil, body: Data? = nil) throws -> URLRequest {
        var components = URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false)!
        components.path = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ConnectionError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue(configuration.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    private func execute(_ request: URLRequest) async throws -> ReadHTTPResponse {
        try Task.checkCancellation()
        let response = try await transport.execute(request)
        try Task.checkCancellation()
        guard response.data.count <= 2_000_000 else { throw ConnectionError.invalidResponse }
        switch response.status {
        case 200...299: return response
        case 401: throw ConnectionError.unauthorized
        case 403: throw ConnectionError.forbidden
        default: throw ConnectionError.failed(response.status)
        }
    }
    public func signIn(email: String, password: String) async throws {
        _ = try Credentials(email: email, password: password)
        guard !authenticating, session == nil else { throw ConnectionError.invalidResponse }
        authenticating = true
        let current = generation
        defer { if generation == current { authenticating = false } }
        let body = try JSONEncoder().encode(["email": email, "password": password])
        let response = try await execute(request("/auth/v1/token", method: "POST", query: [.init(name: "grant_type", value: "password")], body: body))
        let value = try JSONDecoder().decode(NativeAuthSession.self, from: response.data)
        try accept(value, generation: current)
    }
    private func accept(_ value: NativeAuthSession, generation current: Int) throws {
        guard generation == current, !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
              value.expiresAt > now().timeIntervalSince1970 else { throw ConnectionError.identityChanged }
        try vault.save(JSONEncoder().encode(StoredNativeSession(origin: configuration.origin, session: value)))
        guard generation == current else { try vault.clear(); throw ConnectionError.identityChanged }
        session = value
    }
    public func restore() async throws {
        guard session == nil, !authenticating else { return }
        authenticating = true
        let current = generation
        defer { if generation == current { authenticating = false } }
        guard let data = try vault.load() else { return }
        guard generation == current else { throw ConnectionError.identityChanged }
        do {
            let stored = try JSONDecoder().decode(StoredNativeSession.self, from: data)
            guard stored.origin == configuration.origin else { throw ConnectionError.invalidConfiguration }
            session = stored.session
            _ = try await validatedUser()
        }
        catch { if generation == current { session = nil; try vault.clear() }; throw error }
    }
    private func token() async throws -> String {
        guard let value = session else { throw ConnectionError.unauthorized }
        if value.expiresAt > now().timeIntervalSince1970 + 60 { return value.accessToken }
        let current = generation
        let task: Task<NativeAuthSession, any Error>
        if let existing = refresh { task = existing }
        else {
            let request = try request("/auth/v1/token", method: "POST", query: [.init(name: "grant_type", value: "refresh_token")], body: JSONEncoder().encode(["refresh_token": value.refreshToken]))
            task = Task { let response = try await self.execute(request); return try JSONDecoder().decode(NativeAuthSession.self, from: response.data) }
            refresh = task
        }
        do {
            let renewed = try await task.value
            guard renewed.user.id == value.user.id else { throw ConnectionError.identityChanged }
            try accept(renewed, generation: current)
            if generation == current { refresh = nil }
            try Task.checkCancellation()
            return renewed.accessToken
        } catch {
            if generation == current { refresh = nil }
            throw error
        }
    }
    public func validatedUser() async throws -> NativeUser {
        let current = generation
        let response = try await execute(request("/auth/v1/user", token: try await token()))
        let user = try JSONDecoder().decode(NativeUser.self, from: response.data)
        guard generation == current, user.id == session?.user.id else { throw ConnectionError.identityChanged }
        return user
    }
    public func memberships() async throws -> [NativeMembership] {
        let user = try await validatedUser()
        let current = generation
        let response = try await execute(request("/rest/v1/household_members", query: [
            .init(name: "select", value: "household_id,user_id,role,display_name"),
            .init(name: "user_id", value: "eq.\(user.id.uuidString)")], token: try await token()))
        let rows = try JSONDecoder().decode([NativeMembership].self, from: response.data)
        guard generation == current, rows.allSatisfy({ $0.userID == user.id }) else { throw ConnectionError.identityChanged }
        return rows
    }
    private func authorize(_ household: UUID) async throws {
        let rows = try await memberships()
        guard rows.contains(where: { $0.householdID == household && $0.knownRole != nil }) else { throw ConnectionError.forbidden }
    }
    public func week(household: UUID, starting: PurchaseDate? = nil) async throws -> WeekSnapshotResponse {
        let current = generation
        try await authorize(household)
        let body = try JSONEncoder().encode(BackendContracts.ComputeWeekRequest(householdID: household.uuidString, weekStart: starting?.rawValue))
        let response = try await execute(request("/functions/v1/compute-week", method: "POST", token: try await token(), body: body))
        guard generation == current else { throw ConnectionError.identityChanged }
        return try JSONDecoder().decode(WeekSnapshotResponse.self, from: response.data)
    }
    public func page(_ relation: ReadRelation, household: UUID, offset: Int = 0, limit: Int = 100) async throws -> NativeReadPage {
        guard offset >= 0, (1...500).contains(limit), offset <= Int.max - limit else { throw ConnectionError.invalidResponse }
        let current = generation
        try await authorize(household)
        var request = try request("/rest/v1/\(relation.rawValue)", query: [
            .init(name: "select", value: relation.columns),
            .init(name: relation == .households ? "id" : "household_id", value: "eq.\(household.uuidString)"),
            .init(name: "order", value: "created_at.asc,id.asc")], token: try await token())
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        request.setValue("items", forHTTPHeaderField: "Range-Unit")
        request.setValue("\(offset)-\(offset + limit - 1)", forHTTPHeaderField: "Range")
        let response = try await execute(request)
        guard generation == current else { throw ConnectionError.identityChanged }
        let rows = try JSONDecoder().decode([APIRecord].self, from: response.data)
        guard let range = response.contentRange, let slash = range.lastIndex(of: "/"),
              let total = Int(range[range.index(after: slash)...]), total >= 0,
              rows.count <= limit, offset <= total, rows.count <= total - offset else { throw ConnectionError.incompletePage }
        let rangePart = String(range[..<slash])
        if rows.isEmpty {
            guard offset == total, rangePart == "*" else { throw ConnectionError.incompletePage }
        } else {
            guard rangePart == "\(offset)-\(offset + rows.count - 1)" else { throw ConnectionError.incompletePage }
        }
        for row in rows {
            let key = relation == .households ? "id" : "household_id"
            guard case .value(.string(let id)) = row.field(key), UUID(uuidString: id) == household else { throw ConnectionError.forbidden }
        }
        let next = offset + rows.count
        return NativeReadPage(rows: rows, total: total, nextOffset: next < total ? next : nil)
    }
    /// Local cleanup only: does not revoke server sessions or modify account data.
    public func signOutLocally() async throws {
        generation += 1; authenticating = false; session = nil; refresh?.cancel(); refresh = nil
        try vault.clear()
    }
}
