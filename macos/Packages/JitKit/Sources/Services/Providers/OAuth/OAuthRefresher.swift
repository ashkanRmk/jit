import Foundation

/// Just-in-time OAuth refresh, single-flight per account (design §4.5). No timers: it runs only when a caller
/// needs a token. Holds no tokens itself — they're loaded from and stored to the Keychain through closures.
public actor OAuthRefresher {
    /// Loads the stored token set (Keychain).
    public typealias Load = @Sendable () async throws -> OAuthTokens
    /// Exchanges a refresh token for a new set (e.g. `GitLabOAuthClient.refresh`).
    public typealias Refresh = @Sendable (SecretBytes) async throws -> OAuthTokens
    /// Persists the new set (Keychain, atomically replacing the old item).
    public typealias Store = @Sendable (OAuthTokens) async throws -> Void

    public let leeway: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: [HostingAccountID: Task<SecretBytes, any Error>] = [:]

    public init(leeway: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.leeway = leeway
        self.now = now
    }

    /// A usable access token for `accountID`. If the stored one is expired or expires within `leeway`, refreshes
    /// once — concurrent callers for the same account share that one refresh.
    ///
    /// Throws `OAuthError.refreshFailed` when the refresh is rejected or there is no refresh token for an expired
    /// access token (mark the account `expired`). Network failures (`OAuthError.request(.transport)`) pass
    /// through unchanged: being offline doesn't mean the sign-in expired.
    public func accessToken(
        for accountID: HostingAccountID, load: @escaping Load, refresh: @escaping Refresh, store: @escaping Store
    ) async throws -> SecretBytes {
        if let task = inFlight[accountID] { return try await task.value }
        let leeway = leeway
        let now = now
        let task = Task<SecretBytes, any Error> {
            let tokens = try await load()
            guard tokens.expires(within: leeway, now: now()) else { return tokens.access }
            guard let refreshToken = tokens.refresh else {
                // Still valid for a few seconds and nothing to refresh with: use it; otherwise it's over.
                if tokens.expires(within: 0, now: now()) { throw OAuthError.refreshFailed }
                return tokens.access
            }
            let fresh: OAuthTokens
            do {
                fresh = try await refresh(refreshToken)
            } catch let error as OAuthError {
                if case .request(let underlying) = error, underlying.transportFailure != nil { throw error }
                throw OAuthError.refreshFailed
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProviderError where error.transportFailure != nil {
                throw OAuthError.request(error)
            } catch {
                throw OAuthError.refreshFailed
            }
            try await store(fresh)
            return fresh.access
        }
        inFlight[accountID] = task
        defer { if inFlight[accountID] == task { inFlight[accountID] = nil } }
        return try await task.value
    }
}
