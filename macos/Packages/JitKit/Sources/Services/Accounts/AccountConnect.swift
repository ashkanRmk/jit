import Foundation
import GitCore

/// The four places an account can live, as shown in Settings ▸ Accounts (spec P8.accounts.1): the two SaaS
/// hosts, and self-hosted servers of each family (added by host domain, no separate server setup).
public enum AccountTab: String, CaseIterable, Sendable, Identifiable {
    case github
    case githubEnterprise
    case gitlab
    case gitlabSelfManaged

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .githubEnterprise: "GitHub Enterprise"
        case .gitlab: "GitLab"
        case .gitlabSelfManaged: "GitLab Self-Managed"
        }
    }

    public var kind: ProviderKind {
        switch self {
        case .github, .githubEnterprise: .github
        case .gitlab, .gitlabSelfManaged: .gitlab
        }
    }

    /// Self-hosted tabs ask for a host domain; the SaaS tabs have a fixed server.
    public var isSelfHosted: Bool { self == .githubEnterprise || self == .gitlabSelfManaged }

    /// The built-in server of a SaaS tab.
    public var fixedInstance: ProviderInstance? {
        switch self {
        case .github: .github
        case .gitlab: .gitlab
        case .githubEnterprise, .gitlabSelfManaged: nil
        }
    }

    public static func tab(for instance: ProviderInstance) -> AccountTab {
        switch (instance.kind, instance.isSelfManaged) {
        case (.github, false): .github
        case (.github, true): .githubEnterprise
        case (.gitlab, false): .gitlab
        case (.gitlab, true): .gitlabSelfManaged
        }
    }
}

/// Turns what a person types into "Host Domain" into the server's web base URL.
public enum HostDomain {
    /// Accepts `git.corp.example`, `git.corp.example:8443/gitlab` or a full `https://…` URL (trailing slashes
    /// dropped). Refuses `http://` and any other scheme, credentials, queries, fragments and malformed hosts —
    /// the result reaches Git `-c http.<url>.*` options and carries a token.
    public static func webBaseURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if let range = value.range(of: "://") {
            guard value[..<range.lowerBound].lowercased() == "https" else { return nil }
        } else {
            value = "https://" + value
        }
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(), HostSyntax.isHostname(host) || host == "localhost",
            host.contains(".") || host == "localhost",
            components.user == nil, components.password == nil, components.query == nil,
            components.fragment == nil
        else { return nil }
        if let port = components.port, !(1...65_535).contains(port) { return nil }
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = host
        clean.port = components.port == 443 ? nil : components.port
        clean.path = components.path
        return clean.url
    }
}

/// Why Connect didn't save an account. Plain language; never contains the token.
public enum ConnectAccountError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidHost
    case emptyToken
    /// The server answered 401.
    case rejected(server: String)
    /// The token is valid but belongs to someone else than the account being replaced.
    case differentUser(found: String, expected: String)
    case provider(ProviderError)
    case keychain(String)
    case failed

    public var description: String {
        switch self {
        case .invalidHost:
            "Enter the server's domain, such as git.mycompany.com. Only https:// servers are supported."
        case .emptyToken: "Paste a personal access token."
        case .rejected(let server):
            "\(server) rejected this token. Check that you copied it completely and that it hasn't expired."
        case .differentUser(let found, let expected):
            "This token belongs to @\(found), not @\(expected)."
        case .provider(let error): error.description
        case .keychain(let reason): "The Keychain refused to store the token: \(reason)"
        case .failed: "Jit couldn't check the token."
        }
    }
}

extension AccountsService {
    /// The server a Connect on `tab` talks to: the built-in instance, an existing self-hosted server with the
    /// same address, or a new unsaved one named after its host. `github.com` / `gitlab.com` typed into a
    /// self-hosted tab resolve to the built-in instance of that family.
    public func connectInstance(tab: AccountTab, host: String) -> ProviderInstance? {
        if let fixed = tab.fixedInstance { return fixed }
        guard let url = HostDomain.webBaseURL(host), let hostName = url.host else { return nil }
        let builtIn: ProviderInstance = tab.kind == .github ? .github : .gitlab
        if hostName == builtIn.httpsHost, url.port == nil, url.path.isEmpty { return builtIn }
        if hostName == "github.com" || hostName == "gitlab.com" { return nil }
        if let existing = profiles.customInstances.first(where: {
            $0.kind == tab.kind && $0.httpsHost == hostName && $0.httpsPort == (url.port ?? 443)
                && $0.webBaseURL.path == url.path
        }) {
            return existing
        }
        return ProviderInstance(id: .new(), kind: tab.kind, name: hostName, webBaseURL: url, sshHost: hostName)
    }

    /// One-step Connect (spec P8.accounts.1): checks `token` against the server (`GET /user` + token info) and,
    /// only if it is accepted, stores it in the Keychain and records the account — and the server, if it is new.
    /// Connecting a user who already has an account on that server replaces that account's token. Nothing is
    /// saved on any failure.
    public func connect(tab: AccountTab, host: String = "", token: SecretBytes) async
        -> Result<HostingAccount, ConnectAccountError>
    {
        guard let instance = connectInstance(tab: tab, host: host) else { return .failure(.invalidHost) }
        return await connect(instance: instance, token: token)
    }

    public func connect(instance: ProviderInstance, token: SecretBytes, replacing: HostingAccount? = nil) async
        -> Result<HostingAccount, ConnectAccountError>
    {
        guard !token.isEmpty else { return .failure(.emptyToken) }
        let provider = await provider(instance: instance, method: .pat, token: token)
        let user: ProviderUser
        let info: TokenInfo
        do {
            if let github = provider as? GitHubProvider {
                (user, info) = try await github.userAndTokenInfo()
            } else {
                user = try await provider.currentUser()
                info = (try? await provider.tokenInfo()) ?? TokenInfo(scopes: [], scopesKnown: false)
            }
        } catch let error as ProviderError {
            return .failure(error == .unauthorized ? .rejected(server: instance.name) : .provider(error))
        } catch {
            return .failure(.failed)
        }
        if let replacing, replacing.userID != user.id {
            return .failure(.differentUser(found: user.login, expected: replacing.login))
        }
        let existing =
            replacing
            ?? profiles.accounts.first { $0.instanceID == instance.id && $0.userID == user.id }
        let account = HostingAccount(
            id: existing?.id ?? .new(), instanceID: instance.id, login: user.login, userID: user.id,
            displayName: user.name, method: .pat, scopes: info.scopes, expiresAt: info.expiresAt, status: .ok,
            lastCheckedAt: Date())
        // The server record goes in first so the account never points at an unknown instance; a Keychain
        // failure takes it out again.
        let isNewInstance = instance.isSelfManaged && profiles.instance(instance.id) == nil
        if isNewInstance { profiles.upsertInstance(instance) }
        do throws(KeychainError) {
            try await saveAccount(account, secret: token, instanceName: instance.name)
        } catch {
            if isNewInstance { profiles.removeInstance(instance.id) }
            return .failure(.keychain(error.description))
        }
        return .success(account)
    }
}
