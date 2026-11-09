import Foundation

/// The one seam provider clients and OAuth use to reach the network (ADR-0037). Tests substitute a stub.
public protocol HTTPTransport: Sendable {
    /// Performs `request` and returns the body and HTTP response. Transport failures throw `URLError`.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed transport. One instance per provider instance, so proxy and trust policy stay scoped
/// (design §4.7, §4.10). Cross-origin redirects are refused so credentials never follow a redirect off-host.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// - Parameters:
    ///   - configuration: usually `URLSessionTransport.defaultConfiguration()` with proxy/trust settings added.
    ///   - delegate: optional session delegate (e.g. server-trust evaluation for custom CAs). Retained until
    ///     this transport is released.
    public init(
        configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration(),
        delegate: (any URLSessionDelegate)? = nil
    ) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Ephemeral, no URL cache, no cookies, no cached responses, 30 s request timeout.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }
}

/// Follows a redirect only when scheme, host and port are unchanged; otherwise the 3xx response is returned.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SameOriginRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url.flatMap(URLOrigin.init),
            let to = request.url.flatMap(URLOrigin.init),
            from == to
        else { return nil }
        return request
    }
}

/// Scheme + host + port, lowercased, default ports filled in.
struct URLOrigin: Hashable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "http" ? 80 : 443)
    }
}
