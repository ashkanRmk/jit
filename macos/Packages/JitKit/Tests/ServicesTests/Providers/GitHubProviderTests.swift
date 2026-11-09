import Foundation
import Testing

@testable import Services

private let userJSON = """
    {"login":"octocat","id":583231,"node_id":"MDQ6VXNlcjU4MzIzMQ==","avatar_url":"https://avatars.githubusercontent.com/u/583231?v=4",
     "html_url":"https://github.com/octocat","type":"User","name":"The Octocat","company":"@github"}
    """

private let reposJSON = """
    [{"id":1296269,"node_id":"MDEwOlJlcG9zaXRvcnkxMjk2MjY5","name":"Hello-World","full_name":"octocat/Hello-World",
      "owner":{"login":"octocat","id":1},"private":false,"html_url":"https://github.com/octocat/Hello-World",
      "description":"This your first repo!","visibility":"public","default_branch":"main",
      "clone_url":"https://github.com/octocat/Hello-World.git","ssh_url":"git@github.com:octocat/Hello-World.git",
      "updated_at":"2011-01-26T19:14:43Z","permissions":{"admin":false,"push":true,"pull":true}},
     {"id":42,"name":"secret","full_name":"acme/secret","owner":{"login":"acme"},"private":true,
      "description":null,"default_branch":"trunk","clone_url":"https://github.com/acme/secret.git",
      "ssh_url":"git@github.com:acme/secret.git","html_url":"https://github.com/acme/secret","updated_at":null}]
    """

@Suite struct GitHubProviderTests {
    func provider(_ transport: ProviderStubTransport, clock: ProviderTestClock = ProviderTestClock()) -> GitHubProvider
    {
        GitHubProvider(transport: transport, token: { SecretBytes(utf8: "gho_test") }, now: clock.closure)
    }

    @Test func currentUserParsesAndSendsGitHubHeaders() async throws {
        let transport = ProviderStubTransport { _ in .json(userJSON) }
        let user = try await provider(transport).currentUser()
        #expect(
            user
                == ProviderUser(
                    id: "583231", login: "octocat", name: "The Octocat",
                    avatarURL: URL(string: "https://avatars.githubusercontent.com/u/583231?v=4"),
                    webURL: URL(string: "https://github.com/octocat")))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gho_test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Jit")
    }

    @Test func classicTokenScopesAndExpiryFromHeaders() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                userJSON,
                headers: [
                    "X-OAuth-Scopes": "repo, read:org, workflow",
                    "github-authentication-token-expiration": "2026-12-01 10:00:00 UTC",
                ])
        }
        let info = try await provider(transport).tokenInfo()
        #expect(info.scopes == ["repo", "read:org", "workflow"])
        #expect(info.fineGrained == false)
        #expect(info.scopesKnown)
        #expect(info.expiresAt == ProviderDates.githubExpiration("2026-12-01T10:00:00Z"))
        #expect(info.expiresAt == Date(timeIntervalSince1970: 1_796_119_200))
    }

    @Test func fineGrainedTokenHasNoScopesHeader() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                userJSON,
                headers: ["X-OAuth-Scopes": "", "github-authentication-token-expiration": "2027-01-15 08:30:00 +0000"])
        }
        let info = try await provider(transport).tokenInfo()
        #expect(info.fineGrained)
        #expect(info.scopes.isEmpty)
        #expect(!info.scopesKnown)
        #expect(info.expiresAt == Date(timeIntervalSince1970: 1_800_001_800))
    }

    @Test(arguments: [
        ("2026-12-01 10:00:00 UTC", 1_796_119_200.0),
        ("2026-12-01 10:00:00 +0000", 1_796_119_200.0),
        ("2026-12-01 05:00:00 -0500", 1_796_119_200.0),
        ("2026-12-01 12:00:00 +02:00", 1_796_119_200.0),
        ("2026-12-01T10:00:00Z", 1_796_119_200.0),
    ])
    func expirationHeaderFormats(text: String, epoch: Double) {
        #expect(ProviderDates.githubExpiration(text) == Date(timeIntervalSince1970: epoch))
    }

    @Test func expirationHeaderGarbageIsNil() {
        #expect(ProviderDates.githubExpiration("soon") == nil)
        #expect(ProviderDates.githubExpiration("2026-13-01 10:00:00 UTC") == nil)
        #expect(ProviderDates.githubExpiration("2026-12-01 10:00:00 PST") == nil)
    }

    @Test func unauthorizedMapsTo401() async throws {
        let transport = ProviderStubTransport { _ in .json(#"{"message":"Bad credentials"}"#, status: 401) }
        await #expect(throws: ProviderError.unauthorized) { try await provider(transport).currentUser() }
    }

    @Test func primaryRateLimitUsesResetHeader() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"message":"API rate limit exceeded"}"#, status: 403,
                headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000900"])
        }
        await #expect(throws: ProviderError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_900))) {
            try await provider(transport).currentUser()
        }
    }

    @Test func secondaryRateLimitUsesRetryAfter() async throws {
        let clock = ProviderTestClock()
        let transport = ProviderStubTransport { _ in
            .json(#"{"message":"secondary rate limit"}"#, status: 429, headers: ["Retry-After": "60"])
        }
        await #expect(throws: ProviderError.rateLimited(resetAt: clock.now.addingTimeInterval(60))) {
            try await provider(transport, clock: clock).currentUser()
        }
    }

    @Test func plainForbiddenKeepsShortMessage() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"message":"Resource not accessible by personal access token"}"#, status: 403,
                headers: ["x-ratelimit-remaining": "4999"])
        }
        await #expect(throws: ProviderError.forbidden("Resource not accessible by personal access token")) {
            try await provider(transport).currentUser()
        }
    }

    @Test func otherStatusesMap() async throws {
        await #expect(throws: ProviderError.notFound) {
            try await provider(ProviderStubTransport { _ in .json("{}", status: 404) }).currentUser()
        }
        await #expect(throws: ProviderError.server(502)) {
            try await provider(ProviderStubTransport { _ in .json("{}", status: 502) }).currentUser()
        }
        await #expect(throws: ProviderError.invalidResponse) {
            try await provider(ProviderStubTransport { _ in .json("<html>") }).currentUser()
        }
    }

    @Test func repositoriesParseAndFollowLinkPagination() async throws {
        let next =
            "https://api.github.com/user/repos?per_page=50&sort=updated&affiliation=owner%2Ccollaborator%2Corganization_member&page=2"
        let transport = ProviderStubTransport(sequence: [
            .json(
                reposJSON,
                headers: [
                    "Link": "<\(next)>; rel=\"next\", <https://api.github.com/user/repos?page=7>; rel=\"last\""
                ]),
            .json("[]", headers: ["Link": "<https://api.github.com/user/repos?page=1>; rel=\"prev\""]),
        ])
        let github = provider(transport)
        let first = try await github.repositories(page: nil, query: nil)
        #expect(first.items.count == 2)
        let hello = try #require(first.items.first)
        #expect(hello.id == "1296269")
        #expect(hello.owner == "octocat")
        #expect(hello.name == "Hello-World")
        #expect(hello.fullName == "octocat/Hello-World")
        #expect(hello.visibility == .public)
        #expect(hello.defaultBranch == "main")
        #expect(hello.httpsCloneURL?.absoluteString == "https://github.com/octocat/Hello-World.git")
        #expect(hello.sshCloneURL == "git@github.com:octocat/Hello-World.git")
        #expect(hello.updatedAt == Date(timeIntervalSince1970: 1_296_069_283))
        #expect(first.items[1].visibility == .private)
        #expect(first.items[1].description == nil)

        let firstQuery = providerQuery(try #require(transport.requests.first))
        #expect(firstQuery["per_page"] == "50")
        #expect(firstQuery["sort"] == "updated")
        #expect(firstQuery["affiliation"] == "owner,collaborator,organization_member")

        let cursor = try #require(first.next)
        let second = try await github.repositories(page: cursor, query: nil)
        #expect(second.items.isEmpty)
        #expect(second.next == nil)
        #expect(transport.requests.last?.url?.absoluteString == next)
    }

    @Test func nextLinkOnForeignHostIsRefused() async throws {
        let transport = ProviderStubTransport { _ in
            .json(reposJSON, headers: ["Link": "<https://evil.example/user/repos?page=2>; rel=\"next\""])
        }
        let page = try await provider(transport).repositories(page: nil, query: nil)
        #expect(page.next == nil)
        // Also refuse a downgraded scheme or other port on the same host.
        #expect(
            ProviderHTTP.nextLink(
                "<http://api.github.com/x>; rel=\"next\"", sameOriginAs: try providerURL("https://api.github.com"))
                == nil)
        #expect(
            ProviderHTTP.nextLink(
                "<https://api.github.com:8443/x>; rel=\"next\"", sameOriginAs: try providerURL("https://api.github.com")
            ) == nil)
    }

    @Test func foreignCursorIsNeverRequested() async throws {
        let transport = ProviderStubTransport { _ in .json("[]") }
        let cursor = PageCursor(.url(try providerURL("https://evil.example/user/repos?page=2")))
        await #expect(throws: ProviderError.invalidResponse) {
            try await provider(transport).repositories(page: cursor, query: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func searchAllBuildsBoundedQualifiedQuery() async throws {
        let transport = ProviderStubTransport { _ in
            .json(#"{"total_count":1,"incomplete_results":false,"items":\#(reposJSON)}"#)
        }
        let results = try await provider(transport).searchAll(
            query: "c++ lib", login: "octocat", orgs: ["my-org", "bad org", "x user:evil"])
        #expect(results.count == 2)
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/search/repositories")
        #expect(request.url?.query == "q=c%2B%2B%20lib%20user%3Aoctocat%20org%3Amy-org&per_page=50")
        #expect(providerQuery(request)["q"] == "c++ lib user:octocat org:my-org")
        // Empty query: no request.
        #expect(try await provider(transport).searchAll(query: "  ", login: "octocat", orgs: []).isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test func metaFingerprintsAreUnauthenticatedAndPrefixed() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                """
                {"verifiable_password_authentication":false,"ssh_key_fingerprints":{
                 "SHA256_ECDSA":"p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
                 "SHA256_ED25519":"+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
                 "SHA256_RSA":"uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"},"hooks":["192.30.252.0/22"]}
                """)
        }
        let fingerprints = try await provider(transport).publishedSSHFingerprints()
        #expect(
            fingerprints == [
                "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
                "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
                "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
            ])
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/meta")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func credentialUsernames() {
        #expect(gitCredentialUsername(kind: .github, method: .oauth, login: "octocat") == "x-access-token")
        #expect(gitCredentialUsername(kind: .github, method: .pat, login: "octocat") == "octocat")
        #expect(gitCredentialUsername(kind: .gitlab, method: .pat, login: "alice") == "alice")
        #expect(gitCredentialUsername(kind: .gitlab, method: .oauth, login: "alice") == "oauth2")
        #expect(gitCredentialUsername(kind: .gitlab, method: .pat, login: "").isEmpty == false)
    }
}
