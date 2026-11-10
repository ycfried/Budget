// OnBudgetKitTests — BiometricUnlockTests.swift
//
// Unit tests for Face ID unlock (native v1, owner-approved Nov 9,
// 2026). No real biometrics, no real Keychain: the coordinator is
// tested against a mock Keychain (which models the real SecItem
// behaviour — a protected item cannot be read without an
// authenticated context) and a mock LAContext authenticator.
// The real SecItem / LAContext code paths are Apple-only
// (`#if canImport(Security)` / `#if canImport(LocalAuthentication)`)
// and can only be proven on a real device / simulator run — see
// PROGRESS.md "Face ID unlock" for what still needs that run.
//
// `StubTransport` and `testConfiguration()` live in
// APIRequestTests.swift (same test target).

import Foundation
import XCTest
@testable import OnBudgetKit

// MARK: - Mocks

/// Models the real Keychain item: `load(nil)` returns nil when an
/// item exists (authentication would be needed — the real SecItem
/// call returns `errSecInteractionNotAllowed` and never prompts);
/// `load(non-nil)` returns the bytes (the unlock flow always passes
/// the just-evaluated context). `invalidated` models an enrolment
/// change: every read throws `.biometricsChanged`, like a
/// `.biometryCurrentSet` item after a face/finger was added or
/// removed.
final class MockBiometricKeychain: BiometricKeychain {
    var stored: Data?
    var invalidated = false
    var saveError: BiometricUnlockError?

    func exists() -> Bool { stored != nil }

    func load(authenticatedContext: Any?) throws -> Data? {
        if invalidated { throw BiometricUnlockError.biometricsChanged }
        guard authenticatedContext != nil else { return nil }
        return stored
    }

    func save(_ data: Data?) throws {
        if let saveError { throw saveError }
        stored = data
    }

    func delete() { stored = nil }
}

/// Scripted LAContext stand-in. `lastAuthenticatedContext` is a
/// non-nil sentinel after a successful evaluate, mirroring the real
/// authenticator handing its LAContext to the Keychain read.
final class MockBiometricAuthenticator: BiometricAuthenticator {
    var kind: BiometryKind = .faceID
    var canEvaluateValue = true
    var evaluateError: BiometricUnlockError?
    var evaluateCalled = false

    var biometryKind: BiometryKind { kind }
    var canEvaluate: Bool { canEvaluateValue }
    var lastAuthenticatedContext: Any? {
        evaluateCalled && evaluateError == nil ? "mock-authenticated" : nil
    }

    func evaluate(reason: String) async throws {
        evaluateCalled = true
        if let evaluateError { throw evaluateError }
    }
}

// MARK: - Helpers

func testAuthSession(expiresIn: TimeInterval = 3600) -> AuthSession {
    AuthSession(
        accessToken: "access-test",
        refreshToken: "refresh-test",
        tokenType: "bearer",
        expiresAt: Date().addingTimeInterval(expiresIn),
        user: AuthUser(id: UUID(), email: "test@example.com", userMetadata: [:])
    )
}

/// A client whose store is the given `store`, holding `session` when
/// one is passed. The transport answers nothing by default; tests
/// that need a refresh pass their own stub.
func testClient(
    store: SessionStore,
    session: AuthSession?,
    transport: HTTPTransport? = nil
) -> SupabaseClient {
    store.save(session)
    return SupabaseClient(
        configuration: testConfiguration(),
        store: store,
        transport: transport ?? StubTransport(handler: { _ in StubTransport.raw("") })
    )
}

func testUnlock(
    keychain: MockBiometricKeychain,
    authenticator: MockBiometricAuthenticator
) -> BiometricUnlock {
    BiometricUnlock(keychain: keychain, authenticator: authenticator)
}

// MARK: - Keychain store (save / load / delete)

final class BiometricSessionStoreTests: XCTestCase {
    func testRoundTripsSessionThroughKeychain() throws {
        let keychain = MockBiometricKeychain()
        let store = BiometricSessionStore(keychain: keychain)
        let session = testAuthSession()

        store.save(session)
        XCTAssertNotNil(keychain.stored, "save must write bytes to the Keychain")

        // The plain protocol load never prompts: without an
        // authenticated context it returns nil even when an item
        // exists (this is what keeps boot on the auth screen).
        XCTAssertNil(store.load(), "plain load() must not read a protected item")

        // The unlock-path read, with a context, decodes the session.
        let loaded = try store.loadAuthenticated(authenticatedContext: "mock-authenticated")
        XCTAssertEqual(loaded, session)
    }

    func testSaveNilDeletesItem() {
        let keychain = MockBiometricKeychain()
        let store = BiometricSessionStore(keychain: keychain)
        store.save(testAuthSession())
        XCTAssertNotNil(keychain.stored)

        store.save(nil)
        XCTAssertNil(keychain.stored)
        XCTAssertFalse(keychain.exists())
    }

    func testLoadAuthenticatedThrowsWhenBiometricsChanged() {
        let keychain = MockBiometricKeychain()
        let store = BiometricSessionStore(keychain: keychain)
        store.save(testAuthSession())
        keychain.invalidated = true

        XCTAssertThrowsError(
            try store.loadAuthenticated(authenticatedContext: "mock-authenticated")
        ) { error in
            XCTAssertEqual(error as? BiometricUnlockError, .biometricsChanged)
        }
    }
}

// MARK: - Toggle state machine (opt in / opt out)

final class BiometricToggleTests: XCTestCase {
    func testEnableMovesSessionToKeychainAndClearsPlainStore() async throws {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let plainStore = InMemorySessionStore()
        let session = testAuthSession()
        let client = testClient(store: plainStore, session: session)

        try await unlock.enable(client: client)

        XCTAssertTrue(authenticator.evaluateCalled, "opt-in must prove Face ID first")
        XCTAssertNotNil(keychain.stored, "session must be in the Keychain")
        XCTAssertTrue(unlock.isEnabled)
        XCTAssertTrue(client.store is BiometricSessionStore, "client must persist to the Keychain store now")
        XCTAssertNil(plainStore.load(), "the plaintext copy must be cleared on opt-in")
        XCTAssertEqual(client.currentSession, session, "the live session is untouched by the move")
    }

    func testEnableTwiceIsIdempotent() async throws {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = testClient(store: InMemorySessionStore(), session: testAuthSession())

        try await unlock.enable(client: client)
        try await unlock.enable(client: client)

        XCTAssertTrue(unlock.isEnabled)
        XCTAssertNotNil(keychain.stored)
        XCTAssertTrue(client.store is BiometricSessionStore)
        XCTAssertNotNil(client.currentSession)
    }

    func testDisableDeletesKeychainItemAndRestoresPlainStore() async throws {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let session = testAuthSession()
        let client = testClient(store: InMemorySessionStore(), session: session)
        try await unlock.enable(client: client)
        XCTAssertTrue(unlock.isEnabled)

        unlock.disable(client: client)

        XCTAssertFalse(unlock.isEnabled)
        XCTAssertNil(keychain.stored, "opt-out must delete the Keychain item")
        XCTAssertTrue(client.store is UserDefaultsSessionStore, "client must persist to UserDefaults again")
        XCTAssertEqual(client.currentSession, session, "the live session survives opt-out")
    }

    func testDisableWhenAlreadyOffIsANoop() {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let plainStore = InMemorySessionStore()
        let session = testAuthSession()
        let client = testClient(store: plainStore, session: session)

        unlock.disable(client: client)

        XCTAssertTrue(client.store === plainStore, "no swap when already off")
        XCTAssertEqual(client.currentSession, session)
        XCTAssertEqual(plainStore.load(), session, "the plaintext session must not be cleared by a no-op disable")
    }

    func testEnableWithNoSessionThrowsAndStoresNothing() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = testClient(store: InMemorySessionStore(), session: nil)

        do {
            try await unlock.enable(client: client)
            XCTFail("enable with no session must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .noSession)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(authenticator.evaluateCalled, "must not prompt Face ID with no session to protect")
        XCTAssertNil(keychain.stored)
        XCTAssertFalse(unlock.isEnabled)
    }

    func testEnableCancelledLeavesEverythingOff() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        authenticator.evaluateError = .cancelled
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let plainStore = InMemorySessionStore()
        let client = testClient(store: plainStore, session: testAuthSession())

        do {
            try await unlock.enable(client: client)
            XCTFail("cancelled opt-in must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(keychain.stored, "a cancelled opt-in must store nothing")
        XCTAssertFalse(unlock.isEnabled)
        XCTAssertTrue(client.store === plainStore, "the client must keep its plain store")
        XCTAssertNotNil(client.currentSession)
    }

    func testEnableWithoutBiometricsThrowsAndStoresNothing() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        authenticator.canEvaluateValue = false
        authenticator.kind = .none
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = testClient(store: InMemorySessionStore(), session: testAuthSession())

        do {
            try await unlock.enable(client: client)
            XCTFail("opt-in without biometrics must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .notEnrolled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(authenticator.evaluateCalled, "must not prompt when biometrics cannot evaluate")
        XCTAssertNil(keychain.stored)
        XCTAssertFalse(unlock.isEnabled)
    }
}

// MARK: - Unlock path

final class BiometricUnlockFlowTests: XCTestCase {
    /// The launch state for a opted-in user: the client was built
    /// with the biometric store, whose plain load returns nil, so
    /// the app starts with no live session — exactly what boot()
    /// sees before the auth screen offers Face ID.
    private func optedInClient(
        keychain: MockBiometricKeychain,
        session: AuthSession,
        transport: HTTPTransport? = nil
    ) -> SupabaseClient {
        let store = BiometricSessionStore(keychain: keychain)
        keychain.stored = try! JSONEncoder().encode(session)
        return SupabaseClient(
            configuration: testConfiguration(),
            store: store,
            transport: transport ?? StubTransport(handler: { _ in StubTransport.raw("") })
        )
    }

    func testUnlockRestoresSessionWithoutPassword() async throws {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let session = testAuthSession(expiresIn: 3600)
        let client = optedInClient(keychain: keychain, session: session)
        XCTAssertNil(client.currentSession, "boot starts with no live session for an opted-in user")

        let restored = try await unlock.unlock(client: client)

        XCTAssertEqual(restored, session)
        XCTAssertEqual(client.currentSession, session)
        XCTAssertTrue(authenticator.evaluateCalled)
    }

    func testUnlockWithNothingStoredNeverPrompts() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = testClient(store: InMemorySessionStore(), session: nil)

        do {
            _ = try await unlock.unlock(client: client)
            XCTFail("unlock with nothing stored must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .noStoredSession)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(
            authenticator.evaluateCalled,
            "Face ID must never prompt when no protected session exists — this is what keeps the UI tests prompt-free"
        )
    }

    func testUnlockWithChangedBiometricsDeletesItemAndFallsBack() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = optedInClient(keychain: keychain, session: testAuthSession())
        keychain.invalidated = true

        do {
            _ = try await unlock.unlock(client: client)
            XCTFail("unlock with changed biometrics must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .biometricsChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(keychain.stored, "the invalidated item must be deleted")
        XCTAssertFalse(unlock.isEnabled)
        XCTAssertTrue(client.store is UserDefaultsSessionStore, "the client must fall back to the plain store")
        XCTAssertNil(client.currentSession, "no session may survive a failed unlock")
    }

    func testUnlockWithExpiredRefreshDropsItemAndFallsBack() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        // The stored session is stale, and GoTrue refuses the
        // refresh (dead refresh token) — the session is dead.
        let refusedRefresh = StubTransport(handler: { _ in
            StubTransport.json(
                ["error": "invalid_grant",
                 "error_description": "Invalid Refresh Token: Refresh Token Not Found"],
                status: 400)
        })
        let client = optedInClient(
            keychain: keychain,
            session: testAuthSession(expiresIn: -60),
            transport: refusedRefresh)

        do {
            _ = try await unlock.unlock(client: client)
            XCTFail("unlock with a dead refresh token must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(keychain.stored, "the dead session must be dropped from the Keychain")
        XCTAssertFalse(unlock.isEnabled)
        XCTAssertTrue(client.store is UserDefaultsSessionStore, "the client must fall back to the plain store")
        XCTAssertNil(client.currentSession)
    }

    func testUnlockWhenBiometricsRemovedDeletesStaleItem() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        authenticator.canEvaluateValue = false
        authenticator.kind = .none
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = optedInClient(keychain: keychain, session: testAuthSession())

        do {
            _ = try await unlock.unlock(client: client)
            XCTFail("unlock with biometrics removed must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .notEnrolled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(authenticator.evaluateCalled, "must not prompt when biometrics cannot evaluate")
        XCTAssertNil(keychain.stored, "the now-unreadable item must be deleted")
        XCTAssertTrue(client.store is UserDefaultsSessionStore)
    }

    func testUnlockCancelledKeepsItemForRetry() async {
        let keychain = MockBiometricKeychain()
        let authenticator = MockBiometricAuthenticator()
        authenticator.evaluateError = .cancelled
        let unlock = testUnlock(keychain: keychain, authenticator: authenticator)
        let client = optedInClient(keychain: keychain, session: testAuthSession())

        do {
            _ = try await unlock.unlock(client: client)
            XCTFail("cancelled unlock must throw")
        } catch let error as BiometricUnlockError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNotNil(keychain.stored, "a cancelled unlock must keep the item so the user can retry")
        XCTAssertTrue(unlock.isEnabled)
        XCTAssertNil(client.currentSession)
    }

    func testRestoreSessionInstallsSessionDirectly() {
        let store = InMemorySessionStore()
        let client = testClient(store: store, session: nil)
        let session = testAuthSession()

        client.restoreSession(session)

        XCTAssertEqual(client.currentSession, session)
        XCTAssertEqual(store.load(), session)
    }
}

// MARK: - Launch store selection + no-biometrics path

final class BiometricAvailabilityTests: XCTestCase {
    func testSessionStoreForLaunchPicksBiometricStoreWhenItemExists() throws {
        let keychain = MockBiometricKeychain()
        keychain.stored = try JSONEncoder().encode(testAuthSession())

        let store = BiometricUnlock.sessionStoreForLaunch(keychain: keychain)
        XCTAssertTrue(store is BiometricSessionStore)
    }

    func testSessionStoreForLaunchPicksPlainStoreWhenNoItemExists() {
        let store = BiometricUnlock.sessionStoreForLaunch(keychain: MockBiometricKeychain())
        XCTAssertTrue(store is UserDefaultsSessionStore)
    }

    func testNoBiometricsMeansUnavailableAndDisabled() {
        let authenticator = MockBiometricAuthenticator()
        authenticator.canEvaluateValue = false
        authenticator.kind = .none
        let unlock = testUnlock(keychain: MockBiometricKeychain(), authenticator: authenticator)

        XCTAssertFalse(unlock.canEvaluate)
        XCTAssertEqual(unlock.biometryKind, .none)
        XCTAssertFalse(unlock.isEnabled, "no item can exist when biometrics were never available")
        XCTAssertEqual(unlock.label, "Unlock with Face ID", "label falls back to Face ID wording")
    }

    func testTouchIDLabel() {
        let authenticator = MockBiometricAuthenticator()
        authenticator.kind = .touchID
        let unlock = testUnlock(keychain: MockBiometricKeychain(), authenticator: authenticator)

        XCTAssertEqual(unlock.label, "Unlock with Touch ID")
    }
}
