import Foundation
import GitCore
import Observation

/// The app's single entry point for profile authentication (design §4): builds the immutable `ExecContext` an
/// operation captures at enqueue, owns the secret store, connectivity, CA store and proxy resolution, and
/// performs account lifecycle steps that touch the Keychain. Creating it does no Keychain or network I/O.
@MainActor @Observable
public final class AccountsService {
    public let profiles: ProfileStore
    public let connectivity: ConnectivityState
    @ObservationIgnored public let secrets: any SecretStore
    @ObservationIgnored public let caStore: CAStore
    @ObservationIgnored public let environment: AccessEnvironment
    @ObservationIgnored public let proxyResolver: any ProxyResolving
    @ObservationIgnored public let helperPath: String?
    /// Presents the SSH passphrase sheet (set by the window controller).
    @ObservationIgnored public var passphrasePrompt: KeychainCredentialSource.PassphrasePrompt?

    public init(
        profiles: ProfileStore, secrets: (any SecretStore)? = nil, location: StoreLocation = .applicationSupport(),
        connectivity: ConnectivityState? = nil, proxyResolver: (any ProxyResolving)? = nil, helperPath: String? = nil
    ) {
        self.profiles = profiles
        self.secrets = secrets ?? KeychainStore()
        caStore = CAStore(location: location)
        environment = .standard(location: location)
        self.connectivity = connectivity ?? ConnectivityState()
        self.proxyResolver = proxyResolver ?? SystemProxyResolver()
        self.helperPath = helperPath ?? HelperLocator.helperPath()
    }

    /// The context for an operation enqueued now: identity + a provider holding the immutable snapshot. Without
    /// the helper binary (a broken build) remote commands fall back to the non-interactive Phase 4 behavior.
    public func execContext(snapshot: ProfileSnapshot? = nil) -> ExecContext {
        let snapshot = snapshot ?? profiles.snapshot()
        connectivity.start()
        guard let helperPath else { return ExecContext(identity: snapshot?.identity) }
        let provider = accessProvider(for: snapshot, helperPath: helperPath)
        return ExecContext(identity: snapshot?.identity, auth: .profile(RemoteAccessProviderRef(provider)))
    }

    public func accessProvider(for snapshot: ProfileSnapshot?, helperPath: String) -> ProfileAccessProvider {
        let accounts = snapshot?.account.map { [$0] } ?? []
        let instances = snapshot?.instance.map { [$0] } ?? []
        let source = KeychainCredentialSource(
            store: secrets, accounts: accounts, instances: instances,
            status: { [weak profiles] id, status in
                await MainActor.run { profiles?.setStatus(status, for: id) }
            }, prompt: passphrasePrompt, token: oauthLoader(for: snapshot))
        return ProfileAccessProvider(
            snapshot: snapshot, environment: environment, helperPath: helperPath, credentials: source,
            proxies: proxyResolver, connectivity: connectivity.checker, caStore: caStore)
    }

    /// OAuth client IDs (build-time `OAuthClients.plist`; never secrets).
    @ObservationIgnored public var oauthClients = OAuthClients(bundle: .main)
    @ObservationIgnored public let oauthRefresher = OAuthRefresher()

    /// Published SSH fingerprints for github.com (fetched over verified HTTPS when the trust sheet opens).
    @ObservationIgnored public var publishedFingerprints: @Sendable (String) async -> [String] = { _ in [] }

    /// Just-in-time OAuth refresh for Git HTTPS credentials (design §4.5); PATs are read straight from the Keychain.
    func oauthLoader(for snapshot: ProfileSnapshot?) -> KeychainCredentialSource.TokenLoader? {
        guard let account = snapshot?.account, account.method == .oauth, let instance = snapshot?.instance else {
            return nil
        }
        let provider = tokenProvider(for: account, instance: instance)
        return { _ throws(CredentialError) in
            do { return try await provider() } catch {
                throw .notAvailable("The sign-in for @\(account.login) expired.")
            }
        }
    }

    // MARK: Account lifecycle (Keychain first, then the non-secret record)

    /// Saves a validated token and the account record. The token goes to the Keychain only.
    public func saveAccount(_ account: HostingAccount, secret: SecretBytes, instanceName: String)
        async throws(KeychainError)
    {
        try await secrets.store(secret, for: .account(account.id), label: "Jit — \(instanceName) @\(account.login)")
        profiles.addAccount(account)
    }

    /// Replaces the token of an existing account (rotation) atomically: the Keychain item is updated in place.
    public func replaceToken(_ account: HostingAccount, secret: SecretBytes, instanceName: String)
        async throws(KeychainError)
    {
        try await secrets.store(secret, for: .account(account.id), label: "Jit — \(instanceName) @\(account.login)")
        var updated = account
        updated.status = .ok
        updated.lastCheckedAt = Date()
        profiles.updateAccount(updated)
    }

    /// Deletes the Keychain item, then the account record (profiles referencing it lose only the account).
    public func disconnect(_ id: HostingAccountID) async {
        try? await secrets.delete(.account(id))
        profiles.removeAccount(id)
    }

    public func readToken(_ id: HostingAccountID) async throws(KeychainError) -> SecretBytes {
        try await secrets.read(.account(id))
    }

    public func storeProxyPassword(_ secret: SecretBytes, for proxy: ManualProxy) async throws(KeychainError) {
        try await secrets.store(secret, for: .proxy(proxy.id), label: "Jit — proxy \(proxy.host)")
    }

    public func forgetPassphrase(fingerprint: String) async {
        try? await secrets.delete(.passphrase(fingerprint: fingerprint))
    }

    /// Profiles (other than the active one) whose account or SSH host matches one of `hosts` — the explicit
    /// "Switch to '<profile>' and Retry" candidates (design §3.4). Never used automatically.
    public func switchCandidates(for hosts: [String]) -> [GitProfile] {
        let lowered = Set(hosts.map { $0.lowercased() })
        return profiles.profiles.filter { profile in
            guard profile.id != profiles.activeProfileID, let auth = profile.auth,
                let instance = profiles.instance(auth.instanceID)
            else { return false }
            return lowered.contains(instance.httpsHost) || lowered.contains(instance.sshHost.lowercased())
        }
    }
}
