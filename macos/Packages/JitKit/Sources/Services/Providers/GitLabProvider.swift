import Foundation

/// GitLab REST v4 client for GitLab.com and self-managed instances (design §4.7, ADR-0037).
public struct GitLabProvider: HostingProvider {
    /// Oldest GitLab Jit supports (ADR-0037): `/personal_access_tokens/self`, `/projects?membership`, PKCE.
    public static let minimumSupportedGitLab = SemanticVersion(15, 0)

    public let instance: ProviderInstance
    public let method: AuthMethod
    private let http: ProviderHTTP
    private let token: TokenProvider

    static let perPage = 50

    /// - Parameters:
    ///   - method: `.pat` sends `PRIVATE-TOKEN`; `.oauth` sends `Authorization: Bearer`.
    ///   - token: returns the token just in time (for OAuth, after any refresh — see `OAuthRefresher`).
    public init(
        instance: ProviderInstance, method: AuthMethod, transport: any HTTPTransport, token: @escaping TokenProvider,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.instance = instance
        self.method = method
        http = ProviderHTTP(transport: transport, now: now)
        self.token = token
    }

    private var api: URL { instance.apiBaseURL }
    private var auth: ProviderHTTP.AuthHeader { method == .pat ? .privateToken : .bearer }

    private func get(_ url: URL, auth: ProviderHTTP.AuthHeader? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let secret = try await token()
        let (data, response) = try await http.send(request, token: secret, auth: auth ?? self.auth, kind: .gitlab)
        // A reverse proxy or the GitLab web UI answering instead of the API: wrong base URL / path prefix.
        if let type = Headers(response)["content-type"]?.lowercased(), type.contains("text/html") {
            throw ProviderError.wrongPathPrefix
        }
        return (data, response)
    }

    private func endpoint(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        guard let url = ProviderHTTP.url(api, path: path, query: query) else { throw ProviderError.invalidResponse }
        return url
    }

    // MARK: HostingProvider

    public func currentUser() async throws -> ProviderUser {
        let (data, _) = try await get(endpoint("user"))
        return try http.decode(GitLabUser.self, from: data).model
    }

    /// PAT: `GET /personal_access_tokens/self`. OAuth: `GET <web base>/oauth/token/info`. A 404 (older GitLab,
    /// other token types) yields `scopesKnown == false` instead of an error.
    public func tokenInfo() async throws -> TokenInfo {
        do {
            switch method {
            case .pat:
                let (data, _) = try await get(endpoint("personal_access_tokens/self"))
                let info = try http.decode(GitLabTokenSelf.self, from: data)
                return TokenInfo(scopes: info.scopes ?? [], expiresAt: ProviderDates.dateOnly(info.expiresAt))
            case .oauth:
                guard let url = ProviderHTTP.url(instance.webBaseURL, path: "oauth/token/info") else {
                    throw ProviderError.invalidResponse
                }
                let (data, _) = try await get(url, auth: .bearer)
                let info = try http.decode(GitLabOAuthTokenInfo.self, from: data)
                let seconds = info.expiresIn ?? info.expiresInSeconds
                return TokenInfo(
                    scopes: info.scope?.values ?? info.scopes?.values ?? [],
                    expiresAt: seconds.map { http.now().addingTimeInterval(TimeInterval($0)) })
            }
        } catch ProviderError.notFound {
            return TokenInfo(scopes: [], scopesKnown: false)
        }
    }

    /// `GET /projects?membership=true&simple=true&order_by=last_activity_at&per_page=50[&search=q]`;
    /// next page from `X-Next-Page`, else `Link` (keyset). `simple=true` omits visibility (`nil`).
    public func repositories(page: PageCursor?, query: String?) async throws -> RepositoryPage {
        let url: URL
        var parameters: [(String, String)] = [
            ("membership", "true"), ("simple", "true"), ("order_by", "last_activity_at"),
            ("per_page", String(Self.perPage)),
        ]
        if let search = query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            parameters.append(("search", search))
        }
        switch page?.storage {
        case .url(let next)?:
            guard ProviderHTTP.isSameOrigin(next, as: api) else { throw ProviderError.invalidResponse }
            url = next
        case .page(let number)?:
            url = try endpoint("projects", parameters + [("page", String(number))])
        case nil:
            url = try endpoint("projects", parameters)
        }
        let (data, response) = try await get(url)
        let items = try http.decode([GitLabProject].self, from: data).map(\.model)
        let headers = Headers(response)
        if let nextPage = headers["x-next-page"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), nextPage > 0
        {
            return RepositoryPage(items: items, next: PageCursor(.page(nextPage)))
        }
        let next = ProviderHTTP.nextLink(headers["link"], sameOriginAs: api)
        return RepositoryPage(items: items, next: next.map { PageCursor(.url($0)) })
    }

    /// GitLab publishes SSH host-key fingerprints only in its HTML documentation — there is no official
    /// machine-readable source (ADR-0037), so the UI shows the fingerprint without comparison.
    public func publishedSSHFingerprints() async throws -> [String] { [] }

    // MARK: Version

    /// `GET /version` (authenticated). 404 or a non-JSON answer → `.wrongPathPrefix`.
    public func version() async throws -> SemanticVersion {
        let data: Data
        do {
            (data, _) = try await get(endpoint("version"))
        } catch ProviderError.notFound {
            throw ProviderError.wrongPathPrefix
        }
        guard let payload = try? JSONDecoder().decode(GitLabVersion.self, from: data),
            let version = SemanticVersion(parsing: payload.version)
        else { throw ProviderError.wrongPathPrefix }
        return version
    }

    /// Fetches the version and throws `.unsupportedVersion` when it's older than `minimumSupportedGitLab`.
    @discardableResult
    public func validateServer() async throws -> SemanticVersion {
        let version = try await version()
        try Self.checkSupported(version)
        return version
    }

    public static func checkSupported(_ version: SemanticVersion) throws {
        if version < minimumSupportedGitLab { throw ProviderError.unsupportedVersion(version.raw) }
    }
}

// MARK: Payloads

private struct GitLabUser: Decodable {
    let id: Int64
    let username: String
    let name: String?
    let avatarUrl: String?
    let webUrl: String?

    var model: ProviderUser {
        ProviderUser(
            id: String(id), login: username, name: name, avatarURL: avatarUrl.flatMap(URL.init(string:)),
            webURL: webUrl.flatMap(URL.init(string:)))
    }
}

private struct GitLabTokenSelf: Decodable {
    let scopes: [String]?
    let expiresAt: String?
}

/// Doorkeeper token info: `scope` is an array on current GitLab; accept a space-separated string too.
private struct GitLabOAuthTokenInfo: Decodable {
    struct Scopes: Decodable {
        let values: [String]
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([String].self) {
                values = array
            } else {
                values = try container.decode(String.self).split(separator: " ").map(String.init)
            }
        }
    }
    let scope: Scopes?
    let scopes: Scopes?
    let expiresIn: Int?
    let expiresInSeconds: Int?
}

private struct GitLabProject: Decodable {
    struct Namespace: Decodable { let fullPath: String? }
    let id: Int64
    let name: String
    let pathWithNamespace: String
    let namespace: Namespace?
    let description: String?
    let visibility: String?
    let defaultBranch: String?
    let httpUrlToRepo: String?
    let sshUrlToRepo: String?
    let webUrl: String?
    let lastActivityAt: String?

    var model: RemoteRepository {
        let owner = namespace?.fullPath ?? pathWithNamespace.split(separator: "/").dropLast().joined(separator: "/")
        return RemoteRepository(
            id: String(id), owner: owner, name: name, fullName: pathWithNamespace, description: description,
            visibility: visibility.flatMap(RepositoryVisibility.init(rawValue:)), defaultBranch: defaultBranch,
            httpsCloneURL: httpUrlToRepo.flatMap(URL.init(string:)), sshCloneURL: sshUrlToRepo,
            webURL: webUrl.flatMap(URL.init(string:)), updatedAt: ProviderDates.iso8601(lastActivityAt))
    }
}

private struct GitLabVersion: Decodable {
    let version: String
}
