// OnBudgetKit — Errors.swift
//
// Error mapping for every backend call. The governing rule, copied from
// the web client (live.js), is: **the server's error text is shown to the
// user unchanged** for refusals the user can act on (admin-only, the
// 35-day week lock, "cannot restore: no prior state recorded", "held
// refund already resolved"). This layer classifies those messages into
// typed cases so screens can branch on them, but it never rewrites the
// message itself — `userMessage` returns the server text verbatim.
//
// A second rule, also from live.js: a failed read is an ERROR STATE,
// never a silent empty list and never an endless spinner. Screens must
// render `LoadState.failed` with a retry affordance. Every request in
// this package carries a 30-second timeout (`SupabaseConfiguration.
// requestTimeoutSeconds`) so a hung request surfaces as
// `.timedOut` instead of spinning forever. (The web app has a live
// "Loading…" hang under investigation; the clone must not copy it.)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every failure a screen can see from the backend.
///
/// Cases carry the server's message text wherever the server supplied
/// one, so the UI can show it unchanged.
public enum OnBudgetError: Error, Equatable, LocalizedError {
    /// No network at all (airplane mode, no route). Retryable.
    case networkOffline
    /// A transport failure that is not a clean offline (DNS, TLS, reset).
    case networkError(String)
    /// The request exceeded `SupabaseConfiguration.requestTimeoutSeconds`.
    case timedOut
    /// No stored session, or the stored session can no longer be
    /// refreshed. The UI shows "Your sign-in expired" + a
    /// "Sign in again" action (live.js: data-tx-signin-again).
    case sessionExpired
    /// Authenticated, but the call was refused with 403 and no more
    /// specific message. See also `.adminOnly`.
    case forbidden(String)
    /// The server refused with "admin only" (RPC raise, or a 403 from
    /// an Edge Function). Message preserved verbatim.
    case adminOnly(String)
    /// A mutation RPC refused with "week is locked: …" — the 35-day
    /// rule (a week's transactions are immutable once the current
    /// Sunday week is more than 35 days past the transaction's Sunday
    /// week; `supabase/n4-pre-exclusion-state.sql`, `pending-
    /// charity-mark.sql`). Message preserved verbatim.
    case weekLocked(String)
    /// The fund does not cover the requested amount
    /// ("insufficient fund: available N cents"). Screens use this case
    /// to offer the typed-reason override path (live.js:1256-1262).
    case insufficientFund(String)
    /// "cannot restore: no prior state recorded" (restore_transaction,
    /// `n4-pre-exclusion-state.sql`). Message preserved verbatim.
    case cannotRestore(String)
    /// "held refund already resolved" (resolve_held_refund,
    /// `merged-audit-held-release-atomic.sql`). Message preserved
    /// verbatim. Note: "held refund is not pending" is a different
    /// refusal and maps to `.validationFailed`.
    case heldRefundAlreadyResolved(String)
    /// Too many failed invite-code attempts
    /// ("too many failed join attempts, try again later",
    /// `n13-invite-rate-limit.sql`). Message preserved verbatim.
    case rateLimited(String)
    /// A row the caller named does not exist ("… not found").
    case notFound(String)
    /// Any other server-side validation refusal (bad amount, bad kind,
    /// bad date, "request is not pending", …). Message preserved.
    case validationFailed(String)
    /// An HTTP failure from PostgREST / an Edge Function that no case
    /// above covers. `message` is the server's `error` string.
    case serverError(status: Int, message: String)
    /// The server answered 200 but the body did not decode.
    case decodingError(String)
    /// Anything else, with whatever detail is available.
    case unknown(String)

    /// The exact text a screen should show. For server refusals this
    /// is the server's own text, unchanged.
    public var userMessage: String {
        switch self {
        case .networkOffline:
            return "You're offline. Check your connection and try again."
        case .networkError(let message):
            return message
        case .timedOut:
            return "The request timed out. Check your connection and try again."
        case .sessionExpired:
            return "Your sign-in expired"
        case .forbidden(let message):
            return message
        case .adminOnly(let message):
            return message
        case .weekLocked(let message):
            return message
        case .insufficientFund(let message):
            return message
        case .cannotRestore(let message):
            return message
        case .heldRefundAlreadyResolved(let message):
            return message
        case .rateLimited(let message):
            return message
        case .notFound(let message):
            return message
        case .validationFailed(let message):
            return message
        case .serverError(_, let message):
            return message
        case .decodingError(let message):
            return message
        case .unknown(let message):
            return message
        }
    }

    public var errorDescription: String? { userMessage }

    /// Whether tapping "Try again" can plausibly succeed without the
    /// user changing anything. Session/admin/lock/validation refusals
    /// are not retryable; transport and 5xx failures are.
    public var isRetryable: Bool {
        switch self {
        case .networkOffline, .networkError, .timedOut:
            return true
        case .serverError(let status, _):
            return status >= 500
        case .sessionExpired, .forbidden, .adminOnly, .weekLocked,
             .insufficientFund, .cannotRestore, .heldRefundAlreadyResolved,
             .rateLimited, .notFound, .validationFailed, .decodingError, .unknown:
            return false
        }
    }

    // MARK: - Classification

    /// Classify a server refusal message (RPC `raise exception` text,
    /// Edge Function `error` string, PostgREST `message`) into the
    /// most specific case, preserving the text verbatim.
    public static func classifyServerMessage(_ message: String, status: Int? = nil) -> OnBudgetError {
        let lower = message.lowercased()
        if lower.contains("admin only") { return .adminOnly(message) }
        if lower.contains("week is locked") { return .weekLocked(message) }
        if lower.contains("cannot restore: no prior state recorded") { return .cannotRestore(message) }
        if lower.contains("held refund already resolved") { return .heldRefundAlreadyResolved(message) }
        if lower.contains("insufficient fund") { return .insufficientFund(message) }
        if lower.contains("too many failed join attempts") { return .rateLimited(message) }
        if lower.contains("not authenticated") { return .sessionExpired }
        // Session-dead signals BEFORE the "not found" check: GoTrue's
        // dead-refresh-token text ("Invalid Refresh Token: Refresh
        // Token Not Found") contains "not found" but is a dead session.
        if isSessionExpiredMessage(message) { return .sessionExpired }
        if lower.contains("not found") { return .notFound(message) }
        if let status {
            switch status {
            case 401: return .sessionExpired
            case 403: return .forbidden(message)
            case 404: return .notFound(message)
            case 409: return .serverError(status: status, message: message)
            case 400, 422: return .validationFailed(message)
            case 429: return .rateLimited(message)
            default: return .serverError(status: status, message: message)
            }
        }
        return .validationFailed(message)
    }

    /// The session-dead signals the web client checks (live.js:767-772):
    /// PostgREST surfaces a 401 as code PGRST301 / "JWT expired".
    public static func isSessionExpiredMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("jwt expired")
            || lower.contains("invalid jwt")
            || lower.contains("pgrst301")
            || lower.contains("unauthorized")
            || lower.contains("token expired")
            || lower.contains("invalid_grant")
            || lower.contains("refresh token not found")
            || lower.contains("refresh token expired")
    }

    /// Map a URLSession transport failure. `URLError.notConnectedToInternet`
    /// (and its common siblings) is offline; everything else keeps its
    /// localized description so the real cause is not hidden.
    public static func fromURLError(_ error: URLError) -> OnBudgetError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .networkOffline
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .unknown("Request cancelled.")
        default:
            return .networkError(error.localizedDescription)
        }
    }

    /// Decode a PostgREST error body (`{code, message, details, hint}`)
    /// or an Edge Function body (`{error, …}`) and classify it.
    /// - Parameters:
    ///   - status: HTTP status of the response.
    ///   - data: Raw response body (may be empty).
    public static func fromHTTPResponse(status: Int, data: Data) -> OnBudgetError {
        let decoder = JSONDecoder()
        if let body = try? decoder.decode(PostgrestErrorBody.self, from: data),
           let message = body.message, !message.isEmpty {
            if status == 401 || body.code == "PGRST301" || isSessionExpiredMessage(message) {
                return .sessionExpired
            }
            return classifyServerMessage(message, status: status)
        }
        if let body = try? decoder.decode(EdgeErrorBody.self, from: data),
           let message = body.error, !message.isEmpty {
            if status == 401 || isSessionExpiredMessage(message) {
                return .sessionExpired
            }
            return classifyServerMessage(message, status: status)
        }
        if status == 401 { return .sessionExpired }
        if status == 403 { return .forbidden("The request was refused.") }
        // Plain language only — never a raw "Request failed (400)."
        // (owner, Nov 11, 2026). The status code is kept on the case
        // for logging, never in the message.
        return .serverError(status: status, message: "Could not complete the request. Try again.")
    }

    /// Classify a GoTrue (auth) error body. GoTrue answers failures as
    /// `{error, error_description}` (and sometimes `{message}`).
    public static func fromAuthResponse(status: Int, data: Data) -> OnBudgetError {
        let decoder = JSONDecoder()
        if let body = try? decoder.decode(GoTrueErrorBody.self, from: data) {
            let message = body.errorDescription ?? body.error ?? body.msg ?? body.message ?? ""
            if !message.isEmpty {
                // `invalid_grant` means different things by context:
                // on the password grant it is a wrong email/password;
                // on the refresh grant it is a dead refresh token.
                // This path serves the password grant (sign-in); the
                // refresh path clears the session on 400/401 itself
                // before reaching here. Check it FIRST, before the
                // session-expired signals (which also match the code).
                if body.error == "invalid_grant" || message.lowercased().contains("invalid login credentials") {
                    return .validationFailed("Username or password is incorrect.")
                }
                if status == 401 || isSessionExpiredMessage(message) {
                    return .sessionExpired
                }
                return classifyServerMessage(message, status: status)
            }
        }
        if status == 401 { return .sessionExpired }
        // Plain language only: a raw "Sign-in failed (400)." is never
        // shown to the user (owner, Nov 11, 2026). The status code is
        // kept on the case for logging, never in the message.
        return .serverError(status: status, message: "Could not complete the request. Try again.")
    }
}

/// PostgREST error envelope: `{code, message, details, hint}`.
struct PostgrestErrorBody: Decodable {
    let code: String?
    let message: String?
    let details: String?
    let hint: String?
}

/// Edge Function error envelope: `{error, …}` plus function-specific fields.
struct EdgeErrorBody: Decodable {
    let error: String?
    let step: String?
}

/// GoTrue error envelope: `{error, error_description}` or `{message}`.
struct GoTrueErrorBody: Decodable {
    let error: String?
    let errorDescription: String?
    let message: String?
    // GoTrue's signup / token-refresh errors carry the text in
    // `msg` ("User already registered"), not `message` — without
    // this field those errors decoded to an empty string and
    // surfaced as the generic "Sign-in failed (400)."
    let msg: String?
    let code: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message
        case msg
        case code
    }
}

// MARK: - Loading state

/// The loading contract for every screen: an explicit loading state,
/// then data or a REAL error. There is no state that can spin forever —
/// a request that fails (including a timeout) lands in `.failed` with
/// the error and a retry path. Screens must render `.failed`, never
/// leave a spinner up with no error.
public enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(OnBudgetError)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var error: OnBudgetError? {
        if case .failed(let error) = self { return error }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
