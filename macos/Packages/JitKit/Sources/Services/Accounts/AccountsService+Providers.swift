import Foundation
import GitCore

/// API clients for accounts and instances (design §4.7): one ephemeral URLSession per instance with that
/// instance's proxy and custom-CA trust scope (ADR-0018). OAuth access tokens are refreshed just in time.
extension AccountsService {
    /// A transport for `instance`: proxy resolved like Git's (System/PAC/Manual/Direct), trust scoped to the
    /// instance's host:port with its CAs (plus system roots), proxy auth answered from the Keychain.
    public func transport(for instance: ProviderInstance) async -> URLSessionTransport {
        let url = RemoteURL.parse(instance.webBaseURL.absoluteString)
        let proxy: ResolvedProxy =
            if let url {
                await proxyResolver.resolve(url, mode: instance.proxy, global: profiles.network.proxy)
            } else {
                .unchanged
            }
        let configuration = NetworkSessionFactory.configuration(proxy: proxy)
        let anchors = caStore.certificates(instance.caCertificateIDs + profiles.network.caCertificateIDs)
        var scopes: [ScopedTrustDelegate.Scope] = []
        if !anchors.isEmpty {
            scopes.append(.init(host: instance.httpsHost, port: instance.httpsPort, anchors: anchors))
        }
        let secrets = secrets
        let manual = proxy.proxy
        let delegate = ScopedTrustDelegate(scopes: scopes) { host, port in
            guard let manual, let username = manual.username, manual.host.lowercased() == host.lowercased(),
                manual.port == port, let password = try? await secrets.read(.proxy(manual.id))
            else { return nil }
            // URLCredential requires a String password; it lives only for this challenge.
            return URLCredential(
                user: username, password: String(decoding: password.dataCopy(), as: UTF8.self), persistence: .none)
        }
        return URLSessionTransport(configuration: configuration, delegate: delegate)
    }

    /// The token for API calls: PAT straight from the Keychain; OAuth via the single-flight refresher.
    public func tokenProvider(for account: HostingAccount, instance: ProviderInstance) -> TokenProvider {
        let secrets = secrets
        let id = account.id
        guard account.method == .oauth else {
            return { try await secrets.read(.account(id)) }
        }
        let refresher = oauthRefresher
        let clients = oauthClients
        let profiles = profiles
        let service = self
        return {
            do {
                return try await refresher.accessToken(
                    for: id,
                    load: { try OAuthTokens(keychainData: try await secrets.read(.account(id))) },
                    refresh: { refreshToken in
                        guard let clientID = clients.clientID(for: instance) else { throw OAuthError.notConfigured }
                        let transport = await service.transport(for: instance)
                        return try await GitLabOAuthClient(instance: instance, clientID: clientID, transport: transport)
                            .refresh(refreshToken)
                    },
                    store: { tokens in
                        try await secrets.store(
                            tokens.keychainData(), for: .account(id), label: "Jit — \(instance.name)")
                    })
            } catch OAuthError.refreshFailed {
                await MainActor.run { profiles.setStatus(.expired, for: id) }
                throw OAuthError.refreshFailed
            }
        }
    }

    /// A provider client for `account` (nil if its instance was removed).
    public func provider(for account: HostingAccount) async -> (any HostingProvider)? {
        guard let instance = profiles.instance(account.instanceID) else { return nil }
        let transport = await transport(for: instance)
        let token = tokenProvider(for: account, instance: instance)
        switch instance.kind {
        case .github: return GitHubProvider(instance: instance, transport: transport, token: token)
        case .gitlab:
            return GitLabProvider(instance: instance, method: account.method, transport: transport, token: token)
        }
    }

    /// A provider for a token not yet saved (Connect Account validation).
    public func provider(instance: ProviderInstance, method: AuthMethod, token: SecretBytes) async
        -> any HostingProvider
    {
        let transport: any HTTPTransport =
            if let transportOverride { transportOverride(instance) } else { await transport(for: instance) }
        switch instance.kind {
        case .github: return GitHubProvider(instance: instance, transport: transport, token: { token })
        case .gitlab: return GitLabProvider(instance: instance, method: method, transport: transport, token: { token })
        }
    }

    /// Check Now (explicit): validates the stored token and records status and expiry. No background checks.
    @discardableResult
    public func checkAccount(_ id: HostingAccountID) async -> Result<TokenInfo, ProviderError> {
        guard let account = profiles.account(id), let provider = await provider(for: account) else {
            return .failure(.notFound)
        }
        do {
            let info = try await provider.tokenInfo()
            var updated = account
            updated.scopes = info.scopes
            updated.expiresAt = info.expiresAt ?? account.expiresAt
            updated.status = .ok
            updated.lastCheckedAt = Date()
            profiles.updateAccount(updated)
            return .success(info)
        } catch let error as ProviderError {
            if case .unauthorized = error { profiles.setStatus(.rejected, for: id) }
            return .failure(error)
        } catch OAuthError.refreshFailed {
            return .failure(.unauthorized)
        } catch {
            return .failure(.invalidResponse)
        }
    }
}
