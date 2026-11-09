import Foundation

/// A pending GitHub device authorization: show `userCode`, open `verificationURL`, then `poll`.
public struct GitHubDeviceAuthorization: Sendable, CustomStringConvertible {
    /// Exchanged for the token while polling — kept as a secret, never displayed.
    let deviceCode: SecretBytes
    public let userCode: String
    /// Always `https://github.com/...` (validated) — safe to open in the system browser.
    public let verificationURL: URL
    public let expiresAt: Date
    /// Seconds between polls as the server requested.
    public let interval: Int

    public var description: String { "GitHubDeviceAuthorization(userCode: \(userCode), expiresAt: \(expiresAt))" }
}

/// GitHub OAuth device flow (RFC 8628) for a public client — no client secret, no redirect (ADR-0017).
/// Polling is the only polling Jit does: it runs inside the caller's `Task` while the sign-in sheet is open,
/// honours `interval`/`slow_down`, and stops on success, expiry, denial or cancellation.
public struct GitHubDeviceFlow: Sendable {
    public static let defaultScopes = ["repo", "read:org"]
    /// Where users review/revoke the grant (revoking via API needs the client secret, which Jit never has).
    public static let authorizedAppsURL = URL(string: "https://github.com/settings/applications")

    public let clientID: String
    public let scopes: [String]
    private let webBase: URL
    private let transport: any HTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameter sleep: injectable for tests; defaults to `Task.sleep(for:)` (throws on cancellation).
    public init(
        clientID: String, transport: any HTTPTransport, instance: ProviderInstance = .github,
        scopes: [String] = GitHubDeviceFlow.defaultScopes,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientID = clientID
        self.scopes = scopes
        webBase = instance.webBaseURL
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    private func url(_ path: String) throws -> URL {
        guard let url = ProviderHTTP.url(webBase, path: path) else { throw OAuthError.invalidResponse }
        return url
    }

    /// `POST /login/device/code` with `client_id` and `scope`.
    public func start() async throws -> GitHubDeviceAuthorization {
        let body = FormBody(fields: [("client_id", .text(clientID)), ("scope", .text(scopes.joined(separator: " ")))])
        let (data, response) = try await postForm(url("login/device/code"), body, transport: transport)
        guard var json = FlatJSON(data) else {
            throw OAuthError.request(response.statusCode == 200 ? .invalidResponse : .server(response.statusCode))
        }
        defer { json.wipeAll() }
        if let code = json.text("error") { throw OAuthError.provider(code: OAuthError.sanitizedCode(code)) }
        guard response.statusCode == 200, let deviceCode = json.secret("device_code"),
            let userCode = json.text("user_code"), let verification = json.text("verification_uri"),
            let verificationURL = URL(string: verification), verificationURL.scheme?.lowercased() == "https",
            verificationURL.host?.lowercased() == webBase.host?.lowercased()
        else { throw OAuthError.invalidResponse }
        let expiresIn = json.number("expires_in") ?? 900
        let interval = Int(json.number("interval") ?? 5)
        return GitHubDeviceAuthorization(
            deviceCode: deviceCode, userCode: userCode, verificationURL: verificationURL,
            expiresAt: now().addingTimeInterval(expiresIn), interval: max(1, interval))
    }

    /// Sleeps `interval`, then polls `POST /login/oauth/access_token` until the user approves.
    /// `authorization_pending` → keep waiting; `slow_down` → interval + 5 s (or the server's new interval,
    /// whichever is larger); `expired_token` → `.expired`; `access_denied` → `.cancelled`.
    public func poll(_ authorization: GitHubDeviceAuthorization) async throws -> OAuthTokens {
        var interval = authorization.interval
        while true {
            try Task.checkCancellation()
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            if now() >= authorization.expiresAt { throw OAuthError.expired }
            let body = FormBody(fields: [
                ("client_id", .text(clientID)), ("device_code", .secret(authorization.deviceCode)),
                ("grant_type", .text("urn:ietf:params:oauth:grant-type:device_code")),
            ])
            let (data, response) = try await postForm(url("login/oauth/access_token"), body, transport: transport)
            guard var json = FlatJSON(data) else {
                throw OAuthError.request(response.statusCode == 200 ? .invalidResponse : .server(response.statusCode))
            }
            defer { json.wipeAll() }
            switch json.text("error").map(OAuthError.sanitizedCode) {
            case nil:
                return try OAuthTokens.parse(response: data, now: now())
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + 5, Int(json.number("interval") ?? 0))
            case "expired_token":
                throw OAuthError.expired
            case "access_denied":
                throw OAuthError.cancelled
            case let code?:
                throw OAuthError.provider(code: code)
            }
        }
    }
}
