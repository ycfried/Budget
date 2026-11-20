// OnBudgetKitTests — WidgetRefreshTests.swift
//
// Widget refresh fixes (build 51, owner Nov 20, 2026): the widget
// extension must not wipe the shared session on a refused refresh,
// and the failure mark must stay visible until the next sync.
// No network — the transport is stubbed; the store is in-memory.
// `StubTransport`, `testConfiguration()` and `testAuthSession()`
// live in APIRequestTests.swift / BiometricUnlockTests.swift
// (same test target).

import Foundation
import XCTest
@testable import OnBudgetKit

final class WidgetRefreshTests: XCTestCase {

    /// A client holding an expired session, backed by an in-memory
    /// store (the App Group mirror, in miniature). The session is
    /// saved BEFORE construction — the client snapshots the store
    /// at init, like the real refresher's client does.
    private func expiredClient(
        clearsSessionOnRefusedRefresh: Bool = true,
        transport: HTTPTransport
    ) -> (client: SupabaseClient, store: InMemorySessionStore) {
        let store = InMemorySessionStore()
        store.save(testAuthSession(expiresIn: -60))
        let client = SupabaseClient(
            configuration: testConfiguration(),
            store: store,
            transport: transport,
            clearsSessionOnRefusedRefresh: clearsSessionOnRefusedRefresh
        )
        return (client, store)
    }

    /// GoTrue refusing a dead refresh token.
    private func refusedRefreshTransport() -> StubTransport {
        StubTransport(handler: { _ in
            StubTransport.json(
                ["error": "invalid_grant",
                 "error_description": "Invalid Refresh Token: Refresh Token Not Found"],
                status: 400)
        })
    }

    func testRefusedRefreshKeepsPersistedSessionWhenFlagIsFalse() async {
        // The widget extension's client (build 51): a refused
        // refresh must fail the fetch but MUST NOT delete the
        // mirrored session — otherwise every later tap and
        // background run has no session and the widget sticks
        // until the user opens the app again.
        let (client, store) = expiredClient(
            clearsSessionOnRefusedRefresh: false,
            transport: refusedRefreshTransport())

        do {
            _ = try await client.validAccessToken()
            XCTFail("a refused refresh must throw")
        } catch let error as OnBudgetError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNotNil(
            store.load(),
            "the extension-style client must NOT wipe the persisted session on a refused refresh — a later tap / background run must still have a session to retry with")
        XCTAssertNotNil(
            client.currentSession,
            "the in-memory session survives too — only the persisted clear is gated")
    }

    func testRefusedRefreshClearsSessionByDefault() async {
        // The app's main client keeps the old behaviour (default
        // `true`): a dead refresh token means the session is dead,
        // so clearing it forces re-sign-in instead of retrying a
        // dead token forever.
        let (client, store) = expiredClient(transport: refusedRefreshTransport())

        do {
            _ = try await client.validAccessToken()
            XCTFail("a refused refresh must throw")
        } catch let error as OnBudgetError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(
            store.load(),
            "the default client must still clear a dead session on a refused refresh")
        XCTAssertNil(client.currentSession)
    }

    func testSuccessfulRefreshStillSavesSessionWhenFlagIsFalse() async throws {
        // The flag only gates the clear-on-refusal: a successful
        // refresh must still persist the new session, so the
        // mirror gets the fresh tokens.
        let fresh = StubTransport(handler: { _ in
            StubTransport.json(
                ["access_token": "acc-new", "refresh_token": "ref-new",
                 "token_type": "bearer", "expires_in": 3600,
                 "user": ["id": "99999999-9999-9999-9999-999999999999",
                          "email": "owner@example.com",
                          "user_metadata": ["full_name": "Shuki Friedman"]]],
                status: 200)
        })
        let (client, store) = expiredClient(
            clearsSessionOnRefusedRefresh: false,
            transport: fresh)

        let token = try await client.validAccessToken()
        XCTAssertEqual(token, "acc-new")
        XCTAssertEqual(
            store.load()?.accessToken, "acc-new",
            "a successful refresh must still persist the new session")
    }

    // MARK: - Failure mark visibility (build 51)

    func testFailedMarkStaysVisibleLongAfterTransientWindow() {
        let hourAgo = Date().addingTimeInterval(-3600)
        XCTAssertTrue(
            WidgetSyncStateStore.isMarkVisible(state: .failed, at: hourAgo),
            "a failed sync must stay red until the next sync — the 15-second expiry made a failed tap look like nothing happened")
    }

    func testSucceededMarkExpiresAfterTransientWindow() {
        let hourAgo = Date().addingTimeInterval(-3600)
        XCTAssertFalse(
            WidgetSyncStateStore.isMarkVisible(state: .succeeded, at: hourAgo),
            "the success checkmark is transient — it clears after 15 seconds")
        XCTAssertTrue(
            WidgetSyncStateStore.isMarkVisible(state: .succeeded, at: Date()),
            "a just-landed success must still show")
    }

    func testSyncingMarkIsVisible() {
        XCTAssertTrue(
            WidgetSyncStateStore.isMarkVisible(state: .syncing, at: nil),
            "the spinner shows until the intent writes its landed state")
    }

    func testIdleMarkIsNeverVisible() {
        XCTAssertFalse(
            WidgetSyncStateStore.isMarkVisible(state: .idle, at: nil))
        XCTAssertFalse(
            WidgetSyncStateStore.isMarkVisible(state: .succeeded, at: nil),
            "a success with no date cannot be recent")
    }
}
