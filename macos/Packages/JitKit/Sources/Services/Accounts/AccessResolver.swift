import Foundation
import GitCore

/// Why the active profile can't (or may not) authenticate to a remote — attached to failures so the error view
/// can explain and offer "Switch to '<profile>' and Retry" (design §3.4). Never acted on automatically.
public enum AuthMismatch: Sendable, Hashable {
    /// HTTPS remote on a host the profile has no account for (the operation ran anonymously).
    case noAccountForHost(host: String)
    /// The profile's instance matches, but no HTTPS account is connected (SSH-only profile).
    case noHTTPSAccount(host: String)
    /// SSH remote whose host isn't the profile instance's SSH host (the profile's key was still used).
    case sshHostNotInstance(host: String)
    /// No profile auth at all.
    case noProfileAuth
}

/// The result of resolving a profile snapshot for an operation's remote URLs (design §4.2). Pure value: unit
/// tested without Git, Keychain or network.
public struct AccessResolution: Sendable, Hashable {
    public var policy: BrokerPolicy
    public var ssh: SSHPlan?
    public var network: [ScopedNetwork]
    public var mismatches: [AuthMismatch]
    /// Hosts of the operation's remotes (for "Switch to …" suggestions).
    public var remoteHosts: [String]
    public var usesHTTPSCredentials: Bool { !policy.https.isEmpty || !policy.proxies.isEmpty }
}

/// Paths and settings that don't come from the profile.
public struct AccessEnvironment: Sendable, Hashable {
    /// `~/.ssh/known_hosts` — read by ssh, never written by Jit.
    public var userKnownHosts: String
    /// `AppSupport/Jit/known_hosts` — written only through the host-key trust sheet.
    public var jitKnownHosts: String
    /// `AppSupport/Jit/ca` — PEM files named `<certificate id>.pem`.
    public var caDirectory: String
    public var agentAvailable: Bool

    public init(userKnownHosts: String, jitKnownHosts: String, caDirectory: String, agentAvailable: Bool) {
        self.userKnownHosts = userKnownHosts
        self.jitKnownHosts = jitKnownHosts
        self.caDirectory = caDirectory
        self.agentAvailable = agentAvailable
    }

    public static func standard(location: StoreLocation = .applicationSupport()) -> AccessEnvironment {
        AccessEnvironment(
            userKnownHosts: NSHomeDirectory() + "/.ssh/known_hosts",
            jitKnownHosts: location.url("known_hosts").path,
            caDirectory: location.url("ca").path,
            agentAvailable: !(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "").isEmpty)
    }

    public func caPath(_ id: String) -> String { (caDirectory as NSString).appendingPathComponent("\(id).pem") }
}

/// A proxy chosen for one URL by `ProxyResolver` (system/PAC/manual/direct).
public struct ResolvedProxy: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case system
        case pac
        case manual
        case direct
        case exception
    }

    public var proxy: ManualProxy?
    public var source: Source

    public init(proxy: ManualProxy?, source: Source) {
        self.proxy = proxy
        self.source = source
    }

    public static let direct = ResolvedProxy(proxy: nil, source: .direct)
    /// No decision: Git keeps its own behavior for the URL (no `-c http.<url>.proxy`).
    public static let unchanged = ResolvedProxy(proxy: nil, source: .system)
}

public enum AccessResolver {
    /// Resolves credentials, SSH and network policy for `urls` under `snapshot`. `proxyFor` picks the proxy
    /// for a URL (system/PAC resolution happens before, off the main actor).
    public static func resolve(
        urls: [String], snapshot: ProfileSnapshot?, environment: AccessEnvironment,
        proxyFor: (RemoteURL, ProviderInstance?) -> ResolvedProxy = { _, _ in .unchanged }
    ) -> AccessResolution {
        var policy = BrokerPolicy()
        var mismatches: [AuthMismatch] = []
        var network: [ScopedNetwork] = []
        var ssh: SSHPlan?
        var hosts: [String] = []
        let parsed = urls.compactMap(RemoteURL.parse)
        let auth = snapshot?.auth
        let instance = snapshot?.instance
        let global = snapshot?.globalNetwork ?? GlobalNetworkConfig()

        for url in parsed where url.scheme != .file {
            if !hosts.contains(url.host) { hosts.append(url.host) }
            let matchingInstance: ProviderInstance? = {
                guard let instance else { return nil }
                if url.isHTTP {
                    return instance.matchesHTTPS(host: url.host, port: url.port, path: url.path) ? instance : nil
                }
                if url.isSSH { return instance.matchesSSH(host: url.host, port: url.port) ? instance : nil }
                return nil
            }()
            if url.isHTTP {
                if let matchingInstance, let accountID = auth?.accountID,
                    snapshot?.account?.id == accountID
                {
                    let target = BrokerPolicy.HTTPSTarget(
                        accountID: accountID, host: url.host, port: url.port, allowPlainHTTP: url.scheme == .http)
                    if !policy.https.contains(target) { policy.https.append(target) }
                    _ = matchingInstance
                } else if auth == nil {
                    mismatches.append(.noProfileAuth)
                } else if matchingInstance != nil {
                    mismatches.append(.noHTTPSAccount(host: url.host))
                } else {
                    mismatches.append(.noAccountForHost(host: url.host))
                }
                // Network: the server's CA + proxy (whichever configured server matches, independent of the
                // profile) plus global host-scoped CAs, scoped to this URL's origin.
                let prefix = originPrefix(url)
                let server =
                    matchingInstance
                    ?? snapshot?.networkInstances.first {
                        $0.matchesHTTPS(host: url.host, port: url.port, path: url.path)
                    }
                let caIDs = (server?.caCertificateIDs ?? []) + global.caCertificateIDs
                let caInfo = caIDs.first.map { _ in combinedCAPath(caIDs, environment: environment) }
                let resolved = proxyFor(url, server)
                let proxy: ScopedNetwork.Proxy
                if let manual = resolved.proxy, manual.isValid {
                    let scheme = manual.kind == .socks5 ? "socks5h" : (manual.kind == .https ? "https" : "http")
                    // The username (not a secret) must be in the URL for Git to ask the helper for the password.
                    let user = manual.username.flatMap {
                        $0.isEmpty ? nil : $0.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
                    }
                    proxy = .url("\(scheme)://\(user.map { "\($0)@" } ?? "")\(manual.host):\(manual.port)")
                    if let username = manual.username, !username.isEmpty {
                        let target = BrokerPolicy.ProxyTarget(
                            proxyID: manual.id, host: manual.host, port: manual.port, username: username)
                        if !policy.proxies.contains(target) { policy.proxies.append(target) }
                    }
                } else {
                    proxy = resolved.source == .direct || resolved.source == .exception ? .direct : .unchanged
                }
                if caInfo != nil || proxy != .unchanged {
                    let scope = ScopedNetwork(urlPrefix: prefix, caInfo: caInfo, proxy: proxy)
                    if !network.contains(scope) { network.append(scope) }
                }
            } else if url.isSSH {
                guard let auth else {
                    mismatches.append(.noProfileAuth)
                    continue
                }
                if matchingInstance == nil { mismatches.append(.sshHostNotInstance(host: url.host)) }
                if ssh == nil {
                    let keyPath: String?
                    if case .keyFile(let path, let fingerprint) = auth.ssh {
                        keyPath = path
                        policy.sshKey = BrokerPolicy.SSHKeyTarget(path: path, fingerprint: fingerprint)
                    } else {
                        keyPath = nil
                    }
                    let resolved = proxyFor(url, matchingInstance)
                    var sshProxy: SSHProxy?
                    if let manual = resolved.proxy, manual.isValid {
                        sshProxy = SSHProxy(
                            kind: manual.kind == .socks5 ? .socks5 : .connect, host: manual.host, port: manual.port)
                    }
                    ssh = SSHPlan(
                        keyPath: keyPath, useAgent: environment.agentAvailable,
                        knownHostsFiles: [environment.userKnownHosts, environment.jitKnownHosts],
                        strictConfig: !auth.useUserSSHConfig, proxy: sshProxy)
                }
            }
        }
        return AccessResolution(
            policy: policy, ssh: ssh, network: network, mismatches: mismatches, remoteHosts: hosts)
    }

    /// `https://host[:port]/` — Git matches `http.<url>.*` by prefix, so the origin covers every repository.
    static func originPrefix(_ url: RemoteURL) -> String {
        let defaultPort = url.scheme == .http ? 80 : 443
        let host = url.host.contains(":") ? "[\(url.host)]" : url.host
        return "\(url.scheme.rawValue)://\(host)\(url.port == defaultPort ? "" : ":\(url.port)")/"
    }

    /// One CA → its file; several → the first file path is still a single PEM; `CAStore` writes a combined
    /// bundle per instance when more than one is configured (`<id1>+<id2>.pem`).
    static func combinedCAPath(_ ids: [String], environment: AccessEnvironment) -> String {
        ids.count == 1 ? environment.caPath(ids[0]) : environment.caPath(ids.joined(separator: "+"))
    }
}
