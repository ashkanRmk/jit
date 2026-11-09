import Foundation

/// The signed-in user as the provider reports it.
public struct ProviderUser: Sendable, Hashable {
    public var id: String
    public var login: String
    public var name: String?
    public var avatarURL: URL?
    public var webURL: URL?

    public init(id: String, login: String, name: String? = nil, avatarURL: URL? = nil, webURL: URL? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.webURL = webURL
    }
}

/// What the provider says about the token itself (design §4.8).
public struct TokenInfo: Sendable, Hashable {
    /// Classic OAuth/PAT scopes. Empty when unknown (see `scopesKnown`) or for fine-grained tokens.
    public var scopes: [String]
    public var expiresAt: Date?
    /// GitHub fine-grained PAT or GitHub App token: permissions aren't expressed as scopes.
    public var fineGrained: Bool
    /// `false` when the server couldn't tell us the scopes (older GitLab, fine-grained GitHub tokens).
    public var scopesKnown: Bool

    public init(scopes: [String], expiresAt: Date? = nil, fineGrained: Bool = false, scopesKnown: Bool = true) {
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.fineGrained = fineGrained
        self.scopesKnown = scopesKnown
    }
}

public enum RepositoryVisibility: String, Sendable, Hashable, Codable {
    case `public`
    case `private`
    case `internal`
}

/// An opaque "next page" token. GitHub: the full `Link` next URL (validated same-origin); GitLab: a page number
/// or a `Link` URL for keyset pagination.
public struct PageCursor: Sendable, Hashable {
    enum Storage: Sendable, Hashable {
        case url(URL)
        case page(Int)
    }

    let storage: Storage
    init(_ storage: Storage) { self.storage = storage }
}

public struct RemoteRepository: Sendable, Hashable, Identifiable {
    public var id: String
    /// GitHub owner login; GitLab namespace full path (may contain `/`).
    public var owner: String
    public var name: String
    /// `owner/name` (GitHub) or `path_with_namespace` (GitLab).
    public var fullName: String
    public var description: String?
    /// `nil` when the API didn't say (GitLab `simple=true` omits visibility).
    public var visibility: RepositoryVisibility?
    public var defaultBranch: String?
    public var httpsCloneURL: URL?
    public var sshCloneURL: String?
    public var webURL: URL?
    public var updatedAt: Date?

    public init(
        id: String, owner: String, name: String, fullName: String, description: String? = nil,
        visibility: RepositoryVisibility? = nil, defaultBranch: String? = nil, httpsCloneURL: URL? = nil,
        sshCloneURL: String? = nil, webURL: URL? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.description = description
        self.visibility = visibility
        self.defaultBranch = defaultBranch
        self.httpsCloneURL = httpsCloneURL
        self.sshCloneURL = sshCloneURL
        self.webURL = webURL
        self.updatedAt = updatedAt
    }
}

public struct RepositoryPage: Sendable, Hashable {
    public var items: [RemoteRepository]
    public var next: PageCursor?

    public init(items: [RemoteRepository], next: PageCursor?) {
        self.items = items
        self.next = next
    }
}

/// `major.minor.patch` parsed from text like `16.5.1-ee`; `raw` keeps the server's text for display.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var raw: String

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
        raw = "\(major).\(minor)"
    }

    /// Parses the leading `N[.N[.N]]`; anything after (`-ee`, `-pre`) is ignored. `nil` without a major number.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var numbers: [Int] = []
        var current = ""
        for character in trimmed {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if character == ".", !current.isEmpty, numbers.count < 2 {
                numbers.append(Int(current) ?? 0)
                current = ""
            } else {
                break
            }
        }
        if !current.isEmpty { numbers.append(Int(current) ?? 0) }
        guard let major = numbers.first else { return nil }
        self.major = major
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
        raw = trimmed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    public var description: String { raw }
}

/// The username Git sends with a token over HTTPS (design §4.4).
/// - GitHub OAuth → `x-access-token`; GitHub PAT → the login (GitHub ignores the username for tokens, so both
///   work; the login keeps credential-helper output recognisable).
/// - GitLab PAT → the login (GitLab accepts any non-empty username with a PAT); GitLab OAuth → `oauth2`
///   (required by GitLab for OAuth access tokens).
public func gitCredentialUsername(kind: ProviderKind, method: AuthMethod, login: String) -> String {
    switch (kind, method) {
    case (.github, .oauth): return "x-access-token"
    case (.gitlab, .oauth): return "oauth2"
    case (.github, .pat): return login.isEmpty ? "x-access-token" : login
    case (.gitlab, .pat): return login.isEmpty ? "jit" : login
    }
}
