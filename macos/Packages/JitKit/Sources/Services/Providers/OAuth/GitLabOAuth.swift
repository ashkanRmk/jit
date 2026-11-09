import Foundation
import Synchronization

/// Opens the authorization URL in the system browser and returns the callback URL (ADR-0017). The app layer
/// implements it with `ASWebAuthenticationSession` (Features), keeping AuthenticationServices out of Services.
/// Throw `CancellationError` (or `OAuthError.cancelled`) when the user closes the window.
public protocol OAuthBrowserSession: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// One in-flight GitLab sign-in: its `state`, PKCE verifier and authorize URL. A callback is accepted once.
public final class GitLabAuthorization: Sendable {
    public let url: URL
    public let state: OAuthState
    let pkce: PKCE
    private let consumed = Mutex(false)

    init(url: URL, state: OAuthState, pkce: PKCE) {
        self.url = url
        self.state = state
        self.pkce = pkce
    }

    fileprivate func consume() -> Bool {
        consumed.withLock { used in
            defer { used = true }
            return !used
        }
    }
}

/// What a callback URL meant for the in-flight sign-in.
public enum OAuthCallbackResult: Sendable, Equatable {
    /// The authorization code — exchange it with `GitLabOAuthClient.exchange`.
    case code(String)
    /// The user denied access (`error=access_denied`). Show a neutral message.
    case cancelled
    /// Another OAuth error (sanitized code).
    case failed(code: String)
    /// Not for this sign-in (wrong scheme/path, unknown or missing state, already used). Do nothing.
    case ignored
}

/// GitLab authorization code + PKCE (S256) for a public client — no client secret (design §4.9, ADR-0017).
public struct GitLabOAuthClient: Sendable {
    public static let redirectURI = "jit://oauth/gitlab"
    public static let callbackScheme = "jit"
    public static let defaultScopes = ["read_api", "read_repository", "write_repository"]

    public let instance: ProviderInstance
    public let clientID: String
    public let scopes: [String]
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        instance: ProviderInstance, clientID: String, transport: any HTTPTransport,
        scopes: [String] = GitLabOAuthClient.defaultScopes, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.instance = instance
        self.clientID = clientID
        self.scopes = scopes
        self.transport = transport
        self.now = now
    }

    private func webURL(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        guard let url = ProviderHTTP.url(instance.webBaseURL, path: path, query: query) else {
            throw OAuthError.invalidResponse
        }
        return url
    }

    /// Creates a fresh state + PKCE pair and the `<web base>/oauth/authorize` URL.
    public func beginAuthorization() throws -> GitLabAuthorization {
        let state = OAuthState()
        let pkce = PKCE()
        let url = try webURL(
            "oauth/authorize",
            [
                ("client_id", clientID), ("redirect_uri", Self.redirectURI), ("response_type", "code"),
                ("state", state.value), ("scope", scopes.joined(separator: " ")),
                ("code_challenge", pkce.challenge), ("code_challenge_method", PKCE.method),
            ])
        return GitLabAuthorization(url: url, state: state, pkce: pkce)
    }

    /// Classifies a callback URL against the in-flight `authorization`. Only `jit://oauth/gitlab` with the
    /// matching `state` counts; a code is handed out once.
    public static func handleCallback(_ url: URL, for authorization: GitLabAuthorization) -> OAuthCallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == callbackScheme, components.host?.lowercased() == "oauth",
            components.path == "/gitlab"
        else { return .ignored }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard authorization.state.matches(value("state")) else { return .ignored }
        if let error = value("error") {
            guard authorization.consume() else { return .ignored }
            let code = OAuthError.sanitizedCode(error)
            return code == "access_denied" ? .cancelled : .failed(code: code)
        }
        guard let code = value("code"), !code.isEmpty, authorization.consume() else { return .ignored }
        return .code(code)
    }

    /// Exchanges the code at `<web base>/oauth/token` (`grant_type=authorization_code`, PKCE verifier, no secret).
    public func exchange(code: String, authorization: GitLabAuthorization) async throws -> OAuthTokens {
        try await tokenRequest([
            ("grant_type", .text("authorization_code")), ("client_id", .text(clientID)), ("code", .text(code)),
            ("redirect_uri", .text(Self.redirectURI)), ("code_verifier", .text(authorization.pkce.verifier)),
        ])
    }

    /// `grant_type=refresh_token`. GitLab rotates refresh tokens — store the returned pair.
    public func refresh(_ refreshToken: SecretBytes) async throws -> OAuthTokens {
        try await tokenRequest([
            ("grant_type", .text("refresh_token")), ("client_id", .text(clientID)),
            ("refresh_token", .secret(refreshToken)), ("redirect_uri", .text(Self.redirectURI)),
        ])
    }

    /// `POST <web base>/oauth/revoke` with `client_id` + token (logout). Best effort: the caller deletes the
    /// Keychain item regardless.
    public func revoke(_ token: SecretBytes) async throws {
        let (_, response) = try await postForm(
            try webURL("oauth/revoke"),
            FormBody(fields: [("client_id", .text(clientID)), ("token", .secret(token))]), transport: transport)
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthError.request(.server(response.statusCode))
        }
    }

    /// Full browser sign-in: authorize in `browser`, check the callback, exchange the code.
    public func signIn(using browser: any OAuthBrowserSession) async throws -> OAuthTokens {
        let authorization = try beginAuthorization()
        let callback: URL
        do {
            callback = try await browser.authenticate(url: authorization.url, callbackScheme: Self.callbackScheme)
        } catch is CancellationError {
            throw OAuthError.cancelled
        }
        switch Self.handleCallback(callback, for: authorization) {
        case .code(let code): return try await exchange(code: code, authorization: authorization)
        case .cancelled: throw OAuthError.cancelled
        case .failed(let code): throw OAuthError.provider(code: code)
        case .ignored: throw OAuthError.stateMismatch
        }
    }

    private func tokenRequest(_ fields: [(String, FormBody.Value)]) async throws -> OAuthTokens {
        let (data, response) = try await postForm(
            try webURL("oauth/token"), FormBody(fields: fields), transport: transport)
        if response.statusCode == 200 { return try OAuthTokens.parse(response: data, now: now()) }
        // RFC 6749 §5.2 errors come back as 400/401 with an `error` code.
        if let json = FlatJSON(data), let code = json.text("error") {
            throw OAuthError.provider(code: OAuthError.sanitizedCode(code))
        }
        throw OAuthError.request(response.statusCode == 401 ? .unauthorized : .server(response.statusCode))
    }
}
