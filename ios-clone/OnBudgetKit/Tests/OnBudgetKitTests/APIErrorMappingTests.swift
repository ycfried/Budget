// OnBudgetKitTests — APIErrorMappingTests.swift
//
// Error mapping: server refusal texts are classified into typed cases
// and carried through UNCHANGED, a 401 / JWT-expired response becomes
// `.sessionExpired`, and transport failures map to offline/timeout.
// Fixtures only — no network.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OnBudgetKit

final class APIErrorMappingTests: XCTestCase {
    func testServerRefusalsPreserveTextVerbatim() {
        let cases: [(String, OnBudgetError)] = [
            ("admin only", .adminOnly("admin only")),
            ("week is locked: a locked-week transaction cannot be changed here",
             .weekLocked("week is locked: a locked-week transaction cannot be changed here")),
            ("cannot restore: no prior state recorded",
             .cannotRestore("cannot restore: no prior state recorded")),
            ("held refund already resolved",
             .heldRefundAlreadyResolved("held refund already resolved")),
            ("insufficient fund: available 500 cents",
             .insufficientFund("insufficient fund: available 500 cents")),
            ("too many failed join attempts, try again later",
             .rateLimited("too many failed join attempts, try again later")),
            ("transaction not found", .notFound("transaction not found")),
            ("amount must be positive", .validationFailed("amount must be positive")),
        ]
        for (message, expected) in cases {
            let classified = OnBudgetError.classifyServerMessage(message)
            XCTAssertEqual(classified, expected, message)
            XCTAssertEqual(classified.userMessage, message, message)
        }
    }

    func testSessionExpiredSignals() {
        for message in ["JWT expired", "invalid jwt", "PGRST301", "unauthorized",
                        "token expired", "invalid_grant", "refresh token not found"] {
            XCTAssertEqual(OnBudgetError.classifyServerMessage(message), .sessionExpired, message)
            XCTAssertTrue(OnBudgetError.isSessionExpiredMessage(message), message)
        }
        XCTAssertEqual(OnBudgetError.sessionExpired.userMessage, "Your sign-in expired")
        XCTAssertFalse(OnBudgetError.sessionExpired.isRetryable)
    }

    func testPostgrest401BodyMapsToSessionExpired() {
        let body = Data("""
        {"code": "PGRST301", "message": "JWT expired", "details": null, "hint": null}
        """.utf8)
        XCTAssertEqual(OnBudgetError.fromHTTPResponse(status: 401, data: body), .sessionExpired)
    }

    func testPostgrestErrorBodyMapsByMessage() {
        let body = Data("""
        {"code": "P0001", "message": "admin only", "details": null, "hint": null}
        """.utf8)
        XCTAssertEqual(
            OnBudgetError.fromHTTPResponse(status: 400, data: body),
            .adminOnly("admin only")
        )
    }

    func testEdgeFunctionErrorBodyMapsByMessage() {
        let body = Data("""
        {"error": "week_start must be a Sunday date (YYYY-MM-DD)"}
        """.utf8)
        let error = OnBudgetError.fromHTTPResponse(status: 400, data: body)
        XCTAssertEqual(error, .validationFailed("week_start must be a Sunday date (YYYY-MM-DD)"))
    }

    func testAuthInvalidGrantMapsToGenericSignInMessage() {
        let body = Data("""
        {"error": "invalid_grant", "error_description": "Invalid login credentials"}
        """.utf8)
        let error = OnBudgetError.fromAuthResponse(status: 400, data: body)
        // The UI must not say which field was wrong from the Auth
        // response alone (live.js:2425-2430): Supabase's
        // signInWithPassword returns one `invalid_credentials` code
        // for both cases, by design. Per-field wording comes from the
        // separate `check-email-exists` Edge Function — the owner
        // accepted that enumeration trade-off Nov 11, ~7:41 PM ("It's
        // just a budgeting app"). When that check cannot run, this
        // generic case is the fallback; its message is the owner's
        // wording: "username or password is incorrect".
        XCTAssertEqual(error, .invalidCredentials)
        XCTAssertEqual(error.userMessage, "Username or password is incorrect.")
    }

    func testAuthInvalidCredentialsInMsgFormatMapsToPlainMessage() {
        // GoTrue's newer error format carries the text in `msg`:
        // {"code":400,"error_code":"invalid_grant",
        //  "msg":"Invalid login credentials"}. This is the body behind
        // the owner's "Sign-in failed (400)." report (Nov 11, 2026):
        // without the `msg` field the message decoded empty and the
        // raw fallback fired.
        let body = Data("""
        {"code": 400, "error_code": "invalid_grant", "msg": "Invalid login credentials"}
        """.utf8)
        let error = OnBudgetError.fromAuthResponse(status: 400, data: body)
        XCTAssertEqual(error, .invalidCredentials)
        XCTAssertEqual(error.userMessage, "Username or password is incorrect.")
    }

    func testAuthFallbackNeverShowsARawStatusCode() {
        // An unparseable 400 body must still read as plain language,
        // never "Sign-in failed (400)."
        let error = OnBudgetError.fromAuthResponse(status: 400, data: Data("not json".utf8))
        XCTAssertEqual(error, .serverError(status: 400, message: "Could not complete the request. Try again."))
        XCTAssertFalse(error.userMessage.contains("400"))
        let httpError = OnBudgetError.fromHTTPResponse(status: 500, data: Data("not json".utf8))
        XCTAssertEqual(httpError, .serverError(status: 500, message: "Could not complete the request. Try again."))
        XCTAssertFalse(httpError.userMessage.contains("500"))
    }

    func testAuthSignUpAlreadyRegisteredMapsToValidationFailed() {
        // GoTrue's sign-up error for an existing email carries the
        // text in `msg`, not `message`:
        // {"code":400,"error_code":"user_already_exists",
        //  "msg":"User already registered"}. Before the `msg` field
        // was decoded, this fell through to the generic
        // "Sign-in failed (400)." and the name step could never tell
        // the user the email is already registered (owner report,
        // Nov 11, 2026).
        let body = Data("""
        {"code": 400, "error_code": "user_already_exists", "msg": "User already registered"}
        """.utf8)
        let error = OnBudgetError.fromAuthResponse(status: 400, data: body)
        XCTAssertEqual(error, .validationFailed("User already registered"))
        XCTAssertEqual(error.userMessage, "User already registered")
        XCTAssertFalse(error.isRetryable)
    }

    func testURLErrorMapping() {
        XCTAssertEqual(
            OnBudgetError.fromURLError(URLError(.notConnectedToInternet)),
            .networkOffline
        )
        XCTAssertEqual(
            OnBudgetError.fromURLError(URLError(.timedOut)),
            .timedOut
        )
        XCTAssertTrue(OnBudgetError.networkOffline.isRetryable)
        XCTAssertTrue(OnBudgetError.timedOut.isRetryable)
        XCTAssertTrue(OnBudgetError.serverError(status: 500, message: "x").isRetryable)
        XCTAssertFalse(OnBudgetError.serverError(status: 400, message: "x").isRetryable)
        XCTAssertFalse(OnBudgetError.adminOnly("admin only").isRetryable)
        XCTAssertFalse(OnBudgetError.weekLocked("week is locked").isRetryable)
    }

    func testRPCErrorSurfacesThroughCall() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json(
                ["code": "P0001", "message": "cannot restore: no prior state recorded"],
                status: 400
            )
        })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        do {
            try await client.restoreTransaction(txnId: UUID())
            XCTFail("expected an error")
        } catch let error as OnBudgetError {
            XCTAssertEqual(error, .cannotRestore("cannot restore: no prior state recorded"))
            XCTAssertEqual(error.userMessage, "cannot restore: no prior state recorded")
        }
    }

    func test401FromRPCSurfacesAsSessionExpired() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json(
                ["code": "PGRST301", "message": "JWT expired"],
                status: 401
            )
        })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        do {
            try await client.restoreTransaction(txnId: UUID())
            XCTFail("expected an error")
        } catch let error as OnBudgetError {
            XCTAssertEqual(error, .sessionExpired)
        }
    }

    func testEdgeFunction401SurfacesAsSessionExpired() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json(["error": "unauthorized"], status: 401)
        })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        do {
            _ = try await client.computeWeek(householdId: UUID()) as WeekResult
            XCTFail("expected an error")
        } catch let error as OnBudgetError {
            XCTAssertEqual(error, .sessionExpired)
        }
    }

    func testPlaidSync502ParsesPartialFailure() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json([
                "error": "plaid sync failed",
                "failed_items": ["item-1"],
                "failed_institutions": ["American Express"],
                "added": 2, "updated": 0, "reversed": 0, "skipped": 0,
                "minutes_since_previous_sync": 120, "stale": true,
                "items": 1, "connected_items": 1,
            ], status: 502)
        })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let outcome = try await client.plaidSyncAllowingPartialFailure(householdId: UUID())
        guard case .partial(let partial) = outcome else {
            XCTFail("expected a partial failure")
            return
        }
        XCTAssertEqual(partial.failedInstitutions, ["American Express"])
        XCTAssertEqual(partial.result.added, 2)
        XCTAssertEqual(partial.result.stale, true)
    }

    func testGmailOAuthStart409KeepsStatus() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json(
                ["error": "multiple admin households: pass household_id of the household to connect"],
                status: 409
            )
        })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        do {
            _ = try await client.gmailOAuthStart() as GmailOAuthStartResult
            XCTFail("expected an error")
        } catch let error as OnBudgetError {
            // The UI checks for status 409 to offer the household picker.
            XCTAssertEqual(
                error,
                .serverError(status: 409, message: "multiple admin households: pass household_id of the household to connect")
            )
        }
    }

    func testLoadStateContract() {
        var state = LoadState<Int>.idle
        XCTAssertNil(state.value)
        XCTAssertNil(state.error)
        state = .loading
        XCTAssertTrue(state.isLoading)
        state = .loaded(42)
        XCTAssertEqual(state.value, 42)
        state = .failed(.networkOffline)
        XCTAssertEqual(state.error, .networkOffline)
        XCTAssertEqual(state.error?.userMessage, "You're offline. Check your connection and try again.")
    }
}
