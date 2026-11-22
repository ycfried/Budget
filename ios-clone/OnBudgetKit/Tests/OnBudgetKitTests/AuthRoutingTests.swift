// OnBudgetKitTests — AuthRoutingTests.swift
//
// Build 54 (owner, Nov 21, 2026): auth-only routing — GoTrue
// requests go to the Cloudflare Worker proxy (auth.getstag.us)
// so the Google sign-in screen shows getstag.us, while rest and
// Edge Functions stay on supabase.co. No network: these pin the
// URLs the client builds.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OnBudgetKit

final class AuthRoutingTests: XCTestCase {
    func testLiveAuthHostIsTheProxy() {
        XCTAssertEqual(Configuration.supabaseAuthURL, "https://auth.getstag.us")
        XCTAssertEqual(SupabaseConfiguration.live.authBaseURL.host, "auth.getstag.us")
        XCTAssertEqual(SupabaseConfiguration.live.authBaseURL.path, "/auth/v1")
    }

    func testLiveRestAndFunctionsStayOnSupabaseCo() {
        XCTAssertEqual(SupabaseConfiguration.live.restBaseURL.host, "tnkhvdkmwmwiogiienee.supabase.co")
        XCTAssertEqual(SupabaseConfiguration.live.restBaseURL.path, "/rest/v1")
        XCTAssertEqual(SupabaseConfiguration.live.functionsBaseURL.host, "tnkhvdkmwmwiogiienee.supabase.co")
        XCTAssertEqual(SupabaseConfiguration.live.functionsBaseURL.path, "/functions/v1")
    }

    func testAuthRequestGoesToTheProxy() throws {
        let request = try SupabaseClient.authRequest(
            configuration: .live,
            path: "token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            method: "POST",
            accessToken: nil,
            jsonBody: ["email": "a@example.com", "password": "secret123"]
        )
        XCTAssertEqual(request.url?.host, "auth.getstag.us")
        XCTAssertEqual(request.url?.path, "/auth/v1/token")
    }

    func testCustomAuthURLIsHonoured() {
        let config = SupabaseConfiguration(
            baseURL: URL(string: "https://tnkhvdkmwmwiogiienee.supabase.co")!,
            authURL: URL(string: "https://auth.example.test")!,
            anonKey: "sb_publishable_test"
        )
        XCTAssertEqual(config.authBaseURL.host, "auth.example.test")
        XCTAssertEqual(config.restBaseURL.host, "tnkhvdkmwmwiogiienee.supabase.co")
    }

    func testDefaultAuthURLIsTheProxy() {
        // Callers that only pass baseURL + anonKey (e.g. the
        // testConfiguration helper) still route auth through the
        // proxy — the default must not silently fall back to
        // supabase.co.
        let config = SupabaseConfiguration(
            baseURL: URL(string: "https://tnkhvdkmwmwiogiienee.supabase.co")!,
            anonKey: "sb_publishable_test"
        )
        XCTAssertEqual(config.authBaseURL.host, "auth.getstag.us")
    }
}
