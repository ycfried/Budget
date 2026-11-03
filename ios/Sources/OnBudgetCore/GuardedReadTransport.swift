import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class DenyReadRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Prepared executor, not used by app composition. Enabling requires the owner's
/// specific first-connection approval and an exact runtime project origin.
/// Permission is a development gate, never a replacement for server RLS.
public final class GuardedReadTransport: ReadHTTPTransport, @unchecked Sendable {
    private let origin: URL
    private let ownerApprovedConnection: Bool
    private let session: URLSession
    public init(origin: URL, ownerApprovedConnection: Bool = false) throws {
        _ = try ReadBackendConfiguration(origin: origin, publicKey: "configuration-validation-only")
        self.origin = origin; self.ownerApprovedConnection = ownerApprovedConnection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: DenyReadRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func validate(_ request: URLRequest) throws {
        guard ownerApprovedConnection else { throw ConnectionError.approvalRequired }
        guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host,
              url.port == origin.port, url.user == nil, url.password == nil, url.fragment == nil else { throw ConnectionError.invalidConfiguration }
        let getPaths = ["/auth/v1/user", "/rest/v1/household_members"] + ReadRelation.allCases.map { "/rest/v1/\($0.rawValue)" }
        if request.httpMethod == "GET", getPaths.contains(url.path) { return }
        if request.httpMethod == "POST", url.path == "/functions/v1/compute-week", url.query == nil { return }
        if request.httpMethod == "POST", url.path == "/auth/v1/token" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.count == 1, items[0].name == "grant_type",
                  ["password", "refresh_token"].contains(items[0].value) else { throw ConnectionError.invalidConfiguration }
            return
        }
        throw ConnectionError.forbidden
    }
    public func execute(_ request: URLRequest) async throws -> ReadHTTPResponse {
        try validate(request)
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw ConnectionError.invalidResponse }
        try Task.checkCancellation()
        return ReadHTTPResponse(status: response.statusCode, data: data, contentRange: response.value(forHTTPHeaderField: "Content-Range"))
    }
}
