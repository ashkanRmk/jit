import Foundation

/// GitHub REST client (api.github.com) for one account (design §4.7, ADR-0037).
public struct GitHubProvider: HostingProvider {
    public let instance: ProviderInstance
    private let http: ProviderHTTP
    private let token: TokenProvider

    static let perPage = 50

    /// - Parameters:
    ///   - token: returns the account's token just in time (PAT or OAuth access token — both go as `Bearer`).
    ///   - now: clock used for `retry-after` arithmetic (tests).
    public init(
        instance: ProviderInstance = .github, transport: any HTTPTransport, token: @escaping TokenProvider,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.instance = instance
        http = ProviderHTTP(transport: transport, now: now)
        self.token = token
    }

    private var api: URL { instance.apiBaseURL }

    private func get(_ url: URL, authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let secret = authenticated ? try await token() : nil
        return try await http.send(request, token: secret, auth: .bearer, kind: .github)
    }

    private func endpoint(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        guard let url = ProviderHTTP.url(api, path: path, query: query) else { throw ProviderError.invalidResponse }
        return url
    }

    // MARK: HostingProvider

    public func currentUser() async throws -> ProviderUser {
        let (data, _) = try await get(endpoint("user"))
        return try http.decode(GitHubUser.self, from: data).model
    }

    /// Scopes from `X-OAuth-Scopes` (absent/empty → fine-grained PAT or GitHub App token), expiry from
    /// `github-authentication-token-expiration`.
    public func tokenInfo() async throws -> TokenInfo {
        try await userAndTokenInfo().token
    }

    /// One `GET /user` yielding both the user and the token info (PAT validation, design §4.8).
    public func userAndTokenInfo() async throws -> (user: ProviderUser, token: TokenInfo) {
        let (data, response) = try await get(endpoint("user"))
        let user = try http.decode(GitHubUser.self, from: data).model
        let headers = Headers(response)
        let expiresAt = ProviderDates.githubExpiration(headers["github-authentication-token-expiration"])
        guard let header = headers["x-oauth-scopes"]?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return (user, TokenInfo(scopes: [], expiresAt: expiresAt, fineGrained: true, scopesKnown: false))
        }
        let scopes = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (user, TokenInfo(scopes: scopes, expiresAt: expiresAt, fineGrained: false, scopesKnown: true))
    }

    /// `GET /user/repos` (owner, collaborator, organization member), 50 per page, `Link` pagination.
    /// `query` is ignored: GitHub has no server-side filter for this list — the UI filters loaded pages and
    /// offers `searchAll(query:login:orgs:)` explicitly.
    public func repositories(page: PageCursor?, query: String?) async throws -> RepositoryPage {
        let url: URL
        switch page?.storage {
        case .url(let next)?:
            guard ProviderHTTP.isSameOrigin(next, as: api) else { throw ProviderError.invalidResponse }
            url = next
        case .page(let number)?:
            url = try endpoint("user/repos", listQuery + [("page", String(number))])
        case nil:
            url = try endpoint("user/repos", listQuery)
        }
        let (data, response) = try await get(url)
        let items = try http.decode([GitHubRepository].self, from: data).map(\.model)
        let next = ProviderHTTP.nextLink(Headers(response)["link"], sameOriginAs: api)
        return RepositoryPage(items: items, next: next.map { PageCursor(.url($0)) })
    }

    private var listQuery: [(String, String)] {
        [
            ("per_page", String(Self.perPage)), ("sort", "updated"),
            ("affiliation", "owner,collaborator,organization_member"),
        ]
    }

    /// "Search all accessible repositories": `GET /search/repositories?q=<query> user:<login> org:<org>…`,
    /// first page only (≤ 50 results, bounded and explicit). Logins/orgs that aren't valid GitHub names are
    /// skipped so they can't inject qualifiers.
    public func searchAll(query: String, login: String, orgs: [String]) async throws -> [RemoteRepository] {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return [] }
        var q = terms
        if Self.isValidName(login) { q += " user:\(login)" }
        for org in orgs where Self.isValidName(org) { q += " org:\(org)" }
        let url = try endpoint("search/repositories", [("q", q), ("per_page", String(Self.perPage))])
        let (data, _) = try await get(url)
        return try http.decode(GitHubSearchResult.self, from: data).items.map(\.model)
    }

    /// Organizations of the signed-in user (`GET /user/orgs`, first 100) — input for `searchAll`.
    public func organizations() async throws -> [String] {
        let (data, _) = try await get(endpoint("user/orgs", [("per_page", "100")]))
        return try http.decode([GitHubOrg].self, from: data).map(\.login)
    }

    /// `GET https://api.github.com/meta` → `ssh_key_fingerprints` (unauthenticated; github.com only).
    public func publishedSSHFingerprints() async throws -> [String] {
        guard instance.httpsHost == "github.com" else { return [] }
        let (data, _) = try await get(endpoint("meta"), authenticated: false)
        let meta = try http.decode(GitHubMeta.self, from: data)
        return (meta.sshKeyFingerprints ?? [:]).sorted { $0.key < $1.key }.map { value in
            value.value.hasPrefix("SHA256:") ? value.value : "SHA256:" + value.value
        }
    }

    /// GitHub login/organization syntax: alphanumerics and single hyphens, ≤ 39 characters.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 39, !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}

// MARK: Payloads

private struct GitHubUser: Decodable {
    let id: Int64
    let login: String
    let name: String?
    let avatarUrl: String?
    let htmlUrl: String?

    var model: ProviderUser {
        ProviderUser(
            id: String(id), login: login, name: name, avatarURL: avatarUrl.flatMap(URL.init(string:)),
            webURL: htmlUrl.flatMap(URL.init(string:)))
    }
}

private struct GitHubRepository: Decodable {
    struct Owner: Decodable { let login: String }
    let id: Int64
    let name: String
    let fullName: String
    let owner: Owner
    let description: String?
    let `private`: Bool?
    let visibility: String?
    let defaultBranch: String?
    let cloneUrl: String?
    let sshUrl: String?
    let htmlUrl: String?
    let updatedAt: String?

    var model: RemoteRepository {
        let resolved =
            visibility.flatMap(RepositoryVisibility.init(rawValue:))
            ?? `private`.map { $0 ? .private : .public }
        return RemoteRepository(
            id: String(id), owner: owner.login, name: name, fullName: fullName, description: description,
            visibility: resolved, defaultBranch: defaultBranch, httpsCloneURL: cloneUrl.flatMap(URL.init(string:)),
            sshCloneURL: sshUrl, webURL: htmlUrl.flatMap(URL.init(string:)),
            updatedAt: ProviderDates.iso8601(updatedAt))
    }
}

private struct GitHubSearchResult: Decodable {
    let items: [GitHubRepository]
}

private struct GitHubOrg: Decodable {
    let login: String
}

private struct GitHubMeta: Decodable {
    let sshKeyFingerprints: [String: String]?
}
