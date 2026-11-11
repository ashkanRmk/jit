import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Settings ▸ Accounts (spec P8.accounts.1): one tab per place an account can live — GitHub, GitHub Enterprise,
/// GitLab, GitLab Self-Managed. A tab shows its connected accounts (status, Check Now, Replace Token…,
/// Disconnect…) or the connect form: a browser button on the SaaS tabs when this build has an OAuth client ID,
/// a host domain on the self-hosted tabs, and a personal access token. Connect checks the token and saves it in
/// one step. Nothing is checked in the background.
struct AccountsSettingsView: View {
    let accounts: AccountsService
    let open: (SettingsWindowController.Pane) -> Void
    @State private var tab: AccountTab
    @State private var adding: Set<AccountTab> = []
    @State private var connect: ConnectAccountRequest?
    @State private var pendingDisconnect: HostingAccount?
    @State private var checking: Set<HostingAccountID> = []
    @State private var checkMessages: [HostingAccountID: String] = [:]

    init(accounts: AccountsService, open: @escaping (SettingsWindowController.Pane) -> Void) {
        self.accounts = accounts
        self.open = open
        // `-JitAccountsTab <tab>` opens a given tab (screenshots).
        let requested = UserDefaults.standard.string(forKey: "JitAccountsTab").flatMap(AccountTab.init(rawValue:))
        _tab = State(initialValue: requested ?? .github)
    }

    private var store: ProfileStore { accounts.profiles }

    private func instances(in tab: AccountTab) -> [ProviderInstance] {
        store.allInstances.filter { AccountTab.tab(for: $0) == tab }
    }

    private func accounts(in tab: AccountTab) -> [HostingAccount] {
        let ids = Set(instances(in: tab).map(\.id))
        return store.accounts.filter { ids.contains($0.instanceID) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Service", selection: $tab) {
                    ForEach(AccountTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            let connected = accounts(in: tab)
            ForEach(instances(in: tab).filter { instance in connected.contains { $0.instanceID == instance.id } }) {
                instance in
                Section(instance.isSelfManaged ? instance.httpsHost : instance.name) {
                    ForEach(connected.filter { $0.instanceID == instance.id }) { account in
                        accountRow(account, instance: instance)
                    }
                }
            }
            if connected.isEmpty || adding.contains(tab) {
                AccountConnectForm(
                    accounts: accounts, tab: tab, canCancel: !connected.isEmpty,
                    openNetwork: { open(.network) }
                ) {
                    adding.remove(tab)
                }
                .id(tab)
            } else {
                Section {
                    HStack {
                        Button("Add Another Account…") { adding.insert(tab) }
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $connect) { request in
            ConnectAccountSheet(accounts: accounts, replacing: request.replacing, openNetwork: { open(.network) }) {
                connect = nil
            }
        }
        .sheet(item: $pendingDisconnect) { account in
            DisconnectAccountSheet(
                account: account, instance: store.instance(account.instanceID),
                usedBy: store.profiles(using: account.id).map(\.displayName)
            ) {
                Task { await accounts.disconnect(account.id) }
                pendingDisconnect = nil
            } cancel: {
                pendingDisconnect = nil
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: HostingAccount, instance: ProviderInstance) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s4) {
                Image(systemName: "person.crop.circle.fill")
                    .symbolSize(IconSize.lg)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text(account.displayName ?? "@\(account.login)").typeStyle(.headline)
                        Spacer()
                        AccountStatusDot(status: account.status)
                        Text(account.status.title)
                            .typeStyle(.callout)
                            .foregroundStyle(account.status == .ok ? .token(.statusSuccess) : .secondary)
                    }
                    if account.displayName != nil {
                        Text("@\(account.login)").typeStyle(.callout).foregroundStyle(.secondary)
                    }
                    Text(AccountText.details(account))
                        .typeStyle(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let usedBy = store.profiles(using: account.id).map(\.displayName)
                    Text(usedBy.isEmpty ? "Not used by any profile" : "Used by \(usedBy.joined(separator: ", "))")
                        .typeStyle(.caption)
                        .foregroundStyle(.secondary)
                    if let message = checkMessages[account.id] {
                        Text(message).typeStyle(.caption).foregroundStyle(.token(.statusWarning))
                    }
                }
            }
            HStack {
                Spacer()
                if checking.contains(account.id) { ProgressView().controlSize(.small) }
                Button("Check Now") { check(account) }
                    .disabled(checking.contains(account.id))
                if account.method == .pat {
                    Button("Replace Token…") { connect = ConnectAccountRequest(replacing: account) }
                } else {
                    Button("Reconnect…") { connect = ConnectAccountRequest(replacing: account) }
                }
                Button("Disconnect…", role: .destructive) { pendingDisconnect = account }
            }
            .controlSize(.small)
        }
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account @\(account.login) on \(instance.name), \(account.status.title)")
    }

    private func check(_ account: HostingAccount) {
        checking.insert(account.id)
        Task {
            let result = await accounts.checkAccount(account.id)
            checking.remove(account.id)
            switch result {
            case .success: checkMessages[account.id] = nil
            case .failure(let error): checkMessages[account.id] = error.localizedDescription
            }
        }
    }
}

/// The connect form of one tab: browser sign-in (SaaS tabs, only with a configured client ID), then host domain
/// (self-hosted tabs) and personal access token with a single Connect.
struct AccountConnectForm: View {
    let accounts: AccountsService
    let tab: AccountTab
    let canCancel: Bool
    let openNetwork: () -> Void
    let finish: () -> Void
    @State private var host = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var failure: String?
    @State private var oauth: ConnectAccountModel

    init(
        accounts: AccountsService, tab: AccountTab, canCancel: Bool, openNetwork: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        self.accounts = accounts
        self.tab = tab
        self.canCancel = canCancel
        self.openNetwork = openNetwork
        self.finish = finish
        let model = ConnectAccountModel(accounts: accounts, replacing: nil)
        model.instanceID = tab.fixedInstance?.id ?? .github
        model.method = .browser
        _oauth = State(initialValue: model)
    }

    private var offersBrowser: Bool { tab.fixedInstance != nil && oauth.oauthClientID != nil }
    private var hostIsValid: Bool { !tab.isSelfHosted || accounts.connectInstance(tab: tab, host: host) != nil }
    private var canConnect: Bool {
        !connecting && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hostIsValid
    }

    var body: some View {
        if offersBrowser { browserSection }
        Section {
            if tab.isSelfHosted {
                TextField("Host Domain", text: $host, prompt: Text(verbatim: hostPrompt))
                    .autocorrectionDisabled()
                    .onChange(of: host) { _, _ in failure = nil }
                if !host.isEmpty, !hostIsValid {
                    Text(ConnectAccountError.invalidHost.description)
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.statusDanger))
                }
            }
            SecureField("Personal Access Token", text: $token, prompt: Text(verbatim: "Paste the token"))
                .onChange(of: token) { _, _ in failure = nil }
                .onSubmit(connect)
            if let url = tokenPageURL {
                Link("Create a token on \(url.host ?? tab.title)…", destination: url)
            }
            Text(scopeGuidance)
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(failure, systemImage: "xmark.octagon")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.statusDanger))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s3) {
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
                if canCancel { Button("Cancel", action: finish) }
                if connecting {
                    ProgressView().controlSize(.small)
                    Text("Checking the token…").typeStyle(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            Text(offersBrowser ? "Or use a personal access token" : "Connect to \(tab.title)")
        } footer: {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(
                    "The token is stored only in your Keychain. Jit never writes it to Git's configuration or any file."
                )
                if tab.isSelfHosted {
                    HStack(spacing: Space.s1) {
                        Text("Custom certificates and proxies are set per server in")
                        Button("Servers & Network", action: openNetwork).buttonStyle(.link)
                    }
                }
            }
            .typeStyle(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var browserSection: some View {
        Section {
            switch oauth.phase {
            case .waitingForBrowser:
                HStack(spacing: Space.s3) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…").typeStyle(.callout)
                    Spacer()
                    Button("Cancel") { oauth.reset() }
                }
            case .deviceCode(let code, let url):
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text("Enter this code on GitHub:").typeStyle(.callout)
                    Text(code).typeStyle(.monoTitle).textSelection(.enabled)
                    Link("Open \(url.host ?? "github.com")…", destination: url)
                    HStack(spacing: Space.s3) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to approve…").typeStyle(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { oauth.reset() }
                    }
                }
            default:
                HStack {
                    Button("Connect with \(tab.title)") {
                        oauth.signInWithBrowser(anchor: NSApp.keyWindow, finish: finish)
                    }
                    .controlSize(.large)
                    Spacer()
                }
                if case .failed(let message) = oauth.phase {
                    Label(message, systemImage: "xmark.octagon")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.statusDanger))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Connect to \(tab.title)")
        } footer: {
            Text("Your browser opens \(tab.title)'s sign-in page. Jit receives a token for this account only.")
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func connect() {
        guard canConnect else { return }
        let secret = SecretBytes(utf8: token.trimmingCharacters(in: .whitespacesAndNewlines))
        connecting = true
        failure = nil
        Task {
            let result = await accounts.connect(tab: tab, host: host, token: secret)
            connecting = false
            switch result {
            case .success:
                token = ""
                host = ""
                finish()
            case .failure(let error):
                failure = error.description
            }
        }
    }

    private var hostPrompt: String {
        tab == .githubEnterprise ? "e.g., github.mycompany.com" : "e.g., gitlab.mycompany.com"
    }

    private var tokenPageURL: URL? {
        switch tab {
        case .github: return URL(string: "https://github.com/settings/personal-access-tokens/new")
        case .gitlab: return URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")
        case .githubEnterprise:
            return accounts.connectInstance(tab: tab, host: host)?.webBaseURL
                .appendingPathComponent("settings/tokens")
        case .gitlabSelfManaged:
            return accounts.connectInstance(tab: tab, host: host)?.webBaseURL
                .appendingPathComponent("-/user_settings/personal_access_tokens")
        }
    }

    private var scopeGuidance: String {
        switch tab {
        case .github:
            "Fine-grained token: give it access to the repositories you need with Contents “Read and write” and Metadata “Read”. Classic token: “repo” for private repositories (“public_repo” for public only)."
        case .githubEnterprise:
            "Classic token with the “repo” scope, or a fine-grained token with Contents “Read and write” and Metadata “Read” if your server offers them."
        case .gitlab, .gitlabSelfManaged:
            "Scopes: read_api (browse repositories), read_repository (fetch and clone), write_repository (push)."
        }
    }
}

struct ConnectAccountRequest: Identifiable {
    let id = UUID()
    let replacing: HostingAccount?
}

enum ProviderSymbols {
    static func symbol(_ kind: ProviderKind) -> String {
        kind == .github ? "chevron.left.forwardslash.chevron.right" : "square.stack.3d.up"
    }
}

/// Muted status dot (design §3.1): green ok, amber expired, grey not checked, red rejected.
struct AccountStatusDot: View {
    let status: AccountStatus

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: Space.s3, height: Space.s3)
            .accessibilityHidden(true)
    }

    private var dotColor: Color {
        switch status {
        case .ok: ColorToken.statusSuccess.color
        case .expired: ColorToken.statusWarning.color
        case .rejected: ColorToken.statusDanger.color
        case .unknown: ColorToken.textTertiary.color
        }
    }
}

enum AccountText {
    static func details(_ account: HostingAccount, now: Date = Date()) -> String {
        var parts = [account.method.title]
        if !account.scopes.isEmpty { parts.append("Scopes: \(account.scopes.joined(separator: ", "))") }
        if let expiresAt = account.expiresAt {
            let days = Calendar.current.dateComponents([.day], from: now, to: expiresAt).day ?? 0
            parts.append(
                expiresAt < now
                    ? "Expired \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
                    : days <= 1 ? "Expires within a day" : "Expires in \(days) days")
        }
        if let checked = account.lastCheckedAt {
            parts.append(
                now.timeIntervalSince(checked) < 60
                    ? "Checked just now"
                    : "Checked \(RelativeDateTimeFormatter().localizedString(for: checked, relativeTo: now))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Destructive sheet: removes the Keychain item; profiles keep identity and SSH settings.
struct DisconnectAccountSheet: View {
    let account: HostingAccount
    let instance: ProviderInstance?
    let usedBy: [String]
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Disconnect @\(account.login) from \(instance?.name ?? "the server")?").typeStyle(.headline)
            Text(explanation)
                .typeStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Disconnect", role: .destructive, action: confirm)
            }
        }
        .padding(Space.s8)
        .frame(width: 460)
    }

    private var explanation: String {
        var text = "Jit deletes the token from your Keychain."
        if !usedBy.isEmpty {
            text +=
                " \(usedBy.joined(separator: ", ")) will keep their identity and SSH settings but no longer sign in over HTTPS."
        }
        if instance?.kind == .github {
            text +=
                " The token itself stays valid on GitHub until you revoke it there (Settings ▸ Developer settings, or Applications ▸ Authorized OAuth Apps)."
        } else {
            text +=
                " The token stays valid on the server until you revoke it in your GitLab user settings (Access Tokens)."
        }
        return text
    }
}
