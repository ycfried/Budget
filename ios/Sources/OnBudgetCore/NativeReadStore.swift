import Foundation
#if canImport(SwiftUI)
import Observation
#endif

#if canImport(SwiftUI)
@Observable
#endif
@MainActor
public final class NativeReadStore {
    private let client: NativeReadClient?
    public private(set) var memberships: [NativeMembership] = []
    public private(set) var selectedHousehold: UUID?
    public private(set) var week: WeekSnapshotResponse?
    public private(set) var page: NativeReadPage?
    public private(set) var loading = false
    public private(set) var signedIn = false
    public private(set) var error: String?
    private var generation = 0
    public var configured: Bool { client != nil }
    /// App composition deliberately supplies nil until first-connection approval.
    public init(client: NativeReadClient? = nil) { self.client = client }
    public func signIn(email: String, password: String) async {
        guard !loading else { return }
        guard let client else { error = ConnectionError.approvalRequired.localizedDescription; return }
        loading = true
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            try await client.signIn(email: email, password: password)
            let rows = try await client.memberships()
            guard generation == current else { return }
            memberships = rows; signedIn = true; error = nil
            // Household selection is explicit, never a guess based on array order.
        } catch {
            guard generation == current else { return }
            try? await client.signOutLocally()
            self.error = Self.message(error)
        }
    }
    public func restoreSession() async {
        guard !loading, let client else { return }
        loading = true
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            try await client.restore()
            let rows = try await client.memberships()
            guard generation == current else { return }
            memberships = rows; signedIn = true; error = nil
        } catch {
            guard generation == current else { return }
            try? await client.signOutLocally()
            self.error = Self.message(error)
        }
    }
    public func select(_ household: UUID) {
        guard !loading, memberships.contains(where: { $0.householdID == household && $0.knownRole != nil }) else { return }
        generation += 1; selectedHousehold = household; week = nil; page = nil; error = nil
    }
    public func load(_ relation: ReadRelation, offset: Int = 0) async {
        guard !loading, let client, let household = selectedHousehold else { return }
        loading = true; page = nil
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            let response = try await client.page(relation, household: household, offset: offset)
            guard generation == current else { return }
            page = response; error = nil
        } catch { if generation == current { self.error = Self.message(error) } }
    }
    public func loadWeek() async {
        guard !loading, let client, let household = selectedHousehold else { return }
        loading = true; week = nil
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            let response = try await client.week(household: household)
            guard generation == current else { return }
            week = response; error = nil
        } catch { if generation == current { self.error = Self.message(error) } }
    }
    public func signOut() async {
        generation += 1; memberships = []; selectedHousehold = nil; week = nil; page = nil
        loading = false; signedIn = false; error = nil
        do { try await client?.signOutLocally() }
        catch { self.error = Self.message(error) }
    }
    private static func message(_ error: any Error) -> String {
        // Never publish decoder descriptions, request URLs, body or provider errors.
        (error as? ConnectionError)?.localizedDescription ?? "The response could not be loaded safely. Retry explicitly."
    }
}
