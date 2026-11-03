import XCTest
@testable import OnBudgetCore

final class APIContractTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    func testMissingNullAndZeroRemainDistinct() throws {
        let value = try decode(WeekSnapshotResponse.self, #"{"temp_cents":null,"available_cents":0,"future_field":"future"}"#)
        XCTAssertEqual(value.baseAvailableCents, .missing)
        XCTAssertEqual(value.tempCents, .null)
        XCTAssertEqual(value.availableCents, .value(0))
        let roundTrip = try JSONDecoder().decode(WeekSnapshotResponse.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundTrip, value)
        XCTAssertEqual(roundTrip.raw.field("future_field"), .value(.string("future")))
    }
    func testCentsRejectFractionalStringAndOverflow() {
        for bad in ["1.5", "\"100\"", "9223372036854775808", "true"] {
            XCTAssertThrowsError(try decode(WeekSnapshotResponse.self, "{\"available_cents\":\(bad)}"))
        }
    }
    func testEnvelopeDoesNotInventSuccess() throws {
        for json in ["{}", #"{"result":null}"#, #"{"error":null}"#] {
            let response = try decode(OperationResponse<WeekSnapshotResponse>.self, json)
            XCTAssertThrowsError(try response.requireResult()) { XCTAssertEqual($0 as? ContractError, .absentResult) }
            XCTAssertEqual(try JSONDecoder().decode(OperationResponse<WeekSnapshotResponse>.self, from: JSONEncoder().encode(response)), response)
        }
    }
    func testErrorCodeAndNullableDetailsPreserved() throws {
        let response = try decode(OperationResponse<APIRecord>.self, #"{"error":{"code":"future_error","details":null,"retry_after":12}}"#)
        XCTAssertThrowsError(try response.requireResult()) { error in
            guard case .server(let record) = error as? ContractError else { return XCTFail("Expected server failure") }
            XCTAssertEqual(record.field("code"), .value(.string("future_error")))
            XCTAssertEqual(record.field("details"), .null)
            XCTAssertEqual(record.field("message"), .missing)
        }
    }
    func testContradictoryEnvelopeRejected() throws {
        let response = try decode(OperationResponse<APIRecord>.self, #"{"result":{},"error":{"code":"conflict"}}"#)
        XCTAssertThrowsError(try response.requireResult()) { XCTAssertEqual($0 as? ContractError, .ambiguousEnvelope) }
    }
    func testSuccessfulEnvelopeAndStableOperationRoundTrip() throws {
        let id = UUID()
        let request = OperationRequest(operationID: id, payload: APIRecord(fields: ["amount_cents": .integer(42)]))
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(OperationRequest<APIRecord>.self, from: data), request)
        let response = try decode(OperationResponse<APIRecord>.self, "{\"operation_id\":\"\(id)\",\"result\":{\"state\":\"future\"}}")
        XCTAssertEqual(response.operationID, .value(id))
        XCTAssertEqual(try response.requireResult().field("state"), .value(.string("future")))
    }
    func testMalformedEnvelopeAndIdentifierFailClosed() {
        for json in ["[]", #"{"operation_id":"bad","result":{}}"#, #"{"error":"bad"}"#] {
            XCTAssertThrowsError(try decode(OperationResponse<APIRecord>.self, json))
        }
    }
    func testAllFreshnessStatesAndUnknownRoundTrip() throws {
        for state in ["fresh", "stale", "never_synced", "disconnected", "unavailable", "future"] {
            let response = try decode(SourceFreshnessResponse.self, "{\"state\":\"\(state)\",\"updated_at\":null}")
            XCTAssertEqual(response.updatedAt, .null)
            XCTAssertEqual(response.state, .value(try decode(SourceFreshness.self, "\"\(state)\"")))
            XCTAssertEqual(try JSONDecoder().decode(SourceFreshnessResponse.self, from: JSONEncoder().encode(response)), response)
        }
        XCTAssertEqual(try decode(SourceFreshnessResponse.self, "{}").state, .missing)
        XCTAssertEqual(try decode(SourceFreshnessResponse.self, #"{"state":null}"#).state, .null)
    }
    func testTimestampRetainedWithoutDeviceFreshnessGuess() throws {
        for timestamp in ["2099-01-01T00:00:00Z", "not-a-date"] {
            let response = try decode(SourceFreshnessResponse.self, "{\"updated_at\":\"\(timestamp)\"}")
            XCTAssertEqual(response.updatedAt, .value(timestamp))
            XCTAssertEqual(response.state, .missing)
        }
    }
    func testUnknownJSONStructureAndNumbersRoundTrip() throws {
        let value = try decode(APIRecord.self, #"{"a":[null,true,12,1.25,"x",{"future":false}]}"#)
        XCTAssertEqual(try JSONDecoder().decode(APIRecord.self, from: JSONEncoder().encode(value)), value)
    }
    func testRetryPolicyIsConservativeAndNeverAutomatic() {
        XCTAssertEqual(OperationFailure(ServiceError.responseLost).retry, .reconcileSameOperation)
        XCTAssertTrue(OperationFailure(CancellationError()).outcomeUnknown)
        XCTAssertEqual(OperationFailure(ServiceError.offline).retry, .manualSameOperation)
        for error in [ServiceError.forbidden, .invalidRequest, .idempotencyConflict, .signedOut] {
            XCTAssertEqual(OperationFailure(error).retry, .doNotRetry)
        }
        struct UnknownFailure: Error {}
        XCTAssertTrue(OperationFailure(UnknownFailure()).outcomeUnknown)
    }
}

@MainActor
final class OperationRecoveryTests: XCTestCase {
    func testInterleavedLostResponsesKeepBothOperationIDs() async throws {
        let store = HouseholdStore()
        await store.openSample(.admin)
        let count = try XCTUnwrap(store.snapshot).requests.count
        store.scenario = .responseLost
        await store.refresh()
        let first = HouseholdAction.request(transactionID: nil, amount: Money(cents: 100), note: "first")
        let second = HouseholdAction.request(transactionID: nil, amount: Money(cents: 200), note: "second")
        let a = await store.submit(first)
        guard case .failed(let firstID, let failure) = store.writeState else { return XCTFail("Expected unknown outcome") }
        XCTAssertFalse(a); XCTAssertTrue(failure.outcomeUnknown)
        let b = await store.submit(second)
        XCTAssertFalse(b)
        let retry = await store.submit(first)
        XCTAssertTrue(retry)
        XCTAssertEqual(store.writeState, .succeeded(firstID))
        let retrySecond = await store.submit(second)
        XCTAssertTrue(retrySecond)
        XCTAssertEqual(store.snapshot?.requests.count, count + 2)
        await store.signOut()
        XCTAssertEqual(store.writeState, .idle)
    }
    func testCancelledTaskCannotMutateMockAndCanExplicitlyRetry() async throws {
        let store = HouseholdStore()
        await store.openSample(.admin)
        let count = store.snapshot?.requests.count
        let action = HouseholdAction.request(transactionID: nil, amount: Money(cents: 100), note: "cancelled")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.submit(action)
        }
        let result = await task.value
        XCTAssertFalse(result)
        guard case .failed(let id, let failure) = store.writeState else { return XCTFail("Expected cancellation state") }
        XCTAssertTrue(failure.outcomeUnknown)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.requests.count, count)
        let retry = await store.submit(action)
        XCTAssertTrue(retry)
        XCTAssertEqual(store.writeState, .succeeded(id))
        XCTAssertEqual(store.snapshot?.requests.count, count.map { $0 + 1 })
    }
}

extension APIContractTests {
    func testLegacyDecoderRejectsErrorAlongsideSuccess() {
        let week = #"{"week_start":"2026-11-01","base_available_cents":37500,"temp_cents":0,"carried_debt_cents":0,"charges_cents":0,"available_cents":37500,"week_locked":false,"pending_refund_excluded_cents":0}"#
        let ambiguous = "{\"result\":\(week),\"error\":{\"code\":\"future\"}}"
        XCTAssertThrowsError(try BackendContracts.decodeWeek(Data(ambiguous.utf8)))
    }
}

extension OperationRecoveryTests {
    func testCancellationAfterCommitReconcilesWithSameID() async {
        let service = CancelAfterCommitService()
        let store = HouseholdStore(service: service)
        await store.openSample(.admin)
        let first = await store.submit(.bankSync)
        XCTAssertFalse(first)
        guard case .failed(let id, let failure) = store.writeState else { return XCTFail("Expected ambiguous cancellation") }
        XCTAssertTrue(failure.outcomeUnknown)
        let retry = await store.submit(.bankSync)
        XCTAssertTrue(retry)
        XCTAssertEqual(store.writeState, .succeeded(id))
        let commits = await service.commitCount
        XCTAssertEqual(commits, 1)
    }
    func testCancelledRefreshKeepsSnapshotReadOnlyUntilExplicitRefresh() async {
        let store = HouseholdStore()
        await store.openSample(.admin)
        let before = store.snapshot
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh()
        }.value
        XCTAssertEqual(store.snapshot, before)
        XCTAssertNotNil(store.readError)
        XCTAssertFalse(store.canWrite)
        await store.refresh()
        XCTAssertTrue(store.canWrite)
    }
}
private actor CancelAfterCommitService: SampleHouseholdService {
    var commitCount = 0
    private var committed: UUID?
    func openSample(role: Role) -> Session { Session(role: role, displayName: "Synthetic") }
    func setScenario(_ scenario: SampleScenario) {}
    func signOut() { committed = nil }
    func snapshot() -> HouseholdSnapshot { Fixtures.snapshot() }
    func submit(_ action: HouseholdAction, idempotencyKey: UUID) throws -> ActionReceipt {
        if committed == idempotencyKey { return ActionReceipt(message: "Synthetic replay") }
        committed = idempotencyKey; commitCount += 1
        throw CancellationError()
    }
}

extension APIContractTests {
    func testWriteAcknowledgementRequiresMatchingOperationID() throws {
        let id = UUID()
        for identifier in ["", "\"operation_id\":null,", "\"operation_id\":\"\(UUID())\","] {
            let response = try decode(OperationResponse<APIRecord>.self, "{\(identifier)\"result\":{}}")
            XCTAssertThrowsError(try response.requireResult(for: id)) { XCTAssertEqual($0 as? ContractError, .operationMismatch) }
        }
        let response = try decode(OperationResponse<APIRecord>.self, "{\"operation_id\":\"\(id)\",\"result\":{}}")
        XCTAssertEqual(try response.requireResult(for: id), APIRecord(fields: [:]))
    }
    func testTypedExistingRequestsRoundTripInsideProposedEnvelope() throws {
        let request = OperationRequest(operationID: UUID(), payload: BackendContracts.ApproveRequest(requestID: "synthetic-request", amountCents: 125, overrideReason: nil))
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(OperationRequest<BackendContracts.ApproveRequest>.self, from: data), request)
        let raw = try JSONDecoder().decode(APIRecord.self, from: data)
        guard case .value(.object(let payload)) = raw.field("payload") else { return XCTFail("Missing payload") }
        XCTAssertEqual(payload["override_reason"], .null)
    }
}
