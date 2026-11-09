import Foundation
import GitCore

/// The hosting provider family. GitLab covers GitLab.com and self-managed instances (design §4.1, ADR-0035).
public enum ProviderKind: String, Codable, Sendable, Hashable, CaseIterable {
    case github
    case gitlab

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }
}

public enum Transport: String, Codable, Sendable, Hashable, CaseIterable {
    case https
    case ssh

    public var title: String { self == .https ? "HTTPS" : "SSH" }
}

/// Stable identifiers. Provider instances for the SaaS hosts use fixed IDs so profiles survive re-creation.
public struct ProviderInstanceID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let github = ProviderInstanceID(rawValue: "github.com")
    public static let gitlab = ProviderInstanceID(rawValue: "gitlab.com")
    public static func new() -> ProviderInstanceID { ProviderInstanceID(rawValue: UUID().uuidString) }
}

public struct HostingAccountID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> HostingAccountID { HostingAccountID(rawValue: UUID().uuidString) }
}

public struct ProxyConfigID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ProxyConfigID { ProxyConfigID(rawValue: UUID().uuidString) }
}

/// How requests to a host reach it (design §4.10). `inheritGlobal` = the global network section's choice.
public enum ProxyMode: Codable, Sendable, Hashable {
    case inheritGlobal
    case system
    case direct
    case manual(ManualProxy)

    public var title: String {
        switch self {
        case .inheritGlobal: "Same as global"
        case .system: "System settings"
        case .direct: "No proxy"
        case .manual(let proxy): "\(proxy.kind.title) \(proxy.host):\(proxy.port)"
        }
    }
}

/// A manually configured proxy. The password (if any) lives in the Keychain under `id`; never in this value.
public struct ManualProxy: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case http
        case https
        case socks5

        public var title: String {
            switch self {
            case .http: "HTTP"
            case .https: "HTTPS"
            case .socks5: "SOCKS5"
            }
        }
    }

    public var id: ProxyConfigID
    public var kind: Kind
    public var host: String
    public var port: Int
    public var username: String?

    public init(id: ProxyConfigID = .new(), kind: Kind, host: String, port: Int, username: String? = nil) {
        self.id = id
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }

    /// Hostname: letters, digits, `-`, `.`; or an IPv4 literal. Port 1–65535. Anything else is refused,
    /// because these values reach Git `-c` options and an SSH ProxyCommand argv.
    public var isValid: Bool { HostSyntax.isHostname(host) && (1...65_535).contains(port) }
}

/// A GitHub.com, GitLab.com or self-managed GitLab server (design §4.1). Non-secret configuration only.
public struct ProviderInstance: Codable, Sendable, Hashable, Identifiable {
    public let id: ProviderInstanceID
    public var kind: ProviderKind
    public var name: String
    /// Scheme + host + optional port + optional path prefix (`https://git.corp.example:8443/gitlab`).
    public var webBaseURL: URL
    /// Derived from `webBaseURL` unless overridden.
    public var apiBaseURLOverride: URL?
    public var sshHost: String
    public var sshPort: Int
    /// Self-managed GitLab: the application ID the admin registered; SaaS: from `OAuthClients.plist`.
    public var oauthClientID: String?
    /// IDs of CA certificates stored in `AppSupport/Jit/ca/` (design §4.10).
    public var caCertificateIDs: [String]
    public var proxy: ProxyMode

    public init(
        id: ProviderInstanceID, kind: ProviderKind, name: String, webBaseURL: URL, apiBaseURLOverride: URL? = nil,
        sshHost: String, sshPort: Int = 22, oauthClientID: String? = nil, caCertificateIDs: [String] = [],
        proxy: ProxyMode = .inheritGlobal
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.webBaseURL = webBaseURL
        self.apiBaseURLOverride = apiBaseURLOverride
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.oauthClientID = oauthClientID
        self.caCertificateIDs = caCertificateIDs
        self.proxy = proxy
    }

    public static let github = ProviderInstance(
        id: .github, kind: .github, name: "GitHub", webBaseURL: URL.fixed("github.com"),
        sshHost: "github.com")
    public static let gitlab = ProviderInstance(
        id: .gitlab, kind: .gitlab, name: "GitLab.com", webBaseURL: URL.fixed("gitlab.com"),
        sshHost: "gitlab.com")

    public var isSelfManaged: Bool { id != .github && id != .gitlab }

    /// GitHub → `https://api.github.com`; GitLab → `<web base>/api/v4` (path prefix kept).
    public var apiBaseURL: URL {
        if let apiBaseURLOverride { return apiBaseURLOverride }
        switch kind {
        case .github:
            if webBaseURL.host?.lowercased() == "github.com" { return URL.fixed("api.github.com") }
            return webBaseURL.appendingPathComponent("api/v3")
        case .gitlab:
            return webBaseURL.appendingPathComponent("api/v4")
        }
    }

    /// Lowercased host of the web/API base.
    public var httpsHost: String { webBaseURL.host?.lowercased() ?? "" }
    public var httpsPort: Int { webBaseURL.port ?? (webBaseURL.scheme?.lowercased() == "http" ? 80 : 443) }
    /// `https://host[:port]/prefix/` — the URL Git `-c http.<url>.*` options are scoped to.
    public var gitURLPrefix: String {
        var text = "\(webBaseURL.scheme?.lowercased() ?? "https")://\(httpsHost)"
        if let port = webBaseURL.port { text += ":\(port)" }
        let path = webBaseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { text += "/" + path }
        return text + "/"
    }

    /// Whether an HTTPS remote (host, port, path) belongs to this instance (host, port and path prefix match).
    public func matchesHTTPS(host: String, port: Int, path: String) -> Bool {
        guard host.lowercased() == httpsHost, port == httpsPort else { return false }
        let prefix = webBaseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty { return true }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed == prefix || trimmed.hasPrefix(prefix + "/")
    }

    public func matchesSSH(host: String, port: Int) -> Bool {
        host.lowercased() == sshHost.lowercased() && port == sshPort
    }
}

/// What Jit last observed about an account — never refreshed in the background (design §4.8).
public enum AccountStatus: String, Codable, Sendable, Hashable {
    case unknown
    case ok
    case expired
    case rejected

    public var title: String {
        switch self {
        case .unknown: "Not checked"
        case .ok: "Signed in"
        case .expired: "Expired"
        case .rejected: "Rejected"
        }
    }

    public var needsAttention: Bool { self == .expired || self == .rejected }
}

public enum AuthMethod: String, Codable, Sendable, Hashable {
    case pat
    case oauth

    public var title: String { self == .pat ? "Personal access token" : "Browser sign-in" }
}

/// A hosting account (GitHub / GitLab user) whose token lives in the Keychain under its `id`.
public struct HostingAccount: Codable, Sendable, Hashable, Identifiable {
    public let id: HostingAccountID
    public let instanceID: ProviderInstanceID
    public var login: String
    public var userID: String
    public var displayName: String?
    public var method: AuthMethod
    public var scopes: [String]
    public var expiresAt: Date?
    public var status: AccountStatus
    public var lastCheckedAt: Date?

    public init(
        id: HostingAccountID = .new(), instanceID: ProviderInstanceID, login: String, userID: String,
        displayName: String? = nil, method: AuthMethod, scopes: [String] = [], expiresAt: Date? = nil,
        status: AccountStatus = .ok, lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.instanceID = instanceID
        self.login = login
        self.userID = userID
        self.displayName = displayName
        self.method = method
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.status = status
        self.lastCheckedAt = lastCheckedAt
    }
}

/// Which SSH key a profile uses (design §4.6). Key files are referenced by path; the passphrase, if the user
/// chose to remember it, is in the Keychain under the fingerprint.
public enum SSHIdentity: Codable, Sendable, Hashable {
    /// Keys loaded in ssh-agent (`SSH_AUTH_SOCK` passed through).
    case agent
    case keyFile(path: String, fingerprint: String)

    public var fingerprint: String? {
        if case .keyFile(_, let fingerprint) = self { return fingerprint }
        return nil
    }
}

/// How a profile authenticates to remotes (§10.3) — separate from who commits.
public struct ProfileAuth: Codable, Sendable, Hashable {
    public var instanceID: ProviderInstanceID
    /// The HTTPS/API account; `nil` = SSH only.
    public var accountID: HostingAccountID?
    public var preferredTransport: Transport
    public var ssh: SSHIdentity?
    /// Off by default: SSH runs with `-F none` so another identity's `~/.ssh/config` rules can't apply.
    public var useUserSSHConfig: Bool

    public init(
        instanceID: ProviderInstanceID, accountID: HostingAccountID? = nil, preferredTransport: Transport = .https,
        ssh: SSHIdentity? = nil, useUserSSHConfig: Bool = false
    ) {
        self.instanceID = instanceID
        self.accountID = accountID
        self.preferredTransport = preferredTransport
        self.ssh = ssh
        self.useUserSSHConfig = useUserSSHConfig
    }
}

/// Global network settings: the proxy used for GitHub.com/GitLab.com and inherited by instances, plus
/// optional CA certificates for TLS-intercepting proxies, scoped to a host list (never global trust).
public struct GlobalNetworkConfig: Codable, Sendable, Hashable {
    public var proxy: ProxyMode
    public var caCertificateIDs: [String]

    public init(proxy: ProxyMode = .system, caCertificateIDs: [String] = []) {
        self.proxy = proxy
        self.caCertificateIDs = caCertificateIDs
    }
}

/// Syntax checks for values that end up in Git options or SSH argv.
public enum HostSyntax {
    public static func isHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !value.hasPrefix("-"), !value.hasPrefix(".") else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value < 128) && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == ".")
        }
    }
}

extension URL {
    /// Fixed SaaS URLs built from components (no force unwraps).
    fileprivate static func fixed(_ host: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
