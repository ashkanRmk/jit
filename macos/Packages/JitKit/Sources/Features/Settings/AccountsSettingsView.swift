import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Settings ▸ Accounts (design §3.2): one row per hosting account with method, scopes, expiry, last check and
/// status; Check Now, Replace Token…, Reconnect, Disconnect…. Nothing is checked in the background.
struct AccountsSettingsView: View {
    let accounts: AccountsService
    let open: (SettingsWindowController.Pane) -> Void
    @State private var connect: ConnectAccountRequest?
    @State private var pendingDisconnect: HostingAccount?
    @State private var checking: Set<HostingAccountID> = []
    @State private var checkMessages: [HostingAccountID: String] = [:]

    private var store: ProfileStore { accounts.profiles }

    var body: some View {
        Form {
            if store.accounts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text("No hosting accounts yet").typeStyle(.headline)
                        Text(
                            "Connect a GitHub or GitLab account to push and pull over HTTPS and browse your repositories. Tokens are stored only in your Keychain."
                        )
                        .typeStyle(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Space.s2)
                }
            }
            ForEach(store.allInstances.filter { instance in store.accounts.contains { $0.instanceID == instance.id } })
            {
                instance in
                Section(instance.isSelfManaged ? "\(instance.name) — \(instance.httpsHost)" : instance.name) {
                    ForEach(store.accounts.filter { $0.instanceID == instance.id }) { account in
                        accountRow(account, instance: instance)
                    }
                }
            }
            Section {
                HStack {
                    Button("Connect Account…") { connect = ConnectAccountRequest(replacing: nil) }
                    Spacer()
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
                Image(systemName: ProviderSymbols.symbol(instance.kind))
                    .symbolSize(IconSize.lg)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text("@\(account.login)").typeStyle(.headline)
                        AccountStatusDot(status: account.status)
                        Text(account.status.title).typeStyle(.caption).foregroundStyle(.secondary)
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
                Spacer()
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
