// OnBudgetKit — EdgeFunctions.swift
//
// Typed invocations for the Supabase Edge Functions
// (`POST <base>/functions/v1/<name>`), the same calls the web app
// makes with `callFn` (live.js:2766-2795):
//   headers: Content-Type application/json,
//            Authorization: Bearer <user JWT>, apikey: <anon key>
//   non-2xx → `{error, …}` + status; a network failure returns
//   `{error: "network error — check your connection", status: 0}`
//   instead of throwing out of the caller.
//
// Functions the client NEVER invokes (server-to-server only):
//   * `plaid-webhook` — Plaid calls it with a Plaid verification
//     header; the client only reads `webhook_events` afterwards.
//   * `gmail-oauth-callback` — Google redirects the browser to it
//     after consent; the client only opens the `auth_url` from
//     `gmail-oauth-start`.
//   * `ingest-amex-alert` — HMAC-signed server-to-server ingest
//     (household ingest secret). The response shape is modelled below
//     for reference only; there is no client invocation.
//   * `plaid-webhook` (again) and the cron-called paths of
//     `plaid-sync` / `gmail-poll` run with the service key; the
//     client paths below run with the user's JWT and their own
//     admin checks.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Response models

/// The failed-item fields of a plaid-sync 502 body
/// (`plaid-sync/index.ts:590`).
struct PlaidSync502Body: Decodable {
    let failedItems: [String]?
    let failedInstitutions: [String]?

    enum CodingKeys: String, CodingKey {
        case failedItems = "failed_items"
        case failedInstitutions = "failed_institutions"
    }
}

/// plaid-link: `{link_token, expiration}` (`plaid-link/index.ts:82`).
/// The client hands `linkToken` to the Plaid Link SDK; opening the
/// Link UI is the app's job, not this package's.
public struct PlaidLinkToken: Equatable, Codable {
    public let linkToken: String
    public let expiration: String?

    enum CodingKeys: String, CodingKey {
        case linkToken = "link_token"
        case expiration
    }
}

/// plaid-exchange: `{item_id, connected, duplicate, duplicate_of}`
/// (`plaid-exchange/index.ts:107-108`).
public struct PlaidExchangeResult: Equatable, Codable {
    public let itemId: String?
    public let connected: Bool
    public let duplicate: Bool
    public let duplicateOf: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case connected, duplicate
        case duplicateOf = "duplicate_of"
    }
}

/// plaid-sync success (`plaid-sync/index.ts:592-601`). On a partial
/// failure the function answers 502 with `error: "plaid sync failed"`
/// PLUS these same counts and `failed_items` / `failed_institutions`
/// — see `PlaidSyncError` below; the counts must not be dropped.
/// `skipped_by_reason` maps reason → count; `stale` is true when the
/// scheduled sync had not run recently before this sync.
public struct PlaidSyncResult: Equatable, Codable {
    public let added: Int
    public let updated: Int
    public let reversed: Int
    public let skipped: Int
    public let skippedByReason: [String: Int]?
    public let minutesSincePreviousSync: Int?
    public let stale: Bool?
    public let duplicateRemoved: [String]?
    public let items: Int
    public let connectedItems: Int
    public let skippedDisconnected: Int?
    public let truncated: Bool?
    public let noBankConnected: Bool?

    enum CodingKeys: String, CodingKey {
        case added, updated, reversed, skipped
        case skippedByReason = "skipped_by_reason"
        case minutesSincePreviousSync = "minutes_since_previous_sync"
        case stale
        case duplicateRemoved = "duplicate_removed"
        case items
        case connectedItems = "connected_items"
        case skippedDisconnected = "skipped_disconnected"
        case truncated
        case noBankConnected = "no_bank_connected"
    }
}

/// The 502 partial-failure body of plaid-sync, kept whole so the UI
/// can name the failed bank(s) (live.js:2857-2862, `bankSyncToast`).
public struct PlaidSyncPartialFailure: Equatable {
    public let failedItems: [String]
    public let failedInstitutions: [String]
    public let result: PlaidSyncResult
}

/// One per-item result of plaid-webhook-register
/// (`plaid-webhook-register/index.ts:101-133`).
public struct WebhookRegisterItemResult: Equatable, Codable {
    public let item: String
    public let institution: String?
    public let ok: Bool
    public let error: String?
}

/// plaid-webhook-register: `{webhook_url, enabled, results}`.
/// A partial failure stores NOTHING — the switch must not move
/// (live.js:2915-2924).
public struct WebhookRegisterResult: Equatable, Codable {
    public let webhookUrl: String?
    public let enabled: Bool
    public let results: [WebhookRegisterItemResult]

    enum CodingKeys: String, CodingKey {
        case webhookUrl = "webhook_url"
        case enabled, results
    }
}

/// gmail-oauth-start: `{auth_url}` (`gmail-oauth-start/index.ts:108`).
/// A 409 means the caller administers more than one household and
/// must name one (`multiple admin households: pass household_id…`,
/// live.js:2969-2987) — surfaced as `.gmailOAuthStartConflict`.
public struct GmailOAuthStartResult: Equatable, Codable {
    public let authUrl: String

    enum CodingKeys: String, CodingKey {
        case authUrl = "auth_url"
    }
}

/// One per-connection failure from gmail-poll
/// (`gmail-poll/index.ts:214-216,363`).
public struct GmailPollConnectionError: Equatable, Codable {
    public let connectionId: String
    public let error: String

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case error
    }
}

/// gmail-poll aggregate (`gmail-poll/index.ts:370`): counts plus
/// per-connection `errors` (a poll can fail per connection with NO
/// top-level `error` — live.js:2987-2996). `stale` is true when the
/// previous poll was long ago.
public struct GmailPollResult: Equatable, Codable {
    public let connections: Int
    public let checked: Int
    public let stored: Int
    public let duplicates: Int
    public let quarantined: Int
    public let unparseable: Int
    public let errors: [GmailPollConnectionError]
    public let minutesSincePreviousPoll: Int?
    public let stale: Bool?

    enum CodingKeys: String, CodingKey {
        case connections, checked, stored, duplicates, quarantined, unparseable, errors
        case minutesSincePreviousPoll = "minutes_since_previous_poll"
        case stale
    }

    /// The first per-connection failure, if any — the message the UI
    /// shows instead of a false success (live.js:2991-2996).
    /// A "reauthorization required" error means the token died and
    /// the user must reconnect (live.js / `emailCheckMessage`).
    public var firstError: GmailPollConnectionError? { errors.first }
    public var needsReauthorization: Bool {
        errors.contains { $0.error.lowercased().contains("reauthorization") }
    }
}

/// plaid-disconnect: `{disconnected, plaid_item_id,
/// already_disconnected}` (`plaid-disconnect/index.ts:95,140`).
public struct PlaidDisconnectResult: Equatable, Codable {
    public let disconnected: Bool
    public let plaidItemId: String
    public let alreadyDisconnected: Bool?

    enum CodingKeys: String, CodingKey {
        case disconnected
        case plaidItemId = "plaid_item_id"
        case alreadyDisconnected = "already_disconnected"
    }
}

/// plaid-account-disconnect (`plaid-account-disconnect/index.ts:106,168`).
/// Per-account disconnect is app-level: the account is flagged, past
/// transactions stay, and only when it was the LAST active account on
/// the item is the Plaid item itself removed (`item_disconnected`).
public struct PlaidAccountDisconnectResult: Equatable, Codable {
    public let disconnected: Bool
    public let plaidAccountId: String
    public let alreadyDisconnected: Bool?
    public let itemDisconnected: Bool?

    enum CodingKeys: String, CodingKey {
        case disconnected
        case plaidAccountId = "plaid_account_id"
        case alreadyDisconnected = "already_disconnected"
        case itemDisconnected = "item_disconnected"
    }
}

/// gmail-disconnect: `{disconnected, connection_id}`
/// (`gmail-disconnect/index.ts:88,120`).
public struct GmailDisconnectResult: Equatable, Codable {
    public let disconnected: Bool
    public let connectionId: String

    enum CodingKeys: String, CodingKey {
        case disconnected
        case connectionId = "connection_id"
    }
}

/// delete-account: `{deleted: true}` (`delete-account/index.ts:246`);
/// failures carry a `step` so a half-deleted account can be named
/// (live.js:3332-3336).
public struct DeleteAccountResult: Equatable, Codable {
    public let deleted: Bool
    public let step: String?
}

/// ingest-amex-alert response shapes — REFERENCE ONLY. The function
/// is HMAC-signed server-to-server; the client never calls it
/// (`ingest-amex-alert/index.ts:140-276`).
public struct IngestAmexAlertResult: Equatable, Codable {
    public let stored: Bool?
    public let duplicate: Bool?
    public let state: String?
    public let quarantined: Bool?
    public let reason: String?
    public let error: String?
}

// MARK: - Client

/// Typed Edge Function invocations. Constructed by `SupabaseClient`.
public struct EdgeFunctionsClient {
    public let configuration: SupabaseConfiguration
    public let tokenProvider: () async throws -> String
    private let transport: HTTPTransport

    public init(
        configuration: SupabaseConfiguration,
        tokenProvider: @escaping () async throws -> String,
        transport: HTTPTransport
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    /// Build the POST request for a function invocation. Pure (no
    /// network) so tests can assert on name, URL, headers, and body.
    public func makeRequest(name: String, body: [String: Any]) throws -> URLRequest {
        let url = configuration.functionsBaseURL.appendingPathComponent(name)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        // Authorization is attached by `invoke` (it needs a fresh token).
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    /// Invoke a function and decode its JSON body. Non-2xx responses
    /// throw `OnBudgetError` with the server's `error` string
    /// preserved (a 401 becomes `.sessionExpired`).
    public func invoke<T: Decodable>(name: String, body: [String: Any]) async throws -> T {
        let (data, response) = try await invokeData(name: name, body: body)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OnBudgetError.decodingError("Could not read the result of \(name).")
        }
    }

    /// Raw invoke: returns the status + body without classifying it,
    /// so callers that need a non-2xx body (plaid-sync's 502) can
    /// read it instead of only getting the error.
    public func invokeData(name: String, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(name: name, body: body)
        let token = try await tokenProvider()
        var authed = request
        authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await transport.send(authed)
    }

    /// Invoke a function and return the raw decoded body as a
    /// dictionary (for responses the caller inspects loosely).
    public func invokeRaw(name: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await invokeData(name: name, body: body)
        guard (200...299).contains(response.statusCode) else {
            throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw OnBudgetError.decodingError("Could not read the result of \(name).")
        }
        return json
    }

    // MARK: - Week

    /// `compute-week` — the server's week figures
    /// (`compute-week/index.ts:393-403`). The client sends ONLY
    /// `household_id` (and an optional Sunday `week_start`) — never D,
    /// T, or any legacy credit field. Any household member may read
    /// their own week's numbers; no admin check. `week_start` must be
    /// a Sunday date or the function answers 400.
    public func computeWeek(householdId: UUID, weekStart: String? = nil) async throws -> WeekResult {
        var body: [String: Any] = ["household_id": householdId.uuidString]
        if let weekStart { body["week_start"] = weekStart }
        return try await invoke(name: "compute-week", body: body)
    }

    /// `week-close` — close any due weeks (`week-close/index.ts:993-1009`).
    /// Admin only. A no-op close returns `weeks_closed: 0` with the
    /// same shape. When the call actually closed a week, the caller
    /// reloads the week figures once.
    public func weekClose(householdId: UUID) async throws -> WeekCloseResult {
        try await invoke(name: "week-close", body: ["household_id": householdId.uuidString])
    }

    // MARK: - Plaid (bank)

    /// `plaid-link` — create a Plaid Link token (`plaid-link/index.ts`).
    /// Admin only ("bank linking is admin-only", 403 otherwise).
    public func plaidLink(householdId: UUID) async throws -> PlaidLinkToken {
        try await invoke(name: "plaid-link", body: ["household_id": householdId.uuidString])
    }

    /// `plaid-exchange` — finish a Link flow
    /// (`plaid-exchange/index.ts:36-108`). Admin only. `duplicate:
    /// true` means the bank was already connected — the duplicate
    /// connection was removed and past transactions stay.
    public func plaidExchange(
        householdId: UUID,
        publicToken: String,
        institutionName: String?
    ) async throws -> PlaidExchangeResult {
        var body: [String: Any] = [
            "household_id": householdId.uuidString,
            "public_token": publicToken,
        ]
        body["institution_name"] = institutionName ?? NSNull()
        return try await invoke(name: "plaid-exchange", body: body)
    }

    /// `plaid-sync` — pull transactions for every connected item
    /// (`plaid-sync/index.ts`). Admin only ("manual sync is admin-only").
    /// One bank sync at a time — the caller guards repeat taps
    /// (live.js `runBankSync` / sync guard). A partial failure is a
    /// 502 with the counts still attached; use
    /// `plaidSyncAllowingPartialFailure` when the caller needs them.
    public func plaidSync(householdId: UUID) async throws -> PlaidSyncResult {
        try await invoke(name: "plaid-sync", body: ["household_id": householdId.uuidString])
    }

    /// The outcome of a sync that may have partially failed: either
    /// the full success counts, or the 502 body with its counts plus
    /// the failed item/institution names.
    public enum PlaidSyncOutcome {
        case success(PlaidSyncResult)
        case partial(PlaidSyncPartialFailure)
    }

    /// Like `plaidSync`, but a 502 partial failure is returned as
    /// `.partial` (with `failed_items` / `failed_institutions` and
    /// the counts) instead of thrown, so the UI can name the failed
    /// bank(s) (live.js:2857-2862, `bankSyncToast`). Any other
    /// failure still throws.
    public func plaidSyncAllowingPartialFailure(householdId: UUID) async throws -> PlaidSyncOutcome {
        let (data, response) = try await invokeData(name: "plaid-sync", body: ["household_id": householdId.uuidString])
        if (200...299).contains(response.statusCode) {
            do {
                return .success(try JSONDecoder().decode(PlaidSyncResult.self, from: data))
            } catch {
                throw OnBudgetError.decodingError("Could not read the result of plaid-sync.")
            }
        }
        if response.statusCode == 502,
           let result = try? JSONDecoder().decode(PlaidSyncResult.self, from: data),
           let partial = try? JSONDecoder().decode(PlaidSync502Body.self, from: data) {
            return .partial(PlaidSyncPartialFailure(
                failedItems: partial.failedItems ?? [],
                failedInstitutions: partial.failedInstitutions ?? [],
                result: result
            ))
        }
        throw OnBudgetError.fromHTTPResponse(status: response.statusCode, data: data)
    }

    /// `plaid-disconnect` — remove a whole Plaid item
    /// (`plaid-disconnect/index.ts`). Admin only.
    public func plaidDisconnect(householdId: UUID, plaidItemId: String) async throws -> PlaidDisconnectResult {
        try await invoke(name: "plaid-disconnect", body: [
            "household_id": householdId.uuidString,
            "plaid_item_id": plaidItemId,
        ])
    }

    /// `plaid-account-disconnect` — disconnect one account on an item
    /// (`plaid-account-disconnect/index.ts`). Admin only. See
    /// `PlaidAccountDisconnectResult` for the last-account rule.
    public func plaidAccountDisconnect(
        householdId: UUID,
        plaidItemId: String,
        plaidAccountId: String
    ) async throws -> PlaidAccountDisconnectResult {
        try await invoke(name: "plaid-account-disconnect", body: [
            "household_id": householdId.uuidString,
            "plaid_item_id": plaidItemId,
            "plaid_account_id": plaidAccountId,
        ])
    }

    /// `plaid-webhook-register` — turn automatic sync on/off
    /// (`plaid-webhook-register/index.ts`). Admin only. `enabled:
    /// false` clears the webhook. A partial failure stores nothing:
    /// the caller must leave the switch where it was and name the
    /// failed connection (live.js:2915-2924).
    public func plaidWebhookRegister(householdId: UUID, enabled: Bool) async throws -> WebhookRegisterResult {
        try await invoke(name: "plaid-webhook-register", body: [
            "household_id": householdId.uuidString,
            "enabled": enabled,
        ])
    }

    // MARK: - Gmail (email alerts)

    /// `gmail-oauth-start` — begin the Google OAuth flow
    /// (`gmail-oauth-start/index.ts:48-108`). Admin only. With no
    /// `householdId` the function derives the household from the
    /// caller's admin membership; when the caller administers more
    /// than one household it answers 409 and the caller retries with
    /// the chosen id (live.js:2969-2987) — the 409 arrives as
    /// `.serverError(status: 409, message: "multiple admin
    /// households: pass household_id…")`, which the UI checks for
    /// to offer the household picker. The result's `auth_url` is
    /// opened in the browser / ASWebAuthenticationSession — the page
    /// redirects to Google, and the callback links back to the app.
    /// `client: "native"` tells the server this is the iOS app, so
    /// the callback redirects to `onbudget://gmail-callback` instead
    /// of live.html (server branch gmail-callback-native-redirect,
    /// NOT deployed yet — until it ships the server ignores the
    /// field and always returns to live.html). Omit it for the web.
    public func gmailOAuthStart(householdId: UUID? = nil, client: String? = nil) async throws -> GmailOAuthStartResult {
        var body: [String: Any] = [:]
        if let householdId { body["household_id"] = householdId.uuidString }
        if let client { body["client"] = client }
        return try await invoke(name: "gmail-oauth-start", body: body)
    }

    /// `gmail-poll` — check email now (`gmail-poll/index.ts`).
    /// Admin only. Per-connection failures arrive in `errors` with
    /// NO top-level error — callers must read them (live.js:2991-2996).
    public func gmailPoll(householdId: UUID) async throws -> GmailPollResult {
        try await invoke(name: "gmail-poll", body: ["household_id": householdId.uuidString])
    }

    /// `gmail-disconnect` — remove an email connection
    /// (`gmail-disconnect/index.ts`). Admin only.
    public func gmailDisconnect(householdId: UUID, connectionId: UUID) async throws -> GmailDisconnectResult {
        try await invoke(name: "gmail-disconnect", body: [
            "household_id": householdId.uuidString,
            "connection_id": connectionId.uuidString,
        ])
    }

    // MARK: - Account

    /// `delete-account` (`delete-account/index.ts:246`). The
    /// `SupabaseClient.deleteAccount()` wrapper calls this and then
    /// signs out locally; call it directly only when the caller owns
    /// the post-delete sign-out.
    public func deleteAccount() async throws -> DeleteAccountResult {
        try await invoke(name: "delete-account", body: [:])
    }
}
