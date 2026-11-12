import XCTest
@testable import OnBudgetKit

/// Roles (owner decision, Nov 11, 2026) + per-field sign-in errors.
///
/// Roles: one owner = the household creator (`households.owner_id`);
/// the owner keeps role `.admin`, so every admin check keeps passing
/// for the owner. These tests pin the client-side contracts: role
/// labels/notes, the owner-id read, the promote/demote RPC, and the
/// unauthenticated email-existence check behind the per-field
/// sign-in messages.
final class RolesAndSignInTests: XCTestCase {

    // MARK: - Role labels and capability notes

    func testRoleLabels() {
        XCTAssertEqual(HouseholdRole.owner.label, "Owner")
        XCTAssertEqual(HouseholdRole.admin.label, "Admin")
        XCTAssertEqual(HouseholdRole.member.label, "Member")
    }

    func testRoleCapabilityNotes() {
        // Each note must name what the role can do, in plain language.
        XCTAssertTrue(HouseholdRole.owner.capabilityNote.contains("remove members"))
        XCTAssertTrue(HouseholdRole.owner.capabilityNote.contains("invite code"))
        XCTAssertEqual(HouseholdRole.admin.capabilityNote, "Full access except removing members.")
        XCTAssertEqual(HouseholdRole.member.capabilityNote, "Regular member.")
    }

    func testStoredRolesStillDecode() throws {
        // The server only ever returns 'admin' / 'member' — 'owner'
        // is a display role derived from households.owner_id, never
        // a stored value.
        XCTAssertEqual(try JSONDecoder().decode(HouseholdRole.self, from: Data("\"admin\"".utf8)), .admin)
        XCTAssertEqual(try JSONDecoder().decode(HouseholdRole.self, from: Data("\"member\"".utf8)), .member)
    }

    // MARK: - households.owner_id read

    func testHouseholdOwnerIdSelectsOwnerIdAndFiltersById() async throws {
        let householdId = UUID()
        let ownerId = UUID()
        let transport = StubTransport(handler: { _ in StubTransport.json([["owner_id": ownerId.uuidString]]) })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let read = try await client.householdOwnerId(householdId: householdId)
        XCTAssertEqual(read, ownerId)
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.path, "/rest/v1/households")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["select"], "owner_id")
        XCTAssertEqual(query["id"], "eq.\(householdId.uuidString)")
        XCTAssertNil(query["household_id"], "households-table reads must not filter on household_id")
    }

    func testHouseholdOwnerIdIsNilWhenUnrecorded() async throws {
        let transport = StubTransport(handler: { _ in StubTransport.json([["owner_id": NSNull()]]) })
        let client = PostgrestClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let read = try await client.householdOwnerId(householdId: UUID())
        XCTAssertNil(read)
    }

    // MARK: - set_household_member_role RPC

    func testSetHouseholdMemberRoleSendsExactNameAndParams() async throws {
        let memberId = UUID()
        let transport = StubTransport(handler: { _ in StubTransport.raw("") })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        try await client.setHouseholdMemberRole(pUserId: memberId, pRole: .admin)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(transport.requests[0].url?.path, "/rest/v1/rpc/set_household_member_role")
        let body = jsonBody(of: transport.requests[0])
        XCTAssertEqual(body["p_user_id"] as? String, memberId.uuidString)
        XCTAssertEqual(body["p_role"] as? String, "admin")
    }

    func testSetHouseholdMemberRoleDemoteSendsMember() async throws {
        let memberId = UUID()
        let transport = StubTransport(handler: { _ in StubTransport.raw("") })
        let client = RPCClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        try await client.setHouseholdMemberRole(pUserId: memberId, pRole: .member)
        XCTAssertEqual(jsonBody(of: transport.requests[0])["p_role"] as? String, "member")
    }

    // MARK: - check-email-exists (unauthenticated)

    func testCheckEmailExistsSendsNoAuthorizationHeader() async throws {
        let transport = StubTransport(handler: { _ in StubTransport.json(["exists": true]) })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        let exists = try await client.checkEmailExists(email: "someone@example.com")
        XCTAssertTrue(exists)
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/functions/v1/check-email-exists")
        // The anon key goes out; no session token exists at sign-in
        // failure, and none may be attached.
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_P2phsf7AYX38dbmxOEZKzQ_uw168MZP")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(jsonBody(of: request)["email"] as? String, "someone@example.com")
    }

    func testCheckEmailExistsReturnsFalse() async throws {
        let transport = StubTransport(handler: { _ in StubTransport.json(["exists": false]) })
        let client = EdgeFunctionsClient(
            configuration: testConfiguration(),
            tokenProvider: testTokenProvider(),
            transport: transport
        )
        XCTAssertFalse(try await client.checkEmailExists(email: "nobody@example.com"))
    }

    // MARK: - Per-field sign-in wording

    func testSignInErrorMessagePerField() {
        XCTAssertEqual(SignInErrorMessage.invalidCredentials(emailExists: true), "Password is incorrect.")
        XCTAssertEqual(SignInErrorMessage.invalidCredentials(emailExists: false), "Username is incorrect.")
        // The check could not run: generic, never a guessed field.
        XCTAssertEqual(SignInErrorMessage.invalidCredentials(emailExists: nil), "Username or password is incorrect.")
    }

    func testInvalidCredentialsCaseHasPlainMessage() {
        XCTAssertEqual(OnBudgetError.invalidCredentials.userMessage, "Username or password is incorrect.")
        XCTAssertFalse(OnBudgetError.invalidCredentials.isRetryable)
    }

    // MARK: - displayMessage (never raw server text on screen)

    func testDisplayMessagePassesSpecificRefusalsThrough() {
        XCTAssertEqual(OnBudgetError.adminOnly("admin only").displayMessage, "admin only")
        XCTAssertEqual(OnBudgetError.weekLocked("week is locked: test").displayMessage, "week is locked: test")
        XCTAssertEqual(OnBudgetError.rateLimited("too many failed join attempts, try again later").displayMessage,
                       "too many failed join attempts, try again later")
        XCTAssertEqual(OnBudgetError.validationFailed("Amount: enter a positive amount.").displayMessage,
                       "Amount: enter a positive amount.")
    }

    func testDisplayMessageMapsRawServerTextToGeneric() {
        // The owner's Nov 11, 2026 report: this exact string reached
        // the Settings screen. It must never be shown again.
        XCTAssertEqual(
            OnBudgetError.serverError(status: 500, message: "column households.household_id does not exist").displayMessage,
            "Could not complete that. Try again.")
        XCTAssertEqual(OnBudgetError.decodingError("keyNotFound").displayMessage, "Could not complete that. Try again.")
        XCTAssertEqual(OnBudgetError.unknown("weird").displayMessage, "Could not complete that. Try again.")
        XCTAssertEqual(OnBudgetError.networkError("The Internet connection appears to be offline.").displayMessage,
                       "Could not complete that. Try again.")
        XCTAssertEqual(OnBudgetError.displayMessage(for: NSError(domain: "x", code: 1)),
                       "Could not complete that. Try again.")
    }
}
