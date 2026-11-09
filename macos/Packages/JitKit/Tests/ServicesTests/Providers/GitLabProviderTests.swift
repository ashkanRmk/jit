import Foundation
import Testing

@testable import Services

private let gitlabUserJSON = """
    {"id":1,"username":"john_smith","name":"John Smith","state":"active","locked":false,
     "avatar_url":"https://gitlab.example.com/uploads/user/avatar/1/cd8.jpeg","web_url":"https://gitlab.example.com/john_smith"}
    """

private let projectsJSON = """
    [{"id":4,"description":"Lorem ipsum","name":"Diaspora Client","name_with_namespace":"Diaspora / Diaspora Client",
      "path":"diaspora-client","path_with_namespace":"diaspora/sub/diaspora-client","created_at":"2013-09-30T13:46:02Z",
      "default_branch":"main","ssh_url_to_repo":"git@gitlab.example.com:diaspora/sub/diaspora-client.git",
      "http_url_to_repo":"https://gitlab.example.com/diaspora/sub/diaspora-client.git",
      "web_url":"https://gitlab.example.com/diaspora/sub/diaspora-client","last_activity_at":"2013-09-30T13:46:02.000Z",
      "namespace":{"id":2,"name":"Sub","path":"sub","kind":"group","full_path":"diaspora/sub"}},
     {"id":5,"name":"Nameless","path_with_namespace":"alice/nameless","visibility":"internal"}]
    """

@Suite struct GitLabProviderTests {
    static let selfManaged = ProviderInstance(
        id: ProviderInstanceID(rawValue: "corp"), kind: .gitlab, name: "Corp",
        webBaseURL: URL(string: "https://git.corp.example:8443/gitlab") ?? ProviderInstance.gitlab.webBaseURL,
        sshHost: "git.corp.example")

    func provider(
        _ transport: ProviderStubTransport, instance: ProviderInstance = .gitlab, method: AuthMethod = .pat,
        clock: ProviderTestClock = ProviderTestClock()
    ) -> GitLabProvider {
        GitLabProvider(
            instance: instance, method: method, transport: transport, token: { SecretBytes(utf8: "glpat-test") },
            now: clock.closure)
    }

    @Test func currentUserWithPATUsesPrivateTokenHeader() async throws {
        let transport = ProviderStubTransport { _ in .json(gitlabUserJSON) }
        let user = try await provider(transport).currentUser()
        #expect(user.id == "1")
        #expect(user.login == "john_smith")
        #expect(user.name == "John Smith")
        #expect(user.webURL?.absoluteString == "https://gitlab.example.com/john_smith")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://gitlab.com/api/v4/user")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Jit")
    }

    @Test func oauthUsesBearerHeader() async throws {
        let transport = ProviderStubTransport { _ in .json(gitlabUserJSON) }
        _ = try await provider(transport, method: .oauth).currentUser()
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer glpat-test")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    }

    @Test func selfManagedKeepsPathPrefixAndPort() async throws {
        let transport = ProviderStubTransport { _ in .json(gitlabUserJSON) }
        _ = try await provider(transport, instance: Self.selfManaged).currentUser()
        #expect(transport.requests.first?.url?.absoluteString == "https://git.corp.example:8443/gitlab/api/v4/user")
    }

    @Test func patTokenInfoScopesAndDateOnlyExpiry() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                """
                {"id":42,"name":"Jit","revoked":false,"created_at":"2026-01-01T00:00:00.000Z",
                 "scopes":["read_api","read_repository","write_repository"],"user_id":1,"active":true,
                 "expires_at":"2026-12-01"}
                """)
        }
        let info = try await provider(transport).tokenInfo()
        #expect(info.scopes == ["read_api", "read_repository", "write_repository"])
        #expect(info.expiresAt == Date(timeIntervalSince1970: 1_796_083_200))
        #expect(info.scopesKnown)
        #expect(transport.requests.first?.url?.path == "/api/v4/personal_access_tokens/self")
    }

    @Test func tokenInfo404FallsBackToUnknownScopes() async throws {
        let transport = ProviderStubTransport { _ in .json(#"{"message":"404 Not Found"}"#, status: 404) }
        let info = try await provider(transport).tokenInfo()
        #expect(!info.scopesKnown)
        #expect(info.scopes.isEmpty)
        #expect(info.expiresAt == nil)
    }

    @Test func oauthTokenInfoUsesWebBaseEndpoint() async throws {
        let clock = ProviderTestClock()
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"resource_owner_id":1,"scope":["read_api","write_repository"],"expires_in":7200,"application":{"uid":"abc"},"created_at":1575890427}"#
            )
        }
        let info = try await provider(transport, instance: Self.selfManaged, method: .oauth, clock: clock).tokenInfo()
        #expect(info.scopes == ["read_api", "write_repository"])
        #expect(info.expiresAt == clock.now.addingTimeInterval(7200))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://git.corp.example:8443/gitlab/oauth/token/info")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer glpat-test")
    }

    @Test func unauthorizedMapsTo401() async throws {
        let transport = ProviderStubTransport { _ in .json(#"{"message":"401 Unauthorized"}"#, status: 401) }
        await #expect(throws: ProviderError.unauthorized) { try await provider(transport).currentUser() }
        await #expect(throws: ProviderError.unauthorized) { try await provider(transport).tokenInfo() }
    }

    @Test func rateLimitUsesRateLimitReset() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"message":"Retry later"}"#, status: 429,
                headers: ["RateLimit-Reset": "1800000300", "Retry-After": "300"])
        }
        await #expect(throws: ProviderError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_300))) {
            try await provider(transport).currentUser()
        }
        // GitLab 403 is a permission problem, never a rate limit.
        let forbidden = ProviderStubTransport { _ in .json(#"{"message":"403 Forbidden"}"#, status: 403) }
        await #expect(throws: ProviderError.forbidden("403 Forbidden")) { try await provider(forbidden).currentUser() }
    }

    @Test func projectsQueryEncodingAndXNextPagePagination() async throws {
        let transport = ProviderStubTransport(sequence: [
            .json(projectsJSON, headers: ["X-Next-Page": "2", "X-Page": "1"]),
            .json("[]", headers: ["X-Next-Page": "", "X-Page": "2"]),
        ])
        let gitlab = provider(transport)
        let first = try await gitlab.repositories(page: nil, query: " my proj&x=1+ ")
        #expect(first.items.count == 2)
        let project = try #require(first.items.first)
        #expect(project.id == "4")
        #expect(project.owner == "diaspora/sub")
        #expect(project.name == "Diaspora Client")
        #expect(project.fullName == "diaspora/sub/diaspora-client")
        #expect(project.visibility == nil)
        #expect(project.defaultBranch == "main")
        #expect(project.sshCloneURL == "git@gitlab.example.com:diaspora/sub/diaspora-client.git")
        #expect(project.updatedAt == Date(timeIntervalSince1970: 1_380_548_762))
        #expect(first.items[1].owner == "alice")
        #expect(first.items[1].visibility == .internal)

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v4/projects")
        #expect(
            request.url?.query
                == "membership=true&simple=true&order_by=last_activity_at&per_page=50&search=my%20proj%26x%3D1%2B")
        #expect(providerQuery(request)["search"] == "my proj&x=1+")

        #expect(first.next == PageCursor(.page(2)))
        let second = try await gitlab.repositories(page: first.next, query: " my proj&x=1+ ")
        #expect(second.next == nil)
        let secondQuery = providerQuery(try #require(transport.requests.last))
        #expect(secondQuery["page"] == "2")
        #expect(secondQuery["search"] == "my proj&x=1+")
    }

    @Test func projectsFallBackToKeysetLink() async throws {
        let next = "https://gitlab.com/api/v4/projects?pagination=keyset&id_after=5&per_page=50"
        let transport = ProviderStubTransport { _ in .json("[]", headers: ["Link": "<\(next)>; rel=\"next\""]) }
        let page = try await provider(transport).repositories(page: nil, query: nil)
        #expect(page.next == PageCursor(.url(try providerURL(next))))
        #expect(providerQuery(try #require(transport.requests.first))["search"] == nil)
    }

    @Test func versionParsesAndGatesMinimum() async throws {
        let modern = ProviderStubTransport { _ in .json(#"{"version":"16.5.1-ee","revision":"abc","enterprise":true}"#)
        }
        let version = try await provider(modern, instance: Self.selfManaged).validateServer()
        #expect(version == SemanticVersion(16, 5, 1))
        #expect(version.raw == "16.5.1-ee")
        #expect(modern.requests.first?.url?.absoluteString == "https://git.corp.example:8443/gitlab/api/v4/version")

        let old = ProviderStubTransport { _ in .json(#"{"version":"14.10.5","revision":"abc"}"#) }
        await #expect(throws: ProviderError.unsupportedVersion("14.10.5")) {
            try await provider(old, instance: Self.selfManaged).validateServer()
        }
        #expect(SemanticVersion(parsing: "15.0.0-pre") == GitLabProvider.minimumSupportedGitLab)
        #expect(SemanticVersion(parsing: "v1") == nil)
    }

    @Test func wrongPathPrefixDetection() async throws {
        let notFound = ProviderStubTransport { _ in .json(#"{"error":"404 Not Found"}"#, status: 404) }
        await #expect(throws: ProviderError.wrongPathPrefix) {
            try await provider(notFound, instance: Self.selfManaged).version()
        }

        let html = ProviderStubTransport { _ in
            ProviderStubResponse(
                status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<html>".utf8))
        }
        await #expect(throws: ProviderError.wrongPathPrefix) {
            try await provider(html, instance: Self.selfManaged).version()
        }
        await #expect(throws: ProviderError.wrongPathPrefix) {
            try await provider(html, instance: Self.selfManaged).currentUser()
        }

        let notJSON = ProviderStubTransport { _ in .json("ok") }
        await #expect(throws: ProviderError.wrongPathPrefix) {
            try await provider(notJSON, instance: Self.selfManaged).version()
        }
    }

    @Test func gitlabFingerprintsHaveNoMachineReadableSource() async throws {
        let transport = ProviderStubTransport { _ in .json("{}") }
        #expect(try await provider(transport).publishedSSHFingerprints().isEmpty)
        #expect(transport.requests.isEmpty)
    }
}
