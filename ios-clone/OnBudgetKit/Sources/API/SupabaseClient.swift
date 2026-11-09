// OnBudgetKit — SupabaseClient.swift
//
// Supabase Auth via the GoTrue REST API (no supabase-swift dependency —
// the package is Foundation-only so it compiles on Linux CI too).
// The web app uses supabase-js (`createClient`, live.js:27-34); the
// endpoints below are the exact HTTP calls that library makes.
//
//   sign-up:    POST /auth/v1/signup            {email, password, data:{full_name}}
//   sign-in:    POST /auth/v1/token?grant_type=password
//   refresh:    POST /auth/v1/token?grant_type=refresh_token
//   sign-out:   POST /auth/v1/logout
//   reset:      POST /auth/v1/recover           {email, redirect_to?}
//   get user:   GET  /auth/v1/user
//   update:     PUT  /auth/v1/user              {password | email | data:{full_name}}
//
// Base URL and anon key come from `config.js` (origin/main): the
// publishable key is already public in the web app by design. The
// service-role key must NEVER appear anywhere in this package.
//
// Session persistence: `SessionStore` is a protocol. The shipped
// default stores the session JSON in UserDefaults; the app SHOULD
// swap in a Keychain-backed store before shipping (one-line swap —
// see `KeychainSessionStore` note below). Tokens are never logged.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Configuration

/// Connection constants. The anon key is the publishable client key
/// from `config.js` — public by design, enforced by RLS + Edge
/// Functions, not by key secrecy.
public struct SupabaseConfiguration: Equatable, Sendable {
    /// The live backend. URL + anon key come from the scaffold's
    /// `Configuration` (Sources/OnBudgetKit/Configuration.swift) —
    /// the publishable client key from `config.js`, public by design.
    /// Do not duplicate the values here.
    public static let live = SupabaseConfiguration(
        baseURL: URL(string: Configuration.supabaseURL)!,
        anonKey: Configuration.supabaseAnonKey
    )

    public let baseURL: URL
    public let anonKey: String
    /// Per-request timeout. A request that exceeds it fails as
    /// `.timedOut` — it never spins forever (see Errors.swift).
    public let requestTimeoutSeconds: TimeInterval
    /// Refresh the access token this far before it expires.
    public let refreshLeewaySeconds: TimeInterval

    public init(
        baseURL: URL,
        anonKey: String,
        requestTimeoutSeconds: TimeInterval = 30,
        refreshLeewaySeconds: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.refreshLeewaySeconds = refreshLeewaySeconds
    }

    var authBaseURL: URL { baseURL.appendingPathComponent("auth/v1") }
    var restBaseURL: URL { baseURL.appendingPathComponent("rest/v1") }
    var functionsBaseURL: URL { baseURL.appendingPathComponent("functions/v1") }
}

// MARK: - Session

/// A GoTrue session. `expiresAt` is computed from `expires_in` at
/// decode time; the raw `expires_at` unix field is honoured when present.
public struct AuthSession: Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let expiresAt: Date
    public let user: AuthUser

    public var isExpired: Bool { Date() >= expiresAt }
    /// True when the token expires within the refresh leeway.
    public func needsRefresh(leewaySeconds: TimeInterval) -> Bool {
        Date().addingTimeInterval(leewaySeconds) >= expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAtUnix = "expires_at"
        case user
    }

    public init(accessToken: String, refreshToken: String, tokenType: String, expiresAt: Date, user: AuthUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.user = user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decode(String.self, forKey: .refreshToken)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "bearer"
        self.user = try container.decode(AuthUser.self, forKey: .user)
        if let unix = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresAtUnix) {
            self.expiresAt = Date(timeIntervalSince1970: unix)
        } else if let seconds = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) {
            self.expiresAt = Date().addingTimeInterval(seconds)
        } else {
            // No expiry advertised: treat as already stale so the next
            // call refreshes rather than trusting an unknown lifetime.
            self.expiresAt = Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(tokenType, forKey: .tokenType)
        try container.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAtUnix)
        try container.encode(user, forKey: .user)
    }
}

/// The signed-in user. `userMetadata` carries `full_name` / `name`
/// (the web app stores the display name in auth metadata only —
/// live.js:538-540, 3367-3370).
public struct AuthUser: Equatable, Codable {
    public let id: UUID
    public let email: String?
    public let userMetadata: [String: String]

    /// First the `full_name` metadata, then `name`, then nothing —
    /// the caller falls back to the email (live.js:544-548).
    public var displayName: String? {
        userMetadata["full_name"] ?? userMetadata["name"]
    }

    enum CodingKeys: String, CodingKey {
        case id, email
        case userMetadata = "user_metadata"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        // Metadata values are strings in practice; tolerate any JSON
        // scalar by decoding as [String: AnyDecodable] would be
        // overkill — fall back to empty on a non-string value.
        self.userMetadata = (try? container.decode([String: String].self, forKey: .userMetadata)) ?? [:]
    }

    public init(id: UUID, email: String?, userMetadata: [String: String] = [:]) {
        self.id = id
        self.email = email
        self.userMetadata = userMetadata
    }
}

/// The outcome of a sign-up attempt. Email confirmation is OFF in
/// the live project (HANDOFF.md §4), so sign-up normally returns a
/// session immediately — but the `.needsConfirmation` case covers a
/// future flip of that setting instead of failing mysteriously.
public enum SignUpOutcome {
    case signedIn(AuthSession)
    case needsConfirmation
}

/// Where a session is persisted. The default implementation below
/// uses UserDefaults; swap it for a Keychain-backed store in the app
/// target before shipping — the client only ever talks to this
/// protocol, so the swap is a single initializer argument.
public protocol SessionStore: AnyObject {
    func load() -> AuthSession?
    func save(_ session: AuthSession?)
}

/// UserDefaults-backed store (default). Key is versioned so a future
/// store migration can be detected.
public final class UserDefaultsSessionStore: SessionStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "onbudget.supabase.session.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AuthSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession?) {
        if let session {
            let data = try? JSONEncoder().encode(session)
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory store, for tests and for callers that manage persistence
/// themselves.
public final class InMemorySessionStore: SessionStore {
    private var stored: AuthSession?
    private let lock = NSLock()

    public init() {}

    public func load() -> AuthSession? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ session: AuthSession?) {
        lock.lock(); defer { lock.unlock() }
        stored = session
    }
}

// MARK: - Transport

/// A single HTTP round-trip. `URLSessionTransport` below is the real
/// implementation; tests assert on the `URLRequest` builders instead
/// of going through the network.
public protocol HTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport built on a completion-handler data task
/// (deliberately not `URLSession.data(for:)` — the continuation form
/// compiles identically on Linux and Apple platforms).
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error as? URLError {
                    continuation.resume(throwing: OnBudgetError.fromURLError(error))
                    return
                }
                if let error {
                    continuation.resume(throwing: OnBudgetError.networkError(error.localizedDescription))
                    return
                }
                guard let data, let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: OnBudgetError.unknown("No response from the server."))
                    return
                }
                continuation.resume(returning: (data, httpResponse))
            }
            task.resume()
        }
    }
}

// MARK: - Auth client

/// Supabase Auth (GoTrue REST) plus the session the rest of the API
/// layer authenticates with. Owns:
///   - sign-up / sign-in / sign-out
///   - password reset request (email link) and password change
///   - profile name / email update
///   - session persistence + refresh, and "sign-in expired" detection
///
/// All other clients (`PostgrestClient`, `RPCClient`,
/// `EdgeFunctionsClient`) authenticate through `validAccessToken()`,
/// so a 401 anywhere in the app funnels through the same refresh +
/// expiry path.
///
/// Thread-safety: the stored session and the in-flight refresh task
/// are guarded by a lock; concurrent callers coalesce onto one
/// refresh instead of racing the refresh-token endpoint.
/// The class is `@unchecked Sendable` because that mutable state is
/// only ever touched under `lock` (the `lazy` API clients are
/// created once and then read-only).
public final class SupabaseClient: @unchecked Sendable {
    public let configuration: SupabaseConfiguration
    public let store: SessionStore
    private let transport: HTTPTransport

    private let lock = NSLock()
    private var _session: AuthSession?
    private var refreshBox: RefreshTaskBox?

    /// The API clients, authenticated through this client's session.
    /// Screens use these — e.g. `client.postgrest.transactionsPage(…)`.
    public lazy var postgrest: PostgrestClient = PostgrestClient(
        configuration: configuration,
        tokenProvider: { [weak self] in
            guard let self else { throw OnBudgetError.sessionExpired }
            return try await self.validAccessToken()
        },
        transport: transport
    )
    public lazy var rpcs: RPCClient = RPCClient(
        configuration: configuration,
        tokenProvider: { [weak self] in
            guard let self else { throw OnBudgetError.sessionExpired }
            return try await self.validAccessToken()
        },
        transport: transport
    )
    public lazy var functions: EdgeFunctionsClient = EdgeFunctionsClient(
        configuration: configuration,
        tokenProvider: { [weak self] in
            guard let self else { throw OnBudgetError.sessionExpired }
            return try await self.validAccessToken()
        },
        transport: transport
    )

    public init(
        configuration: SupabaseConfiguration = .live,
        store: SessionStore? = nil,
        transport: HTTPTransport? = nil
    ) {
        self.configuration = configuration
        self.store = store ?? UserDefaultsSessionStore()
        self.transport = transport ?? URLSessionTransport()
        self._session = self.store.load()
    }

    // MARK: Session state

    /// The currently stored session, if any (may be expired).
    public var currentSession: AuthSession? {
        lock.lock(); defer { lock.unlock() }
        return _session
    }

    public var isSignedIn: Bool { currentSession != nil }

    /// A valid access token, refreshing first when the stored token is
    /// stale. Throws `.sessionExpired` when there is no session or the
    /// refresh is refused (bad/expired refresh token) — the caller
    /// must send the user to sign in again.
    public func validAccessToken() async throws -> String {
        let session = currentSession
        guard let session else { throw OnBudgetError.sessionExpired }
        if !session.needsRefresh(leewaySeconds: configuration.refreshLeewaySeconds) {
            return session.accessToken
        }
        return try await refreshAccessToken()
    }

    /// Force a refresh even when the token looks fresh (used after a
    /// 401, mirroring the web client's getSession re-check).
    public func refreshAccessToken() async throws -> String {
        let box: RefreshTaskBox = lock.synchronized {
            if let existing = refreshBox { return existing }
            let created = RefreshTaskBox(Task<String, Error> { [weak self] in
                guard let self else { throw OnBudgetError.sessionExpired }
                let newSession = try await self.performRefresh()
                self.setSession(newSession)
                return newSession.accessToken
            })
            refreshBox = created
            return created
        }
        do {
            let token = try await box.task.value
            lock.synchronized { if refreshBox === box { refreshBox = nil } }
            return token
        } catch {
            lock.synchronized { if refreshBox === box { refreshBox = nil } }
            throw error
        }
    }

    private func setSession(_ session: AuthSession?) {
        lock.synchronized { _session = session }
        store.save(session)
    }

    // MARK: - Auth flows

    /// Sign in with email + password (live.js:2412-2438). A wrong
    /// email/password maps to `.validationFailed("Incorrect email or
    /// password")` — never naming which field was wrong.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> AuthSession {
        let body: [String: Any] = ["email": email, "password": password]
        let request = try Self.authRequest(
            configuration: configuration,
            path: "token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            method: "POST",
            accessToken: nil,
            jsonBody: body
        )
        let session: AuthSession = try await performAuthRequest(request)
        setSession(session)
        return session
    }

    /// Create an account. The name is REQUIRED by the app (live.js
    /// sign-up name step, Nov 4): it is stored as auth metadata
    /// `full_name` at sign-up time, never as a separate call.
    /// The live project has email confirmation OFF, so this normally
    /// returns `.signedIn`; `.needsConfirmation` covers the setting
    /// being turned back on.
    public func signUp(email: String, password: String, fullName: String) async throws -> SignUpOutcome {
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "data": ["full_name": fullName],
        ]
        let request = try Self.authRequest(
            configuration: configuration,
            path: "signup",
            method: "POST",
            accessToken: nil,
            jsonBody: body
        )
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
        // With confirmation on, GoTrue returns a user with no session.
        if let session = try? JSONDecoder().decode(AuthSession.self, from: data),
           !session.accessToken.isEmpty {
            setSession(session)
            return .signedIn(session)
        }
        return .needsConfirmation
    }

    /// Sign out. The local session is cleared even if the network call
    /// fails — a sign-out must never leave credentials behind on a
    /// shared device (live.js:2601-2615).
    public func signOut() async {
        if let token = currentSession?.accessToken {
            let request = try? Self.authRequest(
                configuration: configuration,
                path: "logout",
                method: "POST",
                accessToken: token,
                jsonBody: [:]
            )
            if let request { _ = try? await transport.send(request) }
        }
        setSession(nil)
    }

    /// Request a password-reset email (live.js:2399-2410). The reply
    /// wording is deliberately generic either way — it must not reveal
    /// whether an account exists for the address.
    /// - Parameter redirectTo: the allow-listed URL the reset link
    ///   returns to. The web app uses its `reset.html` page; the
    ///   native app must pass its own allow-listed deep link (or nil
    ///   to use the project's Site URL). The reset page then completes
    ///   the flow with `updateUser(password:)` while the recovery
    ///   session is active (see `reset.html:43-67`).
    public func requestPasswordReset(email: String, redirectTo: URL? = nil) async throws {
        var body: [String: Any] = ["email": email]
        if let redirectTo { body["redirect_to"] = redirectTo.absoluteString }
        let request = try Self.authRequest(
            configuration: configuration,
            path: "recover",
            method: "POST",
            accessToken: nil,
            jsonBody: body
        )
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
    }

    /// Exchange a PKCE recovery code from a password-reset deep link
    /// for a session (`reset.html:43-67` calls
    /// `exchangeCodeForSession(code)`). The native reset link is
    /// `onbudget://reset-password?code=…` (see AppDeepLinks). A bad
    /// code throws; the caller shows "This reset link could not be
    /// used. Request a new one from the sign-in screen."
    @discardableResult
    public func exchangeRecoveryCode(_ code: String) async throws -> AuthSession {
        let body: [String: Any] = ["auth_code": code]
        let request = try Self.authRequest(
            configuration: configuration,
            path: "token",
            queryItems: [URLQueryItem(name: "grant_type", value: "pkce")],
            method: "POST",
            accessToken: nil,
            jsonBody: body
        )
        let session: AuthSession = try await performAuthRequest(request)
        setSession(session)
        return session
    }

    /// Adopt a recovery session from a hash-style link
    /// (`#access_token=…&refresh_token=…`): fetch the user with the
    /// supplied token and store the resulting session, so
    /// `changePassword(_:)` can run as the recovering user.
    public func adoptRecoverySession(accessToken: String, refreshToken: String, expiresIn: TimeInterval) async throws {
        let request = try Self.authRequest(
            configuration: configuration,
            path: "user",
            method: "GET",
            accessToken: accessToken,
            jsonBody: nil
        )
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
        do {
            let user = try JSONDecoder().decode(AuthUser.self, from: data)
            setSession(AuthSession(
                accessToken: accessToken, refreshToken: refreshToken,
                tokenType: "bearer",
                expiresAt: Date().addingTimeInterval(expiresIn), user: user))
        } catch {
            throw OnBudgetError.decodingError("Could not read the signed-in user.")
        }
    }

    /// Change the password for the signed-in user (live.js:3342-3355).
    /// Minimum 8 characters — enforced by the caller before this call,
    /// matching the web UI.
    public func changePassword(_ newPassword: String) async throws {
        _ = try await updateUser(["password": newPassword])
    }

    /// Save the profile display name (auth metadata only — no SQL,
    /// live.js:3367-3379).
    @discardableResult
    public func updateDisplayName(_ name: String) async throws -> AuthUser {
        try await updateUser(["data": ["full_name": name]])
    }

    /// Change the sign-in email. A confirmation goes to the NEW
    /// address; the sign-in email does not change until it is
    /// confirmed (live.js:3381-3395).
    @discardableResult
    public func updateEmail(_ email: String) async throws -> AuthUser {
        try await updateUser(["email": email])
    }

    /// Re-read the current user from GoTrue (live.js:372, 497).
    public func getUser() async throws -> AuthUser {
        let token = try await validAccessToken()
        let request = try Self.authRequest(
            configuration: configuration,
            path: "user",
            method: "GET",
            accessToken: token,
            jsonBody: nil
        )
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(AuthUser.self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the signed-in user.")
        }
    }

    /// Delete the account via the `delete-account` Edge Function, then
    /// sign out locally. The function deletes the user and — when the
    /// caller is the last member — the household too; it is all-or-
    /// nothing per step (live.js:3324-3340, delete-account/index.ts).
    /// The UI must confirm twice before calling this.
    public func deleteAccount() async throws {
        _ = try await functions.deleteAccount()
        setSession(nil)
    }

    // MARK: - Internals

    private func updateUser(_ fields: [String: Any]) async throws -> AuthUser {
        let token = try await validAccessToken()
        let request = try Self.authRequest(
            configuration: configuration,
            path: "user",
            method: "PUT",
            accessToken: token,
            jsonBody: fields
        )
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
        do {
            let user = try JSONDecoder().decode(AuthUser.self, from: data)
            // Keep the stored session's user in sync with the update.
            if let session = currentSession {
                let updated = AuthSession(
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken,
                    tokenType: session.tokenType,
                    expiresAt: session.expiresAt,
                    user: user
                )
                setSession(updated)
            }
            return user
        } catch {
            throw OnBudgetError.decodingError("Could not read the updated user.")
        }
    }

    private func performRefresh() async throws -> AuthSession {
        guard let refreshToken = currentSession?.refreshToken else {
            throw OnBudgetError.sessionExpired
        }
        let body: [String: Any] = ["refresh_token": refreshToken]
        let request = try Self.authRequest(
            configuration: configuration,
            path: "token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            method: "POST",
            accessToken: nil,
            jsonBody: body
        )
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            // A refused refresh means the session is dead: clear it so
            // the app does not keep retrying a dead token.
            if response.statusCode == 401 || response.statusCode == 400 {
                setSession(nil)
                throw OnBudgetError.sessionExpired
            }
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the refreshed session.")
        }
    }

    private func performAuthRequest(_ request: URLRequest) async throws -> AuthSession {
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromAuthResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the session.")
        }
    }

    /// Build a GoTrue request. Pure (no network) so tests can assert
    /// on method, URL, headers, and body.
    static func authRequest(
        configuration: SupabaseConfiguration,
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        accessToken: String?,
        jsonBody: [String: Any]?
    ) throws -> URLRequest {
        // appendingPathComponent (never relative-URL resolution: a base
        // of “…/auth/v1” would resolve “token” to “…/auth/token”).
        var components = URLComponents(
            url: configuration.authBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else {
            throw OnBudgetError.unknown("Invalid auth URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }
        return request
    }
}

/// Identity box for the in-flight refresh task (Task itself is a
/// struct and has no identity to compare).
private final class RefreshTaskBox {
    let task: Task<String, Error>
    init(_ task: Task<String, Error>) { self.task = task }
}

// MARK: - NSLock convenience

private extension NSLock {
    /// Named `synchronized` (not `withLock`) so it can never clash
    /// with an SDK-provided `withLock` on NSLock.
    func synchronized<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
