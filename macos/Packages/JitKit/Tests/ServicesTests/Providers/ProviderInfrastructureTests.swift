import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import Services

// MARK: Cache

@Suite struct CacheProviderTests {
    func page(_ name: String) -> RepositoryPage {
        RepositoryPage(items: [RemoteRepository(id: name, owner: "o", name: name, fullName: "o/\(name)")], next: nil)
    }

    @Test func entriesExpireAfterTTL() {
        let clock = ProviderTestClock()
        let cache = RepositoryCache(now: clock.closure)
        let key = RepositoryCache.Key(accountID: HostingAccountID(rawValue: "a"), query: "  jit ")
        cache.store(page("one"), for: key)
        clock.advance(299)
        #expect(
            cache.page(for: RepositoryCache.Key(accountID: HostingAccountID(rawValue: "a"), query: "jit"))
                == page("one"))
        clock.advance(1)
        #expect(cache.page(for: key) == nil)
        #expect(cache.count == 0)
    }

    @Test func evictsExpiredThenOldest() {
        let clock = ProviderTestClock()
        let cache = RepositoryCache(ttl: 300, maxEntries: 2, now: clock.closure)
        let account = HostingAccountID(rawValue: "a")
        let keys = (0..<3).map { RepositoryCache.Key(accountID: account, query: "q\($0)") }
        cache.store(page("0"), for: keys[0])
        clock.advance(1)
        cache.store(page("1"), for: keys[1])
        clock.advance(1)
        cache.store(page("2"), for: keys[2])
        #expect(cache.count == 2)
        #expect(cache.page(for: keys[0]) == nil)
        #expect(cache.page(for: keys[1]) == page("1"))
        #expect(cache.page(for: keys[2]) == page("2"))
    }

    @Test func fetchesOnMissOnlyAndClearsPerAccount() async throws {
        let clock = ProviderTestClock()
        let cache = RepositoryCache(now: clock.closure)
        let a = RepositoryCache.Key(accountID: HostingAccountID(rawValue: "a"))
        let b = RepositoryCache.Key(accountID: HostingAccountID(rawValue: "b"))
        let fetches = Locked(0)
        for _ in 0..<3 {
            _ = try await cache.page(for: a) {
                fetches.withLock { $0 += 1 }
                return page("a")
            }
        }
        #expect(fetches.withLock { $0 } == 1)
        cache.store(page("b"), for: b)
        cache.removeAll(accountID: HostingAccountID(rawValue: "a"))
        #expect(cache.page(for: a) == nil)
        #expect(cache.page(for: b) == page("b"))
        cache.removeAll()
        #expect(cache.count == 0)
    }
}

// MARK: URLSession transport (URLProtocol stub)

/// Routes requests by host so parallel tests don't share handlers.
final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> ProviderStubResponse
    static let handlers = Mutex<[String: Handler]>([:])

    static func register(host: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let stub = try handler(request)
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite struct TransportProviderTests {
    func transport() -> URLSessionTransport {
        let configuration = URLSessionTransport.defaultConfiguration()
        configuration.protocolClasses = [ProviderURLProtocol.self]
        return URLSessionTransport(configuration: configuration)
    }

    func instance(host: String) -> ProviderInstance {
        ProviderInstance(
            id: ProviderInstanceID(rawValue: host), kind: .gitlab, name: host,
            webBaseURL: URL(string: "https://\(host)") ?? ProviderInstance.gitlab.webBaseURL, sshHost: host)
    }

    @Test func defaultConfigurationIsEphemeralAndCookieless() {
        let configuration = URLSessionTransport.defaultConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func endToEndThroughURLSession() async throws {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        let seen = Locked<URLRequest?>(nil)
        ProviderURLProtocol.register(host: host) { request in
            seen.withLock { $0 = request }
            return .json(#"{"id":7,"username":"bob","name":"Bob"}"#)
        }
        let gitlab = GitLabProvider(
            instance: instance(host: host), method: .pat, transport: transport(),
            token: { SecretBytes(utf8: "glpat-e2e") })
        let user = try await gitlab.currentUser()
        #expect(user.login == "bob")
        let request = try #require(seen.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-e2e")
        #expect(request.url?.absoluteString == "https://\(host)/api/v4/user")
    }

    @Test func urlErrorsBecomeClassifiedTransportErrors() async throws {
        let cases: [(URLError.Code, ProviderError.TransportFailure)] = [
            (.notConnectedToInternet, .offline), (.cannotFindHost, .dns), (.serverCertificateUntrusted, .tls),
            (.timedOut, .timeout), (.cannotConnectToHost, .unreachable),
        ]
        for (code, expected) in cases {
            let host = "stub-\(UUID().uuidString.lowercased()).test"
            ProviderURLProtocol.register(host: host) { _ in throw URLError(code) }
            let gitlab = GitLabProvider(
                instance: instance(host: host), method: .pat, transport: transport(), token: { SecretBytes(utf8: "t") })
            do {
                _ = try await gitlab.currentUser()
                Issue.record("expected a transport error for \(code)")
            } catch {
                // Exhaustive catch + explicit rethrow: Swift 6.3 SILGen crashes on non-exhaustive typed catches (CI, Xcode 26).
                guard let providerError = error as? ProviderError else { throw error }
                #expect(providerError.transportFailure == expected)
            }
        }
        #expect(
            ProviderError.classify(URLError(.cannotConnectToHost, userInfo: ["_kCFStreamErrorCodeKey": 310])) == .proxy)
    }
}

// MARK: Secrets never leak into errors

@Suite struct SecretLeakProviderTests {
    static let sentinel = "ghp_SENTINEL_9f8e7d6c5b4a"

    func assertClean(_ error: any Error, _ context: String) {
        let renderings = [
            String(describing: error), String(reflecting: error), error.localizedDescription, "\(error)",
            (error as NSError).description, (error as NSError).userInfo.description,
        ]
        for text in renderings {
            #expect(!text.contains(Self.sentinel), "\(context): \(text)")
        }
        if case ProviderError.transport(let underlying) = error {
            #expect(!"\(underlying)".contains(Self.sentinel), "\(context): underlying URLError")
        }
        if case OAuthError.request(.transport(let underlying)) = error {
            #expect(!"\(underlying)".contains(Self.sentinel), "\(context): underlying URLError")
        }
    }

    @Test func tokenNeverAppearsInThrownErrors() async throws {
        let echo = #"{"message":"token \#(Self.sentinel) is not allowed","error":"\#(Self.sentinel)"}"#
        let leakyURLError = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLErrorKey: URL(string: "https://api.github.com/user?access_token=\(Self.sentinel)")
                    as Any,
                NSLocalizedDescriptionKey: "failed with \(Self.sentinel)",
            ])
        let responses: [@Sendable (URLRequest) throws -> ProviderStubResponse] = [
            { _ in .json(echo, status: 401) }, { _ in .json(echo, status: 403) },
            { _ in .json(echo, status: 403, headers: ["x-ratelimit-remaining": "0"]) },
            { _ in .json(echo, status: 404) },
            { _ in .json(echo, status: 500) }, { _ in .json(echo, status: 429) },
            { _ in .json("not json \(Self.sentinel)") },
            { _ in throw leakyURLError },
        ]
        var errorCount = 0
        for (index, respond) in responses.enumerated() {
            let transport = ProviderStubTransport(respond)
            let token: TokenProvider = { SecretBytes(utf8: Self.sentinel) }
            let github = GitHubProvider(transport: transport, token: token)
            let gitlab = GitLabProvider(instance: .gitlab, method: .pat, transport: transport, token: token)
            let calls: [@Sendable () async throws -> Void] = [
                { _ = try await github.currentUser() }, { _ = try await github.tokenInfo() },
                { _ = try await github.repositories(page: nil, query: nil) },
                { _ = try await gitlab.currentUser() }, { _ = try await gitlab.repositories(page: nil, query: "x") },
                { _ = try await gitlab.version() },
                {
                    _ = try await GitLabOAuthClient(instance: .gitlab, clientID: "c", transport: transport).refresh(
                        SecretBytes(utf8: Self.sentinel))
                },
                {
                    try await GitLabOAuthClient(instance: .gitlab, clientID: "c", transport: transport).revoke(
                        SecretBytes(utf8: Self.sentinel))
                },
            ]
            for (callIndex, call) in calls.enumerated() {
                do {
                    try await call()
                } catch {
                    errorCount += 1
                    assertClean(error, "response \(index), call \(callIndex)")
                }
            }
        }
        #expect(errorCount > 40)

        // Forbidden messages that echo the token are dropped entirely.
        let forbidden = ProviderStubTransport { _ in .json(echo, status: 403) }
        await #expect(throws: ProviderError.forbidden("")) {
            try await GitHubProvider(transport: forbidden, token: { SecretBytes(utf8: Self.sentinel) }).currentUser()
        }
    }

    @Test func tokenValuesAreRedactedInDescriptions() {
        let tokens = OAuthTokens(
            access: SecretBytes(utf8: Self.sentinel), refresh: SecretBytes(utf8: Self.sentinel), expiresAt: nil)
        #expect(!String(describing: tokens).contains(Self.sentinel))
        #expect(!String(reflecting: tokens).contains(Self.sentinel))
    }
}
