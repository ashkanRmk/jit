import AppKit
import DesignSystem
import Services
import SwiftUI

/// The remote repository browser (design §3.6, ADR-0006): the account list is the system sidebar (Liquid Glass
/// by the system), the search field sits in the toolbar (`.searchable`), and the repository list and detail are
/// opaque content surfaces from `DesignSystem`. No glass on rows, no custom materials or animations.
public struct RepositoryBrowserView: View {
    @Bindable var model: RepositoryBrowserModel

    public init(model: RepositoryBrowserModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            AccountSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            RepositoryListPane(model: model)
                .navigationSplitViewColumnWidth(min: 320, ideal: 400)
        } detail: {
            RepositoryDetailPane(model: model)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: Text(searchPrompt))
        .navigationTitle("Remote Repositories")
        .onAppear { model.open() }
        .alert(
            model.pendingSwitch.map { "Switch to '\($0.profileName)' and clone?" } ?? "",
            isPresented: Binding(
                get: { model.pendingSwitch != nil }, set: { if !$0 { model.cancelPendingSwitch() } }),
            presenting: model.pendingSwitch
        ) { _ in
            Button("Switch and Clone") { model.confirmPendingSwitch() }
            Button("Cancel", role: .cancel) { model.cancelPendingSwitch() }
        } message: { pending in
            Text(
                "\(pending.repositoryName) is only accessible with the account used by '\(pending.profileName)'. "
                    + "Jit makes '\(pending.profileName)' the active profile, then clones with it.")
        }
    }

    private var searchPrompt: String {
        model.filtersLocally ? "Filter loaded repositories" : "Search repositories"
    }
}

// MARK: - Sidebar

private struct AccountSidebar: View {
    let model: RepositoryBrowserModel

    var body: some View {
        List(selection: Binding(get: { model.selectedAccountID }, set: { model.selectAccount($0) })) {
            ForEach(model.accountGroups, id: \.instance.id) { group in
                Section(group.instance.name) {
                    ForEach(group.accounts) { account in
                        AccountRow(account: account, instance: group.instance).tag(account.id)
                    }
                }
            }
        }
        .overlay {
            if model.accounts.isEmpty {
                Text("No accounts")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccountRow: View {
    let account: HostingAccount
    let instance: ProviderInstance

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("@\(account.login)").lineLimit(1)
                Text(instance.httpsHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: Self.symbol(for: instance))
        }
        .badge(
            Text(Image(systemName: "circle.fill"))
                .foregroundStyle(.token(Self.statusColor(account.status)))
        )
        .help("\(instance.name) — @\(account.login) — \(account.status.title)")
        .accessibilityLabel("\(instance.name), @\(account.login), \(account.status.title)")
    }

    static func symbol(for instance: ProviderInstance) -> String {
        if instance.isSelfManaged { return "server.rack" }
        switch instance.kind {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gitlab: return "cube"
        }
    }

    static func statusColor(_ status: AccountStatus) -> ColorToken {
        switch status {
        case .ok: .statusSuccess
        case .expired, .rejected: .statusDanger
        case .unknown: .textTertiary
        }
    }
}

// MARK: - List

private struct RepositoryListPane: View {
    @Bindable var model: RepositoryBrowserModel

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                if model.selectedAccount == nil, !model.accounts.isEmpty {
                    StateMessage(symbol: "sidebar.left", title: "Choose an account", detail: nil)
                } else {
                    SkeletonList()
                }
            case .noAccounts:
                StateMessage(
                    symbol: "person.crop.circle.badge.plus", title: "No accounts connected",
                    detail: "Connect a GitHub or GitLab account to browse the repositories it can access."
                ) {
                    Button("Connect Account…") { model.connectAccount() }
                        .buttonStyle(.borderedProminent)
                }
            case .loading:
                SkeletonList()
            case .loaded:
                loadedContent
            case .needsAttention(let status):
                StateMessage(
                    symbol: "exclamationmark.triangle", title: "This account needs attention",
                    detail: status == .expired
                        ? "The sign-in for @\(model.selectedAccount?.login ?? "") has expired. Reconnect it in "
                            + "Settings ▸ Accounts."
                        : "The server rejected the token for @\(model.selectedAccount?.login ?? ""). Reconnect it "
                            + "in Settings ▸ Accounts."
                ) {
                    Button("Open Accounts Settings…") { model.reconnect() }
                }
            case .offline:
                StateMessage(
                    symbol: "wifi.slash", title: "You're offline — Jit will not retry automatically",
                    detail: "Connect to the network (or your VPN) and retry."
                ) {
                    Button("Retry") { model.retry() }
                }
            case .rateLimited(let resetAt):
                StateMessage(
                    symbol: "hourglass", title: "Rate limit reached",
                    detail: RepositoryBrowserModel.rateLimitText(resetAt)
                ) {
                    Button("Retry") { model.retry() }
                }
            case .failed(let message, let canTestConnection):
                StateMessage(symbol: "exclamationmark.octagon", title: "Couldn't load repositories", detail: message) {
                    HStack(spacing: Space.s4) {
                        Button("Retry") { model.retry() }
                        if canTestConnection {
                            Button("Test Connection…") { model.testConnection() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfaceCanvas.color)
    }

    @ViewBuilder private var loadedContent: some View {
        VStack(spacing: 0) {
            if model.searchAllResults != nil || model.searchAllState != .idle || model.canSearchAll {
                SearchAllBar(model: model)
                Divider()
            }
            if model.displayedItems.isEmpty {
                StateMessage(
                    symbol: "magnifyingglass", title: model.emptyMessage,
                    detail: model.filtersLocally && model.appliedQuery != nil && model.searchAllResults == nil
                        ? "Only the repositories loaded so far were filtered." : nil
                ) {
                    if model.nextCursor != nil, model.searchAllResults == nil {
                        Button("Load More") { model.loadNextPage() }
                            .disabled(model.isLoadingMore)
                    }
                }
            } else {
                List(selection: $model.selectedRepositoryID) {
                    ForEach(model.displayedItems) { repository in
                        RepositoryRow(repository: repository)
                            .tag(repository.id)
                            .onAppear { model.rowAppeared(repository.id) }
                    }
                    if model.searchAllResults == nil { ListFooter(model: model) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(ColorToken.surfaceCanvas.color)
            }
        }
    }
}

private struct SearchAllBar: View {
    let model: RepositoryBrowserModel

    var body: some View {
        HStack(spacing: Space.s4) {
            switch model.searchAllState {
            case .searching:
                ProgressView().controlSize(.small)
                Text("Searching all accessible repositories…")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.token(.statusWarning))
                Text(message)
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(2)
                Spacer(minLength: Space.s4)
                Button("Try Again") { model.searchAllAccessible() }
            case .idle:
                if model.searchAllResults != nil {
                    Text("Results from all accessible repositories (first 50)")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                    Spacer(minLength: Space.s4)
                    Button("Show Loaded Repositories") { model.showLoadedRepositories() }
                } else {
                    Text("Filtering loaded repositories")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                    Spacer(minLength: Space.s4)
                    Button("Search All Accessible Repositories") { model.searchAllAccessible() }
                        .help("Searches GitHub for repositories of this account and its organizations")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.surfacePanel.color)
    }
}

private struct ListFooter: View {
    let model: RepositoryBrowserModel

    var body: some View {
        if model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .accessibilityLabel("Loading more repositories")
        } else if let failure = model.loadMoreFailure {
            HStack(spacing: Space.s4) {
                Text(failure)
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(2)
                Spacer(minLength: Space.s4)
                Button("Retry") { model.loadNextPage() }
                    .controlSize(.small)
            }
        }
    }
}

private struct RepositoryRow: View {
    let repository: RemoteRepository

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(repository.owner)
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(repository.name)
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s4)
                if let visibility = repository.visibility { VisibilityBadge(visibility: visibility) }
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                Text(repository.description ?? "")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.s4)
                if let updated = repository.updatedAt {
                    // A static string — `Text(_:style: .relative)` would re-render on a timer.
                    Text(updated.formatted(.relative(presentation: .named)))
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .combine)
    }
}

struct VisibilityBadge: View {
    let visibility: RepositoryVisibility

    var body: some View {
        Text(Self.title(visibility))
            .typeStyle(.caption)
            .foregroundStyle(.token(.textSecondary))
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .overlay(
                Capsule().strokeBorder(ColorToken.borderStrong.color, lineWidth: Border.hairline)
            )
    }

    static func title(_ visibility: RepositoryVisibility) -> String {
        switch visibility {
        case .public: "Public"
        case .private: "Private"
        case .internal: "Internal"
        }
    }
}

/// Placeholder rows while the first page loads (no fake data: shapes only, hidden from accessibility as rows).
private struct SkeletonList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            ForEach(0..<8, id: \.self) { index in
                VStack(alignment: .leading, spacing: Space.s3) {
                    bar(width: 90, height: TypeToken.caption.size)
                    bar(width: index.isMultiple(of: 2) ? 180 : 140, height: TypeToken.headline.size)
                    bar(width: index.isMultiple(of: 3) ? 260 : 220, height: TypeToken.callout.size)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading repositories")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(ColorToken.surfaceSunken.color)
            .frame(width: width, height: height)
    }
}

private struct StateMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    @ViewBuilder var actions: Actions

    init(symbol: String, title: String, detail: String?, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Space.s5) {
            Image(systemName: symbol)
                .symbolSize(IconSize.hero, weight: .light)
                .foregroundStyle(.token(.textTertiary))
                .accessibilityHidden(true)
            Text(title)
                .typeStyle(.title)
                .foregroundStyle(.token(.textPrimary))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .typeStyle(.body)
                    .foregroundStyle(.token(.textSecondary))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions
        }
        .padding(Space.s9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension StateMessage where Actions == EmptyView {
    init(symbol: String, title: String, detail: String?) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: - Detail

private struct RepositoryDetailPane: View {
    @Bindable var model: RepositoryBrowserModel

    var body: some View {
        Group {
            if let repository = model.selectedRepository, let account = model.selectedAccount {
                RepositoryDetail(model: model, repository: repository, account: account)
            } else {
                StateMessage(symbol: "folder", title: "Select a repository", detail: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfacePanel.color)
    }
}

private struct RepositoryDetail: View {
    @Bindable var model: RepositoryBrowserModel
    let repository: RemoteRepository
    let account: HostingAccount

    var body: some View {
        let action = model.cloneAction(for: account)
        let url = model.cloneURL(for: repository, transport: model.transport)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s7) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(repository.owner)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                        .textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                        Text(repository.name)
                            .typeStyle(.display)
                            .foregroundStyle(.token(.textPrimary))
                            .textSelection(.enabled)
                        if let visibility = repository.visibility { VisibilityBadge(visibility: visibility) }
                    }
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .typeStyle(.body)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: Space.s4) {
                    Picker("Clone URL", selection: $model.transport) {
                        ForEach(Transport.allCases, id: \.self) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    URLLine(title: "HTTPS", value: repository.httpsCloneURL?.absoluteString)
                    URLLine(title: "SSH", value: repository.sshCloneURL)
                }
                .contentCard(padding: Space.s6)

                if let branch = repository.defaultBranch {
                    LabeledContent("Default branch") {
                        Text(branch)
                            .typeStyle(.monoBody)
                            .foregroundStyle(.token(.textPrimary))
                            .textSelection(.enabled)
                    }
                    .typeStyle(.body)
                }

                VStack(alignment: .leading, spacing: Space.s4) {
                    Button(model.cloneButtonTitle(for: account)) { model.clone(repository) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(url == nil || action.isUnavailable)
                    if case .unavailable(let reason) = action {
                        Text(reason)
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                    } else if url == nil {
                        Text("The server didn't provide an \(model.transport.title) URL for this repository.")
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                    } else if case .switchAndClone(_, let name) = action {
                        Text("@\(account.login) belongs to '\(name)'. Jit asks before switching profiles.")
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                    }
                }
            }
            .padding(Space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct URLLine: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: Space.s4) {
            Text(title)
                .typeStyle(.caption)
                .foregroundStyle(.token(.textTertiary))
                .frame(width: 44, alignment: .leading)
            Text(value ?? "Not provided")
                .typeStyle(.monoCaption)
                .foregroundStyle(.token(value == nil ? .textTertiary : .textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: Space.s4)
            Button {
                guard let value else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(value == nil)
            .help("Copy \(title) URL")
            .accessibilityLabel("Copy \(title) URL")
        }
    }
}

extension RepositoryBrowserModel.CloneAction {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
