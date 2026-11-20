// OnBudgetKitTests — SessionStoreMirrorTests.swift
//
// Tests for the build-48 widget-sync fix: `replaceSessionStore` must
// always wrap a persistent store in a MirroredSessionStore, so the
// App Group mirror is an invariant and the widget extension always
// finds a session to fetch with. The one exception is
// InMemorySessionStore (remember-me off, and tests): a session the
// user chose not to persist must not be persisted into the App Group
// either.
//
// Background (Nov 19, 2026): the mirror was dropped by every
// session-store swap — BiometricUnlock.enable() swapped to a bare
// BiometricSessionStore, sign-in swapped to a bare
// UserDefaultsSessionStore — so after any sign-in or Face ID opt-in
// the widget found no (or an expired) session and its sync button
// silently did nothing. These tests pin the invariant so a later
// swap cannot silently drop the mirror again.
//
// The tests use unique UserDefaults keys so they never touch the
// real session key, and a StubTransport so no network is involved.

import Foundation
import XCTest
@testable import OnBudgetKit

final class SessionStoreMirrorTests: XCTestCase {
    private func makeClient() -> SupabaseClient {
        SupabaseClient(
            configuration: testConfiguration(),
            store: InMemorySessionStore(),
            transport: StubTransport(handler: { _ in StubTransport.raw("") })
        )
    }

    private func makeSession() -> AuthSession {
        AuthSession(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            tokenType: "bearer",
            expiresAt: Date().addingTimeInterval(3600),
            user: AuthUser(id: UUID(), email: "test@example.com")
        )
    }

    func testReplaceSessionStoreWrapsPersistentStoreInMirror() {
        let client = makeClient()
        let key = "test.mirror.\(UUID().uuidString)"
        client.replaceSessionStore(UserDefaultsSessionStore(defaults: .standard, key: key))

        guard let mirrored = client.store as? MirroredSessionStore else {
            XCTFail("replaceSessionStore must wrap a persistent store in a MirroredSessionStore")
            return
        }
        XCTAssertTrue(
            mirrored.wrappedStore is UserDefaultsSessionStore,
            "the mirror must wrap the store it was given"
        )
        // Leave no test residue behind.
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testReplaceSessionStoreDoesNotWrapInMemoryStore() {
        let client = makeClient()
        client.replaceSessionStore(InMemorySessionStore())
        XCTAssertTrue(
            client.store is InMemorySessionStore,
            "remember-me-off / test sessions must not be persisted into the App Group"
        )
        XCTAssertFalse(client.store is MirroredSessionStore)
    }

    func testReplaceSessionStoreKeepsExistingMirror() {
        let client = makeClient()
        let mirror = MirroredSessionStore(inner: InMemorySessionStore())
        client.replaceSessionStore(mirror)
        XCTAssertTrue(
            client.store === mirror,
            "an already-mirrored store must not be double-wrapped"
        )
    }

    func testMirroredStoreSaveReachesInnerStore() {
        let inner = InMemorySessionStore()
        let mirror = MirroredSessionStore(inner: inner)
        let session = makeSession()

        mirror.save(session)
        XCTAssertEqual(inner.load()?.accessToken, "test-access")

        mirror.save(nil)
        XCTAssertNil(inner.load(), "save(nil) must clear the inner store")
    }

    func testMirroredStoreClearInnerLeavesMirrorAlone() {
        // clearInner is the "session is MOVING" path: the old store's
        // own storage is cleared, but the shared App Group mirror is
        // not touched (the new store just wrote the session there).
        let inner = InMemorySessionStore()
        let mirror = MirroredSessionStore(inner: inner)
        mirror.save(makeSession())
        mirror.clearInner()
        XCTAssertNil(inner.load())
    }

    func testReplaceSessionStoreWithSameUnderlyingStoreDoesNotClearIt() {
        // Re-enabling Face ID wraps the SAME Keychain store in a
        // fresh mirror: the old mirror's inner store must not be
        // cleared, or the session the new mirror just wrote is
        // deleted again. (Build 48 fix — the first cloud run caught
        // re-enable deleting the Keychain item; the InMemory store
        // here stands in for the Keychain store — the identity
        // logic is what is pinned.)
        let inner = InMemorySessionStore()
        let session = makeSession()
        inner.save(session)
        let client = SupabaseClient(
            configuration: testConfiguration(),
            store: MirroredSessionStore(inner: inner),
            transport: StubTransport(handler: { _ in StubTransport.raw("") })
        )
        XCTAssertEqual(client.currentSession?.accessToken, "test-access")

        // Swap to a FRESH mirror around the SAME inner store.
        client.replaceSessionStore(MirroredSessionStore(inner: inner))

        XCTAssertEqual(
            inner.load()?.accessToken, "test-access",
            "re-swapping to the same underlying store must not clear it"
        )
        XCTAssertEqual(client.currentSession?.accessToken, "test-access")
    }
}
