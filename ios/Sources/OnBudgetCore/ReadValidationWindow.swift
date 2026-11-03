import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One approved inspection, not a reusable production network session.
/// Limits are consumed before dispatch. No reset or automatic retry exists.
actor ReadValidationWindow {
    private var stopped = false
    private var used: [String: Int] = [:]
    private var requests = 0
    func stop() { stopped = true }
    func admit(_ request: URLRequest) throws {
        guard !stopped else { throw ConnectionError.windowStopped }
        do {
            guard let url = request.url else { throw ConnectionError.invalidConfiguration }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard Set(items.map(\.name)).count == items.count else { throw ConnectionError.forbidden }
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            let key: String
            let limit: Int
            if request.httpMethod == "POST", url.path == "/auth/v1/token" {
                guard query.count == 1, let grant = query["grant_type"], ["password", "refresh_token"].contains(grant) else { throw ConnectionError.forbidden }
                key = grant; limit = 1
                let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
                guard Set(body.keys) == (grant == "password" ? ["email", "password"] : ["refresh_token"]) else { throw ConnectionError.forbidden }
            } else if request.httpMethod == "GET", url.path == "/auth/v1/user" {
                guard query.isEmpty, request.httpBody == nil else { throw ConnectionError.forbidden }
                key = "identity"; limit = 15
            } else if request.httpMethod == "GET", url.path == "/rest/v1/household_members" {
                guard Set(query.keys) == ["select", "user_id"], query["select"] == "household_id,user_id,role,display_name",
                      validFilter(query["user_id"]), request.httpBody == nil else { throw ConnectionError.forbidden }
                key = "membership"; limit = 15
            } else if request.httpMethod == "POST", url.path == "/functions/v1/compute-week" {
                guard query.isEmpty else { throw ConnectionError.forbidden }
                let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
                guard Set(body.keys).isSubset(of: ["household_id", "week_start"]), let id = body["household_id"], UUID(uuidString: id) != nil else { throw ConnectionError.forbidden }
                if let date = body["week_start"] { _ = try PurchaseDate(date) }
                key = "week"; limit = 1
            } else if request.httpMethod == "GET", let relation = ReadRelation.allCases.first(where: { url.path == "/rest/v1/\($0.rawValue)" }) {
                let filter = relation == .households ? "id" : "household_id"
                guard Set(query.keys) == ["select", filter, "order"], query["select"] == relation.columns,
                      query["order"] == "created_at.asc,id.asc", validFilter(query[filter]), request.httpBody == nil,
                      request.value(forHTTPHeaderField: "Range") == "0-99",
                      request.value(forHTTPHeaderField: "Range-Unit") == "items",
                      request.value(forHTTPHeaderField: "Prefer") == "count=exact" else { throw ConnectionError.forbidden }
                key = relation.rawValue; limit = 1
            } else { throw ConnectionError.forbidden }
            guard requests < 46, used[key, default: 0] < limit else { throw ConnectionError.windowLimit }
            used[key, default: 0] += 1; requests += 1
        } catch {
            stopped = true
            throw error
        }
    }
    private func validFilter(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("eq.") else { return false }
        return UUID(uuidString: String(value.dropFirst(3))) != nil
    }
}
