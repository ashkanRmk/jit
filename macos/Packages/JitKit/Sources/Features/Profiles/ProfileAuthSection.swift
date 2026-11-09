import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Editable copy of a profile's authentication (design §3.2 Authentication group).
struct ProfileAuthDraft: Equatable {
    var instanceID: ProviderInstanceID?
    var accountID: HostingAccountID?
    var transport: Transport = .https
    var sshMode: SSHMode = .none
    var keyPath: String?
    var keyFingerprint: String?
    var useUserSSHConfig = false

    enum SSHMode: String, CaseIterable, Identifiable {
        case none, agent, keyFile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Not used"
            case .agent: "Keys in ssh-agent"
            case .keyFile: "Key file"
            }
        }
    }

    init() {}

    init(_ auth: ProfileAuth?) {
        guard let auth else { return }
        instanceID = auth.instanceID
        accountID = auth.accountID
        transport = auth.preferredTransport
        useUserSSHConfig = auth.useUserSSHConfig
        switch auth.ssh {
        case .agent: sshMode = .agent
        case .keyFile(let path, let fingerprint):
            sshMode = .keyFile
            keyPath = path
            keyFingerprint = fingerprint
        case nil: sshMode = .none
        }
    }

    var value: ProfileAuth? {
        guard let instanceID else { return nil }
        let ssh: SSHIdentity?
        switch sshMode {
        case .none: ssh = nil
        case .agent: ssh = .agent
        case .keyFile:
            if let keyPath, let keyFingerprint {
                ssh = .keyFile(path: keyPath, fingerprint: keyFingerprint)
            } else {
                ssh = nil
            }
        }
        return ProfileAuth(
            instanceID: instanceID, accountID: accountID, preferredTransport: transport, ssh: ssh,
            useUserSSHConfig: useUserSSHConfig)
    }

    /// An error that blocks saving (inline under the field).
    @MainActor
    func blockingIssue(_ store: ProfileStore) -> String? {
        if sshMode == .keyFile && (keyPath == nil || keyFingerprint == nil) { return "Choose an SSH key file." }
        if let accountID, store.account(accountID)?.instanceID != instanceID {
            return "The account belongs to another server."
        }
        return nil
    }
}

struct ProfileAuthSection: View {
    let store: ProfileStore
    @Binding var draft: ProfileAuthDraft
    let openAccounts: () -> Void
    @State private var keyError: String?

    var body: some View {
        Section {
            Picker("Provider", selection: $draft.instanceID) {
                Text("None (identity only)").tag(ProviderInstanceID?.none)
                ForEach(store.allInstances) { instance in
                    Text(instance.isSelfManaged ? "\(instance.name) (self-managed)" : instance.name)
                        .tag(ProviderInstanceID?.some(instance.id))
                }
            }
            .onChange(of: draft.instanceID) { _, _ in
                if let accountID = draft.accountID, store.account(accountID)?.instanceID != draft.instanceID {
                    draft.accountID = nil
                }
            }
            if let instanceID = draft.instanceID {
                let accounts = store.accounts.filter { $0.instanceID == instanceID }
                LabeledContent("Account") {
                    HStack {
                        Picker("Account", selection: $draft.accountID) {
                            Text(accounts.isEmpty ? "No accounts connected" : "None (SSH only)")
                                .tag(HostingAccountID?.none)
                            ForEach(accounts) { account in
                                Text("@\(account.login)").tag(HostingAccountID?.some(account.id))
                            }
                        }
                        .labelsHidden()
                        Button("Connect Account…", action: openAccounts)
                    }
                }
                Picker("Clone with", selection: $draft.transport) {
                    ForEach(Transport.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("SSH identity", selection: $draft.sshMode) {
                    ForEach(ProfileAuthDraft.SSHMode.allCases) { Text($0.title).tag($0) }
                }
                if draft.sshMode == .keyFile {
                    LabeledContent("Key file") {
                        HStack {
                            VStack(alignment: .trailing, spacing: Space.s1) {
                                Text(draft.keyPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                                    .typeStyle(.monoCaption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let fingerprint = draft.keyFingerprint {
                                    Text(fingerprint).typeStyle(.monoCaption).foregroundStyle(.secondary)
                                }
                            }
                            Button("Choose…", action: chooseKey)
                        }
                    }
                    if let keyError {
                        Text(keyError).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                    }
                }
                if draft.sshMode != .none {
                    Toggle("Use my ~/.ssh/config for this profile", isOn: $draft.useUserSSHConfig)
                    Text(
                        draft.useUserSSHConfig
                            ? "Host aliases and ProxyJump from ~/.ssh/config apply — but so can IdentityFile rules for other accounts. Jit still never edits that file."
                            : "Off: SSH ignores ~/.ssh/config, so another account's IdentityFile rules can't make Jit sign in as someone else."
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(draft.useUserSSHConfig ? .token(.statusWarning) : .secondary)
                }
                if let instance = store.instance(instanceID), instance.isSelfManaged {
                    LabeledContent("Network") {
                        Text(networkSummary(instance)).foregroundStyle(.secondary)
                    }
                }
                if let issue = draft.blockingIssue(store) {
                    Text(issue).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text(
                "How this profile signs in to remotes. Secrets stay in the Keychain; Jit never falls back to other credentials."
            )
            .typeStyle(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func networkSummary(_ instance: ProviderInstance) -> String {
        let ca = instance.caCertificateIDs.isEmpty ? "system trust" : "\(instance.caCertificateIDs.count) custom CA"
        return "\(ca) · proxy: \(instance.proxy.title) — edit in Servers & Network"
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "Choose the private SSH key this profile uses."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path.hasSuffix(".pub") ? String(url.path.dropLast(4)) : url.path
        Task {
            if let fingerprint = await SSHTools.fingerprint(ofKeyFile: path) {
                draft.keyPath = path
                draft.keyFingerprint = fingerprint
                keyError = nil
            } else {
                keyError = "That file isn't an SSH key Jit can read."
            }
        }
    }
}
