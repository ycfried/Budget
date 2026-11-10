// OnBudgetKitTests — GmailCallbackTests.swift
//
// Unit tests for the native Gmail OAuth return path: the
// `onbudget://gmail-callback` URL parser and the `client: "native"`
// marker the app sends to `gmail-oauth-start` so the server knows
// to redirect back to the app instead of live.html. Fixtures only —
// no network, no Google consent.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OnBudgetKit

final class GmailCallbackTests: XCTestCase {
    func testConnectedURLParses() {
        XCTAssertEqual(
            GmailCallback.result(from: URL(string: "onbudget://gmail-callback?gmail=connected")!),
            .connected
        )
    }

    func testFailedURLParses() {
        XCTAssertEqual(
            GmailCallback.result(from: URL(string: "onbudget://gmail-callback?gmail=failed")!),
            .failed
        )
    }

    func testNonCallbackURLsReturnNil() {
        XCTAssertNil(GmailCallback.result(from: URL(string: "onbudget://reset-password?code=abc")!))
        XCTAssertNil(GmailCallback.result(from: URL(string: "https://ycfried.github.io/Budget/live.html?gmail=connected")!))
        XCTAssertNil(GmailCallback.result(from: URL(string: "onbudget://gmail-callback")!))
        XCTAssertNil(GmailCallback.result(from: URL(string: "onbudget://gmail-callback?gmail=other")!))
    }

    func testGmailOAuthStartSendsNativeClientMarker() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json(["auth_url": "https://accounts.google.com/o/oauth2/v2/auth?state=native%3Aabc"])
        })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let result = try await client.gmailOAuthStart(client: "native") as GmailOAuthStartResult
        XCTAssertTrue(result.authUrl.contains("accounts.google.com"))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(jsonBody(of: transport.requests[0])["client"] as? String, "native")
    }

    func testGmailOAuthStartOmitsClientByDefault() async throws {
        let transport = StubTransport(handler: { _ in
            StubTransport.json(["auth_url": "https://accounts.google.com/o/oauth2/v2/auth"])
        })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        _ = try await client.gmailOAuthStart() as GmailOAuthStartResult
        XCTAssertEqual(transport.requests.count, 1)
        // The web flow sends no client marker — the server keeps
        // redirecting it to live.html.
        XCTAssertNil(jsonBody(of: transport.requests[0])["client"])
    }
}
