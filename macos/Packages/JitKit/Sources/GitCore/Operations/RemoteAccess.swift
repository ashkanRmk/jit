import Foundation
import Synchronization

/// The operation-scoped channel the bundled `jit-git-helper` uses to ask Jit for one credential (ADR-0016,
/// design B): a Unix socket in a fresh `0700` directory plus a single-use nonce. Both are passed to the helper
/// through the environment of *this* Git invocation only; neither is a secret by itself (the socket accepts one
/// request per nonce, for the expected host only, from the expected executable).
public struct BrokerEndpoint: Sendable, Hashable {
    public var socketPath: String
    public var nonce: String

    public init(socketPath: String, nonce: String) {
        self.socketPath = socketPath
        self.nonce = nonce
    }
}

/// A proxy for SSH connections, applied with `ProxyCommand=/usr/bin/nc -X <5|connect> -x host:port %h %p`.
/// No proxy authentication for SSH (documented limitation, ADR-0036).
public struct SSHProxy: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case socks5
        case connect
    }

    public var kind: Kind
    public var host: String
    public var port: Int

    public init(kind: Kind, host: String, port: Int) {
        self.kind = kind
        self.host = host
        self.port = port
    }
}

/// How SSH runs for one invocation (design §4.6, ADR-0036). Paths and flags only — never secrets.
public struct SSHPlan: Sendable, Hashable {
    /// `nil` = agent-only (`SSH_AUTH_SOCK` passed through, `IdentitiesOnly` not forced).
    public var keyPath: String?
    public var useAgent: Bool
    /// Read by ssh (user's file first, then Jit's). Only Jit's is ever written, only via the trust sheet.
    public var knownHostsFiles: [String]
    /// `-F none`: the user's `~/.ssh/config` is ignored unless the profile opted in.
    public var strictConfig: Bool
    public var proxy: SSHProxy?

    public init(
        keyPath: String?, useAgent: Bool, knownHostsFiles: [String], strictConfig: Bool = true,
        proxy: SSHProxy? = nil
    ) {
        self.keyPath = keyPath
        self.useAgent = useAgent
        self.knownHostsFiles = knownHostsFiles
        self.strictConfig = strictConfig
        self.proxy = proxy
    }
}

/// Per-URL network policy for Git (design §4.10, ADR-0018): `-c http.<prefix>.sslCAInfo` / `.proxy`.
/// The proxy URL never contains credentials (they would be argv); proxy auth goes through the helper.
public struct ScopedNetwork: Sendable, Hashable {
    public enum Proxy: Sendable, Hashable {
        /// Leave Git's behavior alone for this URL (system default: Git doesn't read macOS proxy settings).
        case unchanged
        /// Force no proxy, even if the user's Git config sets one.
        case direct
        /// `http://host:port`, `https://host:port` or `socks5h://host:port`.
        case url(String)
    }

    public var urlPrefix: String
    public var caInfo: String?
    public var proxy: Proxy

    public init(urlPrefix: String, caInfo: String? = nil, proxy: Proxy = .unchanged) {
        self.urlPrefix = urlPrefix
        self.caInfo = caInfo
        self.proxy = proxy
    }
}

/// Everything a remote Git invocation needs to authenticate and reach the remote, resolved from the profile
/// snapshot for the operation's remote URLs. Built by Services; turned into argv/env by `GitEnvironment`.
public struct RemoteAccess: Sendable, Hashable {
    /// Absolute path to `jit-git-helper` (credential helper, `GIT_SSH_COMMAND` target and askpass).
    public var helperPath: String
    /// Present while the operation may need a credential, passphrase or proxy password.
    public var broker: BrokerEndpoint?
    /// Install the helper as Git's only credential helper (HTTPS with an account, or proxy auth).
    public var httpsCredentials: Bool
    /// `nil` → the non-interactive Phase 4 SSH command (agent keys only, `BatchMode=yes`).
    public var ssh: SSHPlan?
    public var network: [ScopedNetwork]

    public init(
        helperPath: String, broker: BrokerEndpoint? = nil, httpsCredentials: Bool = false, ssh: SSHPlan? = nil,
        network: [ScopedNetwork] = []
    ) {
        self.helperPath = helperPath
        self.broker = broker
        self.httpsCredentials = httpsCredentials
        self.ssh = ssh
        self.network = network
    }
}

/// What a remote invocation is for (lets the provider skip work, e.g. no broker for `ls-remote` of a public
/// URL is still allowed — kept simple: purposes only label logs and diagnostics).
public enum RemotePurpose: String, Sendable, Hashable {
    case fetch
    case push
    case clone
    case lsRemote
}

/// Resolves `RemoteAccess` for an operation's remote URLs from the profile snapshot captured at enqueue
/// (Services implements it; GitCore only calls it). Called right before Git is spawned; the returned lease is
/// released when the Git process has exited, which tears the broker down.
public protocol RemoteAccessProvider: Sendable {
    func prepare(for urls: [String], purpose: RemotePurpose) async throws(GitCoreError) -> RemoteAccessLease
}

/// Owns operation-scoped resources (the broker socket). `release()` is idempotent and also runs on deinit.
public final class RemoteAccessLease: Sendable {
    public let access: RemoteAccess?
    private let onRelease: Mutex<(@Sendable () -> Void)?>

    public init(access: RemoteAccess?, onRelease: (@Sendable () -> Void)? = nil) {
        self.access = access
        self.onRelease = Mutex(onRelease)
    }

    public func release() {
        let action = onRelease.withLock { value -> (@Sendable () -> Void)? in
            defer { value = nil }
            return value
        }
        action?()
    }

    deinit { release() }
}

/// Wraps a provider so `ExecContext` stays `Hashable` (identity by object).
public struct RemoteAccessProviderRef: Sendable, Hashable {
    public let provider: any RemoteAccessProvider
    private let id: UUID

    public init(_ provider: any RemoteAccessProvider) {
        self.provider = provider
        id = UUID()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ExecContext {
    /// Prepares access for `urls` (no provider → no lease: Phase 4 non-interactive behavior, still without
    /// any inherited credential helper).
    public func prepareAccess(for urls: [String], purpose: RemotePurpose) async throws(GitCoreError)
        -> RemoteAccessLease?
    {
        guard case .profile(let reference) = auth else { return nil }
        return try await reference.provider.prepare(for: urls, purpose: purpose)
    }
}
