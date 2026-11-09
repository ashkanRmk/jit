import AppKit
import AuthenticationServices
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// Connect Account (design §3.3): provider, then method — personal access token (validated before saving),
/// browser sign-in (only when a client ID is configured), or SSH only. Replace Token / Reconnect reuse it with
/// the account's instance fixed and require the same login.
@MainActor @Observable
final class ConnectAccountModel {
    enum Method: String, CaseIterable, Identifiable {
        case token, browser, sshOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .token: "Access Token"
            case .browser: "Browser"
            case .sshOnly: "SSH Only"
            }
        }
    }

    enum Phase: Equatable {
        case editing
        case validating
        case validated(
            login: String, name: String?, scopes: [String], scopesKnown: Bool, expiresAt: Date?, userID: String)
        case saving
        case waitingForBrowser
        case deviceCode(code: String, url: URL)
        case failed(String)
    }

    let accounts: AccountsService
    let replacing: HostingAccount?
    var instanceID: ProviderInstanceID
    var method: Method = .token
    var token = ""
    private(set) var phase: Phase = .editing
    @ObservationIgnored private var validatedSecret: SecretBytes?
    @ObservationIgnored private var oauthTask: Task<Void, Never>?

    init(accounts: AccountsService, replacing: HostingAccount?) {
        self.accounts = accounts
        self.replacing = replacing
        instanceID = replacing?.instanceID ?? .github
        if replacing?.method == .oauth { method = .browser }
    }

    var instance: ProviderInstance? { accounts.profiles.instance(instanceID) }
    var oauthClientID: String? { instance.flatMap { accounts.oauthClients.clientID(for: $0) } }

    func reset() {
        oauthTask?.cancel()
        validatedSecret = nil
        phase = .editing
    }

    /// Validate: `GET /user` (+ token info), shown before anything is saved; a 401 refuses to save.
    func validate() {
        guard let instance, !token.isEmpty else { return }
        let secret = SecretBytes(utf8: token.trimmingCharacters(in: .whitespacesAndNewlines))
        phase = .validating
        Task {
            let provider = await accounts.provider(instance: instance, method: .pat, token: secret)
            do {
                let user: ProviderUser
                let info: TokenInfo
                if let github = provider as? GitHubProvider {
                    (user, info) = try await github.userAndTokenInfo()
                } else {
                    user = try await provider.currentUser()
                    info = (try? await provider.tokenInfo()) ?? TokenInfo(scopes: [], scopesKnown: false)
                }
                if let replacing, replacing.login.lowercased() != user.login.lowercased() {
                    phase = .failed(
                        "This token belongs to @\(user.login), not @\(replacing.login). Connect it as a new account instead."
                    )
                    return
                }
                validatedSecret = secret
                phase = .validated(
                    login: user.login, name: user.name, scopes: info.scopes, scopesKnown: info.scopesKnown,
                    expiresAt: info.expiresAt, userID: user.id)
            } catch let error as ProviderError {
                phase = .failed(
                    error == .unauthorized
                        ? "\(instance.name) rejected this token. Check that you copied it completely and that it hasn't expired."
                        : error.description)
            } catch {
                phase = .failed("Jit couldn't validate the token.")
            }
        }
    }

    func save(finish: @escaping () -> Void) {
        guard case .validated(let login, let name, let scopes, _, let expiresAt, let userID) = phase,
            let secret = validatedSecret, let instance
        else { return }
        phase = .saving
        Task {
            do throws(KeychainError) {
                if var existing = replacing {
                    existing.scopes = scopes
                    existing.expiresAt = expiresAt
                    try await accounts.replaceToken(existing, secret: secret, instanceName: instance.name)
                } else {
                    let account = HostingAccount(
                        instanceID: instance.id, login: login, userID: userID, displayName: name, method: .pat,
                        scopes: scopes, expiresAt: expiresAt, status: .ok, lastCheckedAt: Date())
                    try await accounts.saveAccount(account, secret: secret, instanceName: instance.name)
                }
                token = ""
                finish()
            } catch {
                phase = .failed("The Keychain refused to store the token: \(error.description)")
            }
        }
    }

    /// Browser sign-in: GitLab (authorization code + PKCE via ASWebAuthenticationSession) or the GitHub device flow.
    func signInWithBrowser(anchor: NSWindow?, finish: @escaping () -> Void) {
        guard let instance, let clientID = oauthClientID else { return }
        oauthTask?.cancel()
        oauthTask = Task {
            let transport = await accounts.transport(for: instance)
            do {
                let tokens: OAuthTokens
                switch instance.kind {
                case .gitlab:
                    phase = .waitingForBrowser
                    tokens = try await GitLabOAuthClient(instance: instance, clientID: clientID, transport: transport)
                        .signIn(using: WebAuthenticationBrowser(anchor: anchor))
                case .github:
                    let flow = GitHubDeviceFlow(clientID: clientID, transport: transport, instance: instance)
                    let authorization = try await flow.start()
                    phase = .deviceCode(code: authorization.userCode, url: authorization.verificationURL)
                    NSWorkspace.shared.open(authorization.verificationURL)
                    tokens = try await flow.poll(authorization)
                }
                let provider: any HostingProvider =
                    instance.kind == .github
                    ? GitHubProvider(instance: instance, transport: transport, token: { tokens.access })
                    : GitLabProvider(instance: instance, method: .oauth, transport: transport, token: { tokens.access })
                let user = try await provider.currentUser()
                if let replacing, replacing.login.lowercased() != user.login.lowercased() {
                    phase = .failed("You signed in as @\(user.login), not @\(replacing.login).")
                    return
                }
                let account = HostingAccount(
                    id: replacing?.id ?? .new(), instanceID: instance.id, login: user.login, userID: user.id,
                    displayName: user.name, method: .oauth, scopes: tokens.scopes, expiresAt: nil, status: .ok,
                    lastCheckedAt: Date())
                try await accounts.saveAccount(account, secret: tokens.keychainData(), instanceName: instance.name)
                finish()
            } catch OAuthError.cancelled {
                phase = .editing
            } catch is CancellationError {
                phase = .editing
            } catch let error as OAuthError {
                phase = .failed(error.description)
            } catch let error as ProviderError {
                phase = .failed(error.description)
            } catch {
                phase = .failed("Sign-in didn't complete.")
            }
        }
    }

    func cancel() {
        oauthTask?.cancel()
        oauthTask = nil
    }
}

/// `ASWebAuthenticationSession` glue for `OAuthBrowserSession` (system browser, custom `jit` callback scheme).
final class WebAuthenticationBrowser: NSObject, OAuthBrowserSession, ASWebAuthenticationPresentationContextProviding,
    @unchecked Sendable
{
    weak var anchor: NSWindow?

    init(anchor: NSWindow?) {
        self.anchor = anchor
    }

    @MainActor
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? NSApp.keyWindow ?? NSWindow() }
    }
}

struct ConnectAccountSheet: View {
    @State private var model: ConnectAccountModel
    let openNetwork: () -> Void
    let finish: () -> Void

    init(
        accounts: AccountsService, replacing: HostingAccount?, openNetwork: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        _model = State(initialValue: ConnectAccountModel(accounts: accounts, replacing: replacing))
        self.openNetwork = openNetwork
        self.finish = finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if let replacing = model.replacing {
                        LabeledContent("Account", value: "@\(replacing.login) on \(model.instance?.name ?? "")")
                    } else {
                        Picker("Provider", selection: $model.instanceID) {
                            ForEach(model.accounts.profiles.allInstances) { instance in
                                Text(instance.isSelfManaged ? "\(instance.name) (self-managed)" : instance.name)
                                    .tag(instance.id)
                            }
                        }
                        .onChange(of: model.instanceID) { _, _ in model.reset() }
                        Picker("Method", selection: $model.method) {
                            ForEach(ConnectAccountModel.Method.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.method) { _, _ in model.reset() }
                        Button("Add a self-managed GitLab server…", action: openNetwork)
                            .buttonStyle(.link)
                    }
                }
                switch model.method {
                case .token: tokenSection
                case .browser: browserSection
                case .sshOnly: sshSection
                }
                if case .failed(let message) = model.phase {
                    Section {
                        Label(message, systemImage: "xmark.octagon")
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.statusDanger))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancel()
                    finish()
                }
                .keyboardShortcut(.cancelAction)
                primaryButton
            }
            .padding(Space.s6)
        }
        .frame(width: 540, height: 560)
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.method {
        case .token:
            if case .validated = model.phase {
                Button(model.replacing == nil ? "Save Account" : "Replace Token") { model.save(finish: finish) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Validate") { model.validate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.token.isEmpty || model.phase == .validating)
            }
        case .browser:
            Button("Sign In with Browser…") { model.signInWithBrowser(anchor: NSApp.keyWindow, finish: finish) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.oauthClientID == nil || model.phase == .waitingForBrowser)
        case .sshOnly:
            Button("Done", action: finish).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var tokenSection: some View {
        Section {
            SecureField("Token", text: $model.token, prompt: Text(verbatim: "Paste the token"))
                .onChange(of: model.token) { _, _ in if model.phase != .editing { model.reset() } }
            if let url = tokenPageURL {
                Link("Create a token on \(model.instance?.name ?? "the server")…", destination: url)
            }
            Text(scopeGuidance)
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch model.phase {
            case .validating, .saving:
                HStack(spacing: Space.s3) {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .saving ? "Saving to the Keychain…" : "Checking the token…")
                        .typeStyle(.callout)
                        .foregroundStyle(.secondary)
                }
            case .validated(let login, let name, let scopes, let scopesKnown, let expiresAt, _):
                VStack(alignment: .leading, spacing: Space.s2) {
                    Label("@\(login)\(name.map { " — \($0)" } ?? "")", systemImage: "checkmark.circle.fill")
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.statusSuccess))
                    Text(
                        scopesKnown
                            ? "Scopes: \(scopes.isEmpty ? "none" : scopes.joined(separator: ", "))"
                            : "Fine-grained token — permissions are set on the token itself."
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                    Text(
                        expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .omitted))" }
                            ?? "No expiry reported"
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        } header: {
            Text("Personal access token")
        } footer: {
            Text("Stored only in your Keychain. Jit never writes it to Git's configuration or any file.")
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var browserSection: some View {
        Section("Sign in with browser") {
            if model.oauthClientID == nil {
                Text(
                    model.instance?.isSelfManaged == true
                        ? "Browser sign-in isn't configured for this server. Ask your GitLab administrator for an OAuth application ID and enter it in Servers & Network — or use an access token."
                        : "Browser sign-in isn't configured for this build of Jit. Use a personal access token instead."
                )
                .typeStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                switch model.phase {
                case .waitingForBrowser:
                    HStack(spacing: Space.s3) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the browser…").typeStyle(.callout)
                    }
                case .deviceCode(let code, let url):
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text("Enter this code on GitHub:").typeStyle(.callout)
                        Text(code).typeStyle(.monoTitle).textSelection(.enabled)
                        Link("Open \(url.host ?? "github.com")…", destination: url)
                        HStack(spacing: Space.s3) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to approve…").typeStyle(.caption).foregroundStyle(.secondary)
                        }
                    }
                default:
                    Text(
                        "Your browser opens \(model.instance?.name ?? "the server")'s sign-in page. Jit receives a token for this account only."
                    )
                    .typeStyle(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var sshSection: some View {
        Section("SSH only") {
            Text(
                "No account is needed to push and pull over SSH: choose an SSH key in the profile's Authentication settings. Repository browsing needs an account and isn't available for SSH-only profiles."
            )
            .typeStyle(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenPageURL: URL? {
        guard let instance = model.instance else { return nil }
        switch instance.kind {
        case .github: return URL(string: "https://github.com/settings/personal-access-tokens/new")
        case .gitlab:
            return instance.webBaseURL.appendingPathComponent("-/user_settings/personal_access_tokens")
        }
    }

    private var scopeGuidance: String {
        switch model.instance?.kind {
        case .github:
            "Fine-grained token: give it access to the repositories you need with Contents “Read and write” and Metadata “Read”. Classic token: “repo” for private repositories (“public_repo” for public only)."
        case .gitlab:
            "Scopes: read_api (browse repositories), read_repository (fetch and clone), write_repository (push)."
        case nil: ""
        }
    }
}
