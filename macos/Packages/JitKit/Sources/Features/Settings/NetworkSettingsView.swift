import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Settings ▸ Servers & Network (design §3.2, §4.10): the global proxy (GitHub.com, GitLab.com and the default
/// for servers), and self-managed GitLab servers with base URL, SSH, OAuth application ID, custom CAs and proxy.
struct NetworkSettingsView: View {
    let accounts: AccountsService
    @State private var editing: InstanceEditRequest?
    @State private var pendingRemoval: ProviderInstance?

    private var store: ProfileStore { accounts.profiles }

    var body: some View {
        Form {
            Section {
                ProxyModeEditor(
                    mode: Binding(
                        get: { store.network.proxy },
                        set: { mode in
                            var network = store.network
                            network.proxy = mode
                            store.setNetwork(network)
                        }), allowsInherit: false, accounts: accounts)
            } header: {
                Text("Proxy")
            } footer: {
                Text(
                    "Used for GitHub.com and GitLab.com, and by servers set to “Same as global”. Applied to both Jit's API requests and Git — Jit never changes your system or Git proxy settings."
                )
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                if store.customInstances.isEmpty {
                    Text("No self-managed servers. Add your company's GitLab to browse and authenticate against it.")
                        .typeStyle(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.customInstances) { instance in
                    HStack(spacing: Space.s4) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(instance.name).typeStyle(.headline)
                            Text(instance.webBaseURL.absoluteString).typeStyle(.monoCaption).foregroundStyle(.secondary)
                            Text(InstanceText.summary(instance, caStore: accounts.caStore))
                                .typeStyle(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = InstanceEditRequest(instance: instance) }
                        Button("Remove…", role: .destructive) { pendingRemoval = instance }
                    }
                    .padding(.vertical, Space.s1)
                }
                HStack {
                    Button("Add GitLab Server…") { editing = InstanceEditRequest(instance: nil) }
                    Spacer()
                }
            } header: {
                Text("Self-managed GitLab servers")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { request in
            InstanceEditorSheet(accounts: accounts, editing: request.instance) { editing = nil }
        }
        .confirmationDialog(
            "Remove the server “\(pendingRemoval?.name ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { instance in
            Button("Remove Server and Its Accounts", role: .destructive) {
                let accountIDs = store.accounts.filter { $0.instanceID == instance.id }.map(\.id)
                Task {
                    for id in accountIDs { await accounts.disconnect(id) }
                    store.removeInstance(instance.id)
                }
            }
        } message: { instance in
            let count = store.accounts.filter { $0.instanceID == instance.id }.count
            Text(
                "Its \(count) account\(count == 1 ? "" : "s") and their Keychain items are removed; profiles that used it keep their identity but lose its authentication. Repositories and commits are not affected."
            )
        }
    }
}

struct InstanceEditRequest: Identifiable {
    let id = UUID()
    let instance: ProviderInstance?
}

enum InstanceText {
    static func summary(_ instance: ProviderInstance, caStore: CAStore) -> String {
        var parts = ["SSH \(instance.sshHost):\(instance.sshPort)"]
        let cas = instance.caCertificateIDs.compactMap { caStore.load($0)?.1 }
        if !cas.isEmpty {
            parts.append("\(cas.count) custom CA")
            if cas.contains(where: { $0.isExpired() }) {
                parts.append("a CA has expired")
            } else if cas.contains(where: { $0.expiresSoon() }) {
                parts.append("a CA expires within 30 days")
            }
        }
        parts.append("Proxy: \(instance.proxy.title)")
        if instance.oauthClientID != nil { parts.append("Browser sign-in configured") }
        return parts.joined(separator: " · ")
    }
}

/// Proxy mode picker with manual fields; the optional password goes to the Keychain only.
struct ProxyModeEditor: View {
    @Binding var mode: ProxyMode
    let allowsInherit: Bool
    let accounts: AccountsService
    @State private var kind: ManualProxy.Kind = .http
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var passwordSaved = false

    enum Choice: Hashable { case inherit, system, direct, manual }

    var body: some View {
        Picker("Proxy", selection: choice) {
            if allowsInherit { Text("Same as global").tag(Choice.inherit) }
            Text("System settings (incl. PAC)").tag(Choice.system)
            Text("No proxy").tag(Choice.direct)
            Text("Manual").tag(Choice.manual)
        }
        .onAppear(perform: load)
        if case .manual(let proxy) = mode {
            Picker("Type", selection: $kind) {
                ForEach(ManualProxy.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Host", text: $host, prompt: Text(verbatim: "proxy.corp.example"))
            TextField("Port", text: $port, prompt: Text(verbatim: "3128"))
            TextField("Username (optional)", text: $username)
            SecureField("Password (optional)", text: $password)
            HStack {
                if !manual(id: proxy.id).isValid {
                    Text("Enter a host name and a port between 1 and 65535.")
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.statusDanger))
                } else if passwordSaved {
                    Text("Saved. The password is in your Keychain.").typeStyle(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply") { apply(id: proxy.id) }
                    .disabled(!manual(id: proxy.id).isValid)
            }
            if kind == .socks5 || !username.isEmpty {
                Text("SSH connections use this proxy without authentication (OpenSSH limitation).")
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var choice: Binding<Choice> {
        Binding {
            switch mode {
            case .inheritGlobal: .inherit
            case .system: .system
            case .direct: .direct
            case .manual: .manual
            }
        } set: { value in
            switch value {
            case .inherit: mode = .inheritGlobal
            case .system: mode = .system
            case .direct: mode = .direct
            case .manual:
                if case .manual = mode { return }
                mode = .manual(ManualProxy(kind: .http, host: "", port: 0))
            }
        }
    }

    private func load() {
        guard case .manual(let proxy) = mode else { return }
        kind = proxy.kind
        host = proxy.host
        port = proxy.port == 0 ? "" : "\(proxy.port)"
        username = proxy.username ?? ""
    }

    private func manual(id: ProxyConfigID) -> ManualProxy {
        ManualProxy(
            id: id, kind: kind, host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
            username: username.trimmingCharacters(in: .whitespaces).isEmpty ? nil : username)
    }

    private func apply(id: ProxyConfigID) {
        let proxy = manual(id: id)
        guard proxy.isValid else { return }
        mode = .manual(proxy)
        if !password.isEmpty {
            let secret = SecretBytes(utf8: password)
            password = ""
            Task {
                try? await accounts.storeProxyPassword(secret, for: proxy)
                passwordSaved = true
            }
        }
    }
}

/// Add/edit a self-managed GitLab server: URL with path prefix, SSH host/port, OAuth application ID (shows the
/// redirect URI and scopes for the admin), custom CAs (validated: must be a CA), proxy.
struct InstanceEditorSheet: View {
    let accounts: AccountsService
    let editing: ProviderInstance?
    let finish: () -> Void
    @State private var name = ""
    @State private var baseURL = ""
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var oauthID = ""
    @State private var caIDs: [String] = []
    @State private var proxy: ProxyMode = .inheritGlobal
    @State private var caError: String?
    @State private var id = ProviderInstanceID.new()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Name", text: $name, prompt: Text(verbatim: "Company GitLab"))
                    TextField("Base URL", text: $baseURL, prompt: Text(verbatim: "https://git.corp.example/gitlab"))
                    if let problem = urlProblem {
                        Text(problem).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                    } else if let instance = draft {
                        Text("API: \(instance.apiBaseURL.absoluteString)").typeStyle(.monoCaption).foregroundStyle(
                            .secondary)
                    }
                    TextField("SSH host", text: $sshHost, prompt: Text(verbatim: "git.corp.example"))
                    TextField("SSH port", text: $sshPort)
                }
                Section {
                    TextField("OAuth application ID (optional)", text: $oauthID)
                    LabeledContent("Redirect URI") {
                        Text(GitLabOAuthClient.redirectURI).typeStyle(.monoCaption).textSelection(.enabled)
                    }
                    LabeledContent("Scopes") {
                        Text(GitLabOAuthClient.defaultScopes.joined(separator: " ")).typeStyle(.monoCaption)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Browser sign-in")
                } footer: {
                    Text(
                        "Ask your GitLab administrator to register a non-confidential application with this redirect URI and scopes. No secret is needed."
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(caIDs, id: \.self) { caID in
                        if let info = accounts.caStore.load(caID)?.1 {
                            CertificateRow(info: info) { caIDs.removeAll { $0 == caID } }
                        }
                    }
                    Button("Import Certificate Authority…", action: importCA)
                    if let caError {
                        Text(caError).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Custom certificate authorities")
                } footer: {
                    Text(
                        "Trusted only for this server, in addition to the system's roots. To rotate, import the new CA, then remove the old one."
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Network") {
                    ProxyModeEditor(mode: $proxy, allowsInherit: true, accounts: accounts)
                }
                if let editing {
                    Section("Test connection") {
                        DiagnosticsView(
                            instance: draft ?? editing,
                            account: accounts.profiles.accounts.first { $0.instanceID == editing.id },
                            accounts: accounts)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add Server" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil)
            }
            .padding(Space.s6)
        }
        .frame(width: 580, height: 640)
        .onAppear(perform: load)
    }

    private var parsedURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host,
            HostSyntax.isHostname(host) || host == "localhost", url.user == nil, url.password == nil, url.query == nil
        else { return nil }
        return url
    }

    private var urlProblem: String? {
        guard !baseURL.isEmpty else { return nil }
        return parsedURL == nil
            ? "Enter an https:// URL without credentials (e.g. https://git.corp.example/gitlab)." : nil
    }

    private var draft: ProviderInstance? {
        guard let url = parsedURL, !name.trimmingCharacters(in: .whitespaces).isEmpty,
            let port = Int(sshPort), (1...65_535).contains(port)
        else { return nil }
        let host = sshHost.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host ?? "") : sshHost
        guard HostSyntax.isHostname(host) else { return nil }
        let clientID = oauthID.trimmingCharacters(in: .whitespaces)
        return ProviderInstance(
            id: id, kind: .gitlab, name: name.trimmingCharacters(in: .whitespaces), webBaseURL: url, sshHost: host,
            sshPort: port, oauthClientID: clientID.isEmpty ? nil : clientID, caCertificateIDs: caIDs, proxy: proxy)
    }

    private func load() {
        guard let editing else { return }
        id = editing.id
        name = editing.name
        baseURL = editing.webBaseURL.absoluteString
        sshHost = editing.sshHost
        sshPort = "\(editing.sshPort)"
        oauthID = editing.oauthClientID ?? ""
        caIDs = editing.caCertificateIDs
        proxy = editing.proxy
    }

    private func importCA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.x509Certificate, .data]
        panel.message = "Choose your company's root or intermediate CA certificate (PEM, DER or .cer)."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do throws(CertificateImportError) {
            let info = try accounts.caStore.importCA(data)
            if !caIDs.contains(info.id) { caIDs.append(info.id) }
            caError = nil
        } catch {
            caError = error.description
        }
    }

    private func save() {
        guard let instance = draft else { return }
        accounts.profiles.upsertInstance(instance)
        finish()
    }
}

struct CertificateRow: View {
    let info: CertificateInfo
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            Image(systemName: "checkmark.seal").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(info.subject).typeStyle(.headline)
                Text("Issued by \(info.issuer)").typeStyle(.caption).foregroundStyle(.secondary)
                if let notAfter = info.notAfter {
                    Text(
                        info.isExpired()
                            ? "Expired \(notAfter.formatted(date: .abbreviated, time: .omitted))"
                            : "Valid until \(notAfter.formatted(date: .abbreviated, time: .omitted))"
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(info.isExpired() || info.expiresSoon() ? .token(.statusWarning) : .secondary)
                }
                Text("SHA-256 \(info.sha256)").typeStyle(.monoCaption).foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Remove", role: .destructive, action: remove).controlSize(.small)
        }
    }
}
