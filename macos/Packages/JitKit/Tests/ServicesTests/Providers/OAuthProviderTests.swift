import Foundation
import Synchronization
import Testing

@testable import Services

@Suite struct OAuthProviderTests {
    static let clientID = "app-123"

    func client(_ transport: ProviderStubTransport, clock: ProviderTestClock = ProviderTestClock()) -> GitLabOAuthClient
    {
        GitLabOAuthClient(instance: .gitlab, clientID: Self.clientID, transport: transport, now: clock.closure)
    }

    // MARK: PKCE / state

    @Test func pkceChallengeS256Vectors() {
        // RFC 7636 Appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE.method == "S256")
        let generated = PKCE()
        #expect((43...128).contains(generated.verifier.count))
        #expect(
            generated.verifier.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            })
        #expect(generated.challenge == PKCE.challenge(for: generated.verifier))
        #expect(PKCE().verifier != generated.verifier)
    }

    @Test func stateIs128BitAndComparesExactly() {
        let state = OAuthState()
        #expect(state.value.count == 22)  // 16 bytes base64url, unpadded
        #expect(state.matches(state.value))
        #expect(!state.matches(String(state.value.dropLast())))
        #expect(!state.matches(state.value + "x"))
        #expect(!state.matches(nil))
        #expect(OAuthState().value != state.value)
    }

    // MARK: Authorization code + PKCE

    @Test func authorizeURLHasPKCEStateAndScopes() throws {
        let authorization = try client(ProviderStubTransport { _ in .json("{}") }).beginAuthorization()
        let components = try #require(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "gitlab.com")
        #expect(components.path == "/oauth/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == Self.clientID)
        #expect(items["redirect_uri"] == "jit://oauth/gitlab")
        #expect(items["response_type"] == "code")
        #expect(items["state"] == authorization.state.value)
        #expect(items["scope"] == "read_api read_repository write_repository")
        #expect(items["code_challenge"] == authorization.pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["client_secret"] == nil)
    }

    @Test func stateMismatchRejected() async throws {
        let gitlab = client(ProviderStubTransport { _ in .json("{}") })
        let authorization = try gitlab.beginAuthorization()
        let forged = try providerURL("jit://oauth/gitlab?code=abc&state=forged")
        #expect(GitLabOAuthClient.handleCallback(forged, for: authorization) == .ignored)
        let missing = try providerURL("jit://oauth/gitlab?code=abc")
        #expect(GitLabOAuthClient.handleCallback(missing, for: authorization) == .ignored)

        struct ForgingBrowser: OAuthBrowserSession {
            func authenticate(url: URL, callbackScheme: String) async throws -> URL {
                URL(string: "jit://oauth/gitlab?code=abc&state=forged") ?? url
            }
        }
        let transport = ProviderStubTransport { _ in .json("{}") }
        await #expect(throws: OAuthError.stateMismatch) { try await client(transport).signIn(using: ForgingBrowser()) }
        #expect(transport.requests.isEmpty)  // no code exchange
    }

    @Test func callbackForUnknownSessionIgnored() throws {
        let gitlab = client(ProviderStubTransport { _ in .json("{}") })
        let current = try gitlab.beginAuthorization()
        let other = try gitlab.beginAuthorization()
        let forOther = try providerURL("jit://oauth/gitlab?code=abc&state=\(other.state.value)")
        #expect(GitLabOAuthClient.handleCallback(forOther, for: current) == .ignored)
        let wrongPath = try providerURL("jit://oauth/github?code=abc&state=\(current.state.value)")
        #expect(GitLabOAuthClient.handleCallback(wrongPath, for: current) == .ignored)
        let wrongScheme = try providerURL("https://oauth/gitlab?code=abc&state=\(current.state.value)")
        #expect(GitLabOAuthClient.handleCallback(wrongScheme, for: current) == .ignored)

        // The matching callback yields the code exactly once.
        let good = try providerURL("jit://oauth/gitlab?code=abc&state=\(current.state.value)")
        #expect(GitLabOAuthClient.handleCallback(good, for: current) == .code("abc"))
        #expect(GitLabOAuthClient.handleCallback(good, for: current) == .ignored)
    }

    @Test func deniedCallbackIsNeutralCancellation() throws {
        let gitlab = client(ProviderStubTransport { _ in .json("{}") })
        let authorization = try gitlab.beginAuthorization()
        let denied = try providerURL(
            "jit://oauth/gitlab?error=access_denied&error_description=The+resource+owner+denied&state=\(authorization.state.value)"
        )
        #expect(GitLabOAuthClient.handleCallback(denied, for: authorization) == .cancelled)
        let other = try gitlab.beginAuthorization()
        let scope = try providerURL("jit://oauth/gitlab?error=invalid_scope%3Cscript%3E&state=\(other.state.value)")
        #expect(GitLabOAuthClient.handleCallback(scope, for: other) == .failed(code: "invalid_scopescript"))
    }

    @Test func codeExchangeSendsVerifierAndNoSecret() async throws {
        let clock = ProviderTestClock()
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"access_token":"at-1","token_type":"Bearer","expires_in":7200,"refresh_token":"rt-1","scope":"read_api read_repository write_repository","created_at":1607635748}"#
            )
        }
        let gitlab = client(transport, clock: clock)
        let authorization = try gitlab.beginAuthorization()
        let tokens = try await gitlab.exchange(code: "the-code", authorization: authorization)
        #expect(providerSecretText(tokens.access) == "at-1")
        #expect(tokens.refresh.map(providerSecretText) == "rt-1")
        #expect(tokens.expiresAt == clock.now.addingTimeInterval(7200))
        #expect(tokens.tokenType == "bearer")
        #expect(tokens.scopes == ["read_api", "read_repository", "write_repository"])

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://gitlab.com/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(
            providerForm(request) == [
                "grant_type": "authorization_code", "client_id": Self.clientID, "code": "the-code",
                "redirect_uri": "jit://oauth/gitlab", "code_verifier": authorization.pkce.verifier,
            ])
    }

    @Test func refreshAndRevokeRequests() async throws {
        let transport = ProviderStubTransport { request in
            request.url?.path == "/oauth/revoke"
                ? .json("{}")
                : .json(#"{"access_token":"at-2","token_type":"bearer","expires_in":7200,"refresh_token":"rt-2"}"#)
        }
        let gitlab = client(transport)
        let tokens = try await gitlab.refresh(SecretBytes(utf8: "rt+1/="))
        #expect(providerSecretText(tokens.access) == "at-2")
        #expect(
            providerForm(try #require(transport.requests.first)) == [
                "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": "rt+1/=",
                "redirect_uri": "jit://oauth/gitlab",
            ])
        let body = String(decoding: try #require(transport.requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("refresh_token=rt%2B1%2F%3D"))

        try await gitlab.revoke(SecretBytes(utf8: "at-2"))
        let revoke = try #require(transport.requests.last)
        #expect(revoke.url?.absoluteString == "https://gitlab.com/oauth/revoke")
        #expect(providerForm(revoke) == ["client_id": Self.clientID, "token": "at-2"])
    }

    @Test func tokenEndpointErrorMapsToProviderCode() async throws {
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"error":"invalid_grant","error_description":"The provided authorization grant is invalid"}"#,
                status: 400)
        }
        await #expect(throws: OAuthError.provider(code: "invalid_grant")) {
            try await client(transport).refresh(SecretBytes(utf8: "rt"))
        }
    }

    @Test func keychainEncodingRoundTrips() throws {
        let tokens = OAuthTokens(
            access: SecretBytes(utf8: "at-\"quoted\"\\"), refresh: SecretBytes(utf8: "rt-1"),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_123.5), tokenType: "bearer",
            scopes: ["read_api", "write_repository"])
        let stored = tokens.keychainData()
        #expect(!stored.contains(Array("at-\"quoted\"".utf8)))  // secrets are base64 inside the item
        let decoded = try OAuthTokens(keychainData: stored)
        #expect(decoded.access.constantTimeEquals(tokens.access))
        #expect(decoded.refresh?.constantTimeEquals(SecretBytes(utf8: "rt-1")) == true)
        #expect(decoded.expiresAt == tokens.expiresAt)
        #expect(decoded.scopes == tokens.scopes)

        let noRefresh = try OAuthTokens(
            keychainData: OAuthTokens(access: SecretBytes(utf8: "x"), refresh: nil, expiresAt: nil).keychainData())
        #expect(noRefresh.refresh == nil)
        #expect(noRefresh.expiresAt == nil)
        #expect(throws: OAuthError.invalidResponse) { try OAuthTokens(keychainData: SecretBytes(utf8: "{}")) }
    }

    @Test func flatJSONDecodesEscapesAndSkipsNesting() throws {
        let json = try #require(FlatJSON(Data(#"{"a":"x\"\\\/é😀","n":3.5,"o":{"k":["}",1]},"b":true,"z":null}"#.utf8)))
        #expect(json.text("a") == "x\"\\/é😀")
        #expect(json.number("n") == 3.5)
        #expect(json.text("o") == nil)
        #expect(FlatJSON(Data("[1]".utf8)) == nil)
        #expect(FlatJSON(Data(#"{"a":"unterminated}"#.utf8)) == nil)
    }

    // MARK: Refresh

    /// A Keychain stand-in.
    final class TokenStore: Sendable {
        let tokens: Mutex<OAuthTokens>
        init(_ tokens: OAuthTokens) { self.tokens = Mutex(tokens) }
        func load() -> OAuthTokens { tokens.withLock { $0 } }
        func store(_ new: OAuthTokens) { tokens.withLock { $0 = new } }
    }

    @Test func refreshSingleFlight() async throws {
        let clock = ProviderTestClock()
        let store = TokenStore(
            OAuthTokens(
                access: SecretBytes(utf8: "old"), refresh: SecretBytes(utf8: "rt-old"),
                expiresAt: clock.now.addingTimeInterval(30)))
        let refreshes = Mutex(0)
        let refresher = OAuthRefresher(now: clock.closure)
        let account = HostingAccountID(rawValue: "acct")
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let token = try await refresher.accessToken(
                        for: account, load: { store.load() },
                        refresh: { refreshToken in
                            #expect(providerSecretText(refreshToken) == "rt-old")
                            refreshes.withLock { $0 += 1 }
                            try await Task.sleep(for: .milliseconds(50))
                            return OAuthTokens(
                                access: SecretBytes(utf8: "new"), refresh: SecretBytes(utf8: "rt-new"),
                                expiresAt: clock.now.addingTimeInterval(7200))
                        },
                        store: { store.store($0) })
                    return providerSecretText(token)
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(results.count == 20)
        #expect(results.allSatisfy { $0 == "new" })
        #expect(refreshes.withLock { $0 } == 1)
        #expect(providerSecretText(store.load().access) == "new")
    }

    @Test func freshTokenIsNotRefreshed() async throws {
        let clock = ProviderTestClock()
        let store = TokenStore(
            OAuthTokens(
                access: SecretBytes(utf8: "ok"), refresh: SecretBytes(utf8: "rt"),
                expiresAt: clock.now.addingTimeInterval(61)))
        let token = try await OAuthRefresher(now: clock.closure).accessToken(
            for: HostingAccountID(rawValue: "a"), load: { store.load() },
            refresh: { _ in
                Issue.record("refresh must not run"); throw OAuthError.refreshFailed
            }, store: { _ in })
        #expect(providerSecretText(token) == "ok")
    }

    @Test func refreshFailureMarksExpired() async throws {
        let clock = ProviderTestClock()
        var account = HostingAccount(instanceID: .gitlab, login: "alice", userID: "1", method: .oauth, status: .ok)
        let store = TokenStore(
            OAuthTokens(access: SecretBytes(utf8: "old"), refresh: SecretBytes(utf8: "rt"), expiresAt: clock.now))
        // The real refresh call against a token endpoint that rejects the grant.
        let transport = ProviderStubTransport { _ in .json(#"{"error":"invalid_grant"}"#, status: 400) }
        let gitlab = client(transport)
        let refresher = OAuthRefresher(now: clock.closure)
        do {
            _ = try await refresher.accessToken(
                for: account.id, load: { store.load() }, refresh: { try await gitlab.refresh($0) },
                store: { store.store($0) })
            Issue.record("expected refreshFailed")
        } catch OAuthError.refreshFailed {
            account.status = .expired  // what the caller does
        }
        #expect(account.status == .expired)
        #expect(providerSecretText(store.load().access) == "old")  // nothing stored

        // Expired with no refresh token → refreshFailed too.
        let noRefresh = TokenStore(
            OAuthTokens(access: SecretBytes(utf8: "old"), refresh: nil, expiresAt: clock.now.addingTimeInterval(-1)))
        await #expect(throws: OAuthError.refreshFailed) {
            try await refresher.accessToken(
                for: account.id, load: { noRefresh.load() }, refresh: { _ in throw OAuthError.refreshFailed },
                store: { _ in })
        }
    }

    @Test func offlineRefreshIsNotExpiry() async throws {
        let clock = ProviderTestClock()
        let store = TokenStore(
            OAuthTokens(access: SecretBytes(utf8: "old"), refresh: SecretBytes(utf8: "rt"), expiresAt: clock.now))
        let transport = ProviderStubTransport { _ in throw URLError(.notConnectedToInternet) }
        let gitlab = client(transport)
        await #expect(throws: OAuthError.request(.transport(URLError(.notConnectedToInternet)))) {
            try await OAuthRefresher(now: clock.closure).accessToken(
                for: HostingAccountID(rawValue: "a"), load: { store.load() }, refresh: { try await gitlab.refresh($0) },
                store: { store.store($0) })
        }
    }

    // MARK: Client configuration

    @Test func oauthClientsPlist() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["GitHubClientID": " Iv1.abc123 ", "GitLabClientID": ""], format: .xml, options: 0)
        let clients = OAuthClients(plistData: plist)
        #expect(clients.githubClientID == "Iv1.abc123")
        #expect(clients.gitlabClientID == nil)
        #expect(clients.clientID(for: .github) == "Iv1.abc123")
        #expect(clients.clientID(for: .gitlab) == nil)
        var instance = GitLabProviderTests.selfManaged
        instance.oauthClientID = "corp-app"
        #expect(clients.clientID(for: instance) == "corp-app")
        instance.oauthClientID = "bad id; rm"
        #expect(clients.clientID(for: instance) == nil)
        #expect(OAuthClients(bundle: Bundle(for: TokenStore.self)) == OAuthClients())
        #expect(OAuthClients(plistData: Data("garbage".utf8)) == OAuthClients())
    }
}
