import Foundation
import GitCore
import Synchronization

/// Finds `jit-git-helper`: `Contents/Helpers/` in the app bundle, `JIT_GIT_HELPER` (tests, scripts), or next to
/// the running executable (SwiftPM builds).
public enum HelperLocator {
    public static func helperPath(bundle: Bundle = .main) -> String? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["JIT_GIT_HELPER"],
            fileManager.isExecutableFile(atPath: override)
        {
            return override
        }
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/jit-git-helper").path
        if fileManager.isExecutableFile(atPath: bundled) { return bundled }
        if let executable = bundle.executableURL?.deletingLastPathComponent() {
            let sibling = executable.appendingPathComponent("jit-git-helper").path
            if fileManager.isExecutableFile(atPath: sibling) { return sibling }
        }
        return nil
    }
}

/// Picks a proxy for a URL (system/PAC/manual/direct). Production: `SystemProxyResolver`.
public protocol ProxyResolving: Sendable {
    func resolve(_ url: RemoteURL, mode: ProxyMode, global: ProxyMode) async -> ResolvedProxy
}

/// Fails fast while offline (ADR-0038).
public protocol ConnectivityChecking: Sendable {
    func isOffline() async -> Bool
}

/// The `RemoteAccessProvider` built when an operation is enqueued: it holds the immutable profile snapshot
/// (design §4.2) and, right before Git starts, resolves credentials/SSH/network for the operation's URLs and
/// starts an operation-scoped broker. The broker is torn down when GitCore releases the lease.
public final class ProfileAccessProvider: RemoteAccessProvider {
    public let snapshot: ProfileSnapshot?
    let environment: AccessEnvironment
    let helperPath: String
    let credentials: any CredentialSource
    let proxies: (any ProxyResolving)?
    let connectivity: (any ConnectivityChecking)?
    let caStore: CAStore?
    /// The last resolution (for mismatch explanations after a failure).
    public let lastResolution = Mutex<AccessResolution?>(nil)

    public init(
        snapshot: ProfileSnapshot?, environment: AccessEnvironment, helperPath: String,
        credentials: any CredentialSource, proxies: (any ProxyResolving)? = nil,
        connectivity: (any ConnectivityChecking)? = nil, caStore: CAStore? = nil
    ) {
        self.snapshot = snapshot
        self.environment = environment
        self.helperPath = helperPath
        self.credentials = credentials
        self.proxies = proxies
        self.connectivity = connectivity
        self.caStore = caStore
    }

    public func prepare(for urls: [String], purpose: RemotePurpose) async throws(GitCoreError) -> RemoteAccessLease {
        let parsed = urls.compactMap(RemoteURL.parse)
        if let connectivity, parsed.contains(where: { $0.scheme != .file }), await connectivity.isOffline() {
            throw .failed(
                ClassifiedFailure(
                    kind: .hostNotFound, summary: "You're offline.",
                    detail: "The network path is unavailable; Jit doesn't retry automatically."))
        }
        var proxyChoices: [RemoteURL: ResolvedProxy] = [:]
        if let proxies {
            let instance = snapshot?.instance
            let global = snapshot?.globalNetwork.proxy ?? .system
            let servers = (instance.map { [$0] } ?? []) + (snapshot?.networkInstances ?? [])
            for url in parsed where url.scheme != .file {
                let server = servers.first {
                    url.isHTTP
                        ? $0.matchesHTTPS(host: url.host, port: url.port, path: url.path)
                        : $0.matchesSSH(host: url.host, port: url.port)
                }
                let mode = server?.proxy ?? .inheritGlobal
                proxyChoices[url] = await proxies.resolve(url, mode: mode, global: global)
            }
        }
        let resolution = AccessResolver.resolve(
            urls: urls, snapshot: snapshot, environment: environment,
            proxyFor: { url, _ in proxyChoices[url] ?? .unchanged })
        lastResolution.withLock { $0 = resolution }
        if let caStore {
            for scope in resolution.network {
                if let path = scope.caInfo { try? caStore.ensureBundle(at: path) }
            }
        }
        var broker: CredentialBroker?
        if !resolution.policy.isEmpty {
            do throws(CredentialError) {
                broker = try CredentialBroker(
                    policy: resolution.policy, source: credentials, expectedPeer: helperPath)
            } catch {
                throw .io(summary: "Jit couldn't prepare credentials for Git.")
            }
        }
        let access = RemoteAccess(
            helperPath: helperPath, broker: broker?.endpoint, httpsCredentials: resolution.usesHTTPSCredentials,
            ssh: resolution.ssh, network: resolution.network)
        let started = broker
        return RemoteAccessLease(access: access) { started?.shutdown() }
    }
}

/// Production credential source: tokens and passphrases from the Keychain, status changes reported back to the
/// profile store on the main actor, passphrase prompts through an injected presenter (the sheet).
public struct KeychainCredentialSource: CredentialSource {
    public typealias StatusSink = @Sendable (HostingAccountID, AccountStatus) async -> Void
    public typealias PassphrasePrompt =
        @Sendable (_ keyPath: String, _ fingerprint: String?) async -> (SecretBytes, remember: Bool)?
    public typealias TokenLoader = @Sendable (HostingAccountID) async throws(CredentialError) -> SecretBytes

    let store: any SecretStore
    let accounts: [HostingAccountID: (kind: ProviderKind, method: AuthMethod, login: String)]
    let status: StatusSink
    let prompt: PassphrasePrompt?
    let token: TokenLoader?

    /// - Parameter token: loads (and just-in-time refreshes) an OAuth access token; PATs are read directly.
    public init(
        store: any SecretStore, accounts: [HostingAccount], instances: [ProviderInstance],
        status: @escaping StatusSink, prompt: PassphrasePrompt?, token: TokenLoader? = nil
    ) {
        self.store = store
        var map: [HostingAccountID: (ProviderKind, AuthMethod, String)] = [:]
        for account in accounts {
            let kind = instances.first { $0.id == account.instanceID }?.kind ?? .github
            map[account.id] = (kind, account.method, account.login)
        }
        self.accounts = map.mapValues { (kind: $0.0, method: $0.1, login: $0.2) }
        self.status = status
        self.prompt = prompt
        self.token = token
    }

    /// GitHub PAT → login; GitHub OAuth → `x-access-token`; GitLab PAT → login; GitLab OAuth → `oauth2`.
    public static func gitUsername(kind: ProviderKind, method: AuthMethod, login: String) -> String {
        switch (kind, method) {
        case (.github, .pat): login
        case (.github, .oauth): "x-access-token"
        case (.gitlab, .pat): login.isEmpty ? "oauth2" : login
        case (.gitlab, .oauth): "oauth2"
        }
    }

    public func httpsCredential(accountID: HostingAccountID, host: String) async throws(CredentialError)
        -> SecretPair
    {
        guard let account = accounts[accountID] else {
            throw .notAvailable("The account was removed.")
        }
        let secret: SecretBytes
        if account.method == .oauth, let token {
            secret = try await token(accountID)
        } else {
            do throws(KeychainError) {
                secret = try await store.read(.account(accountID))
            } catch {
                throw .notAvailable(error.description)
            }
        }
        return SecretPair(
            username: Self.gitUsername(kind: account.kind, method: account.method, login: account.login),
            secret: secret)
    }

    public func sshPassphrase(keyPath: String, fingerprint: String?, prompt text: String) async throws(CredentialError)
        -> SecretBytes
    {
        if let fingerprint, let stored = try? await store.read(.passphrase(fingerprint: fingerprint)) {
            return stored
        }
        guard let prompt, let answer = await prompt(keyPath, fingerprint) else { throw .cancelled }
        if answer.remember, let fingerprint {
            try? await store.store(
                answer.0, for: .passphrase(fingerprint: fingerprint),
                label: "Jit — SSH key \((keyPath as NSString).lastPathComponent)")
        }
        return answer.0
    }

    public func proxyCredential(proxyID: ProxyConfigID, username: String) async throws(CredentialError)
        -> SecretPair
    {
        do throws(KeychainError) {
            return SecretPair(username: username, secret: try await store.read(.proxy(proxyID)))
        } catch {
            throw .notAvailable(error.description)
        }
    }

    public func credentialRejected(accountID: HostingAccountID, host: String) async {
        await status(accountID, .rejected)
    }

    public func credentialAccepted(accountID: HostingAccountID, host: String) async {
        await status(accountID, .ok)
    }
}
