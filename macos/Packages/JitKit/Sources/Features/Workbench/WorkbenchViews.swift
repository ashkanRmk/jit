import DesignSystem
import GitCore
import Services
import SwiftUI

/// Main region: repository header + status summary (opaque content). Phase 1 shows only what works —
/// no history or branch placeholders.
struct WorkbenchMainView: View {
    let session: RepositorySession
    let tab: TabModel
    let actions: WorkbenchActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let error = session.error {
                ScrollView {
                    RepositoryErrorView(error: error, path: session.path, actions: actions)
                        .frame(maxWidth: PanelMetrics.contentColumnMax)
                        .padding(Space.s9)
                        .frame(maxWidth: .infinity)
                }
                .transition(RevealTransition.transition(reduceMotion: reduceMotion))
            } else if let info = session.info, let status = session.status {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        RepositoryHeader(info: info, status: status)
                        if let summary = status.summary {
                            StatusSummaryBlock(summary: summary)
                        } else {
                            BareRepositoryNote()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s9)
                    .padding(.vertical, Space.s8)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                DelayedLoadingPlaceholder(title: tab.title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfaceCanvas.color.ignoresSafeArea())
        .animation(MotionToken.panel.animation, value: session.error != nil)
    }
}

/// Name, HEAD, upstream and operation chip (design §3.3).
struct RepositoryHeader: View {
    let info: RepositoryInfo
    let status: RepositoryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s5) {
                Text(info.displayName)
                    .typeStyle(.display)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let chip = OperationChip.title(for: status.operation) {
                    OperationChip(title: chip)
                }
            }
            HStack(spacing: Space.s6) {
                Label {
                    Text(headText)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                } icon: {
                    Image(systemName: status.branch.isDetached ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                        .foregroundStyle(.token(.textTertiary))
                }
                .accessibilityLabel(headAccessibility)
                if let upstream = status.branch.upstream {
                    UpstreamLabel(upstream: upstream, ahead: status.branch.ahead, behind: status.branch.behind)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headText: String {
        if status.branch.isUnborn { return "\(status.branch.head ?? "") — No commits yet" }
        return BranchLabel.text(for: status.branch)
    }

    private var headAccessibility: String {
        status.branch.isDetached ? headText : "Branch \(headText)"
    }
}

private struct UpstreamLabel: View {
    let upstream: String
    let ahead: Int?
    let behind: Int?

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(.token(.textTertiary))
                .accessibilityHidden(true)
            Text(upstream)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
            if let ahead, let behind {
                Text("↑\(ahead)  ↓\(behind)")
                    .typeStyle(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.token(ahead + behind > 0 ? .textPrimary : .textTertiary))
            } else {
                Text("upstream gone")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textTertiary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let ahead, let behind else { return "Upstream \(upstream) no longer exists" }
        return "Upstream \(upstream), \(ahead) ahead, \(behind) behind"
    }
}

struct OperationChip: View {
    let title: String

    static func title(for operation: OperationState) -> String? {
        switch operation {
        case .none: nil
        case .merging: "Merging"
        case .rebasing(let step?, let total?): "Rebasing \(step)/\(total)"
        case .rebasing: "Rebasing"
        case .cherryPicking: "Cherry-picking"
        case .reverting: "Reverting"
        case .bisecting: "Bisecting"
        case .applyingMailbox: "Applying patches"
        }
    }

    var body: some View {
        Text(title)
            .typeStyle(.caption)
            .foregroundStyle(.token(.statusWarning))
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s1)
            .background(ColorToken.statusWarning.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(ColorToken.statusWarning.color.opacity(0.4), lineWidth: Border.hairline))
            .accessibilityLabel("Operation in progress: \(title)")
    }
}

/// Staged / unstaged / untracked / conflicted counts.
struct StatusSummaryBlock: View {
    let summary: StatusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Working directory")
                .typeStyle(.micro)
                .foregroundStyle(.token(.textTertiary))
            HStack(spacing: Space.s5) {
                StatCell(value: summary.staged, label: "Staged", symbol: "checkmark.circle", tint: .statusSuccess)
                StatCell(value: summary.unstaged, label: "Unstaged", symbol: "pencil.circle", tint: .accentBase)
                StatCell(value: summary.untracked, label: "Untracked", symbol: "plus.circle", tint: .statusInfo)
                StatCell(
                    value: summary.conflicted, label: "Conflicted", symbol: "exclamationmark.triangle",
                    tint: .statusDanger)
            }
            if summary.isClean {
                Text("No local changes.")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
    }
}

private struct StatCell: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: ColorToken

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Image(systemName: symbol)
                .symbolSize(IconSize.md)
                .foregroundStyle(.token(value > 0 ? tint : .textTertiary))
            Text("\(value)")
                .typeStyle(.display)
                .monospacedDigit()
                .foregroundStyle(.token(value > 0 ? .textPrimary : .textTertiary))
            Text(label)
                .typeStyle(.caption)
                .foregroundStyle(.token(.textSecondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(padding: Space.s6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label.lowercased())")
    }
}

private struct BareRepositoryNote: View {
    var body: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "shippingbox")
                .symbolSize(IconSize.md)
                .foregroundStyle(.token(.textTertiary))
            Text("Bare repository — no working tree")
                .typeStyle(.body)
                .foregroundStyle(.token(.textSecondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(padding: Space.s6)
    }
}

/// A static, faint placeholder that appears only if loading takes longer than 150 ms (no shimmer).
struct DelayedLoadingPlaceholder: View {
    let title: String
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: Space.s4) {
            ProgressView().controlSize(.small)
            Text("Reading \(title)…")
                .typeStyle(.callout)
                .foregroundStyle(.token(.textTertiary))
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: OverlayMetrics.loadingPlaceholderDelay)
            if !Task.isCancelled { isVisible = true }
        }
    }
}

/// Error state with recovery actions: Locate…, Remove Tab, Retry.
struct RepositoryErrorView: View {
    let error: GitCoreError
    let path: String
    let actions: WorkbenchActions
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolSize(IconSize.md)
                    .foregroundStyle(.token(.statusDanger))
                    .accessibilityHidden(true)
                Text(error.summary)
                    .typeStyle(.title)
                    .foregroundStyle(.token(.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(path)
                .typeStyle(.monoCaption)
                .foregroundStyle(.token(.textSecondary))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let guidance = ErrorGuidance.text(for: error) {
                Text(guidance)
                    .typeStyle(.body)
                    .foregroundStyle(.token(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = error.detail {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    Text(detail)
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textSecondary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s4)
                        .background(
                            ColorToken.surfaceSunken.color,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .typeStyle(.callout)
            }
            HStack(spacing: Space.s4) {
                Button("Retry", action: actions.retry)
                    .keyboardShortcut(.defaultAction)
                Button("Locate…", action: actions.locate)
                Button("Remove Tab", role: .destructive, action: actions.removeTab)
            }
            .controlSize(.large)
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .onAppear { AccessibilityNotification.Announcement(error.summary).post() }
    }
}

/// System glass sidebar: repository summary only (branch lists arrive in Phase 2).
struct SidebarView: View {
    let session: RepositorySession

    var body: some View {
        List {
            Section("Repository") {
                if let info = session.info {
                    Label(info.displayName, systemImage: "folder")
                        .help(info.topLevel ?? info.gitDirectory)
                    Text(info.topLevel ?? info.gitDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Label(kindTitle(info), systemImage: kindSymbol(info))
                    if info.kind == .linkedWorktree {
                        Text("Main repository: \((info.commonDirectory as NSString).deletingLastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } else {
                    Label((session.path as NSString).lastPathComponent, systemImage: "folder")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func kindTitle(_ info: RepositoryInfo) -> String {
        switch info.kind {
        case .regular: "Standard repository"
        case .bare: "Bare repository"
        case .linkedWorktree: "Linked worktree"
        }
    }

    private func kindSymbol(_ info: RepositoryInfo) -> String {
        switch info.kind {
        case .regular: "externaldrive"
        case .bare: "shippingbox"
        case .linkedWorktree: "square.on.square"
        }
    }
}

/// Inspector (opaque content): working-directory summary and Finder/Terminal actions.
struct InspectorView: View {
    let session: RepositorySession
    let actions: WorkbenchActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                Text("Working directory")
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                if let status = session.status {
                    if let summary = status.summary {
                        Grid(alignment: .leading, horizontalSpacing: Space.s6, verticalSpacing: Space.s3) {
                            row("Staged", summary.staged)
                            row("Unstaged", summary.unstaged)
                            row("Untracked", summary.untracked)
                            row("Conflicted", summary.conflicted)
                        }
                    } else {
                        Text("Bare repository — no working tree")
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                    }
                } else if session.error == nil {
                    Text("Loading…")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textTertiary))
                }
                if session.info?.topLevel != nil {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        Button("Open in Finder", systemImage: "folder", action: actions.revealInFinder)
                        Button("Open in Terminal", systemImage: "terminal", action: actions.openInTerminal)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, Space.s2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s7)
        }
        .background(ColorToken.surfacePanel.color.ignoresSafeArea())
    }

    private func row(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
            Text("\(value)")
                .typeStyle(.callout)
                .monospacedDigit()
                .foregroundStyle(.token(value > 0 ? .textPrimary : .textTertiary))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plain-language recovery guidance per error.
enum ErrorGuidance {
    static func text(for error: GitCoreError) -> String? {
        switch error {
        case .gitNotFound:
            "Install the Xcode Command Line Tools (run “xcode-select --install” in Terminal) or Git from Homebrew, then try again."
        case let .gitTooOld(found, required):
            "This Mac has Git \(found). Install Git \(required) or newer — for example from Homebrew — then try again."
        case .unsafeRepository:
            "Git protects you from repositories owned by other users. If you trust this folder, you can allow it with “git config --global --add safe.directory <path>”. Jit never changes this setting for you."
        case .permissionDenied:
            "Check the folder's permissions in Finder (Get Info → Sharing & Permissions)."
        case .notARepository:
            "Pick the folder that contains your project's .git folder, or any folder inside it."
        case .pathNotFound:
            "The folder may have been moved, renamed, deleted, or its disk ejected. Use Locate… to point Jit at its new location."
        default:
            nil
        }
    }
}
