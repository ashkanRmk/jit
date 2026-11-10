import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// The repository action bar's commands (0.0.3, replacing the P3.0 glass capsules): Fetch, Branch, Pull, Push,
/// Stash, Pop and Terminal as plain icon-over-title items inside one glass bar. Nothing here is a bordered
/// button; the bar is the only glass. It holds no Git state of its own and observes `RepositorySession`.
struct CommandBarActions: View {
    let controller: GraphViewController
    let layout: CommandBarLayout

    var body: some View {
        HStack(spacing: Space.s2) {
            // Fetch leads; Pull and Push sit in the middle of the row, after Branch (0.0.5).
            if layout.visible.contains(.sync), let operations = controller.operations {
                FetchAction(operations: operations)
            }
            ForEach(layout.visible, id: \.self) { group in
                switch group {
                case .sync: if let operations = controller.operations { SyncActions(operations: operations) }
                case .branch: if let operations = controller.operations { newBranchAction(operations) }
                case .stash: if let operations = controller.operations { StashActions(operations: operations) }
                case .terminal: terminalAction
                default: EmptyView()
                }
            }
            if !layout.overflow.isEmpty { overflowMenu }
        }
        .environment(\.barShowsTitles, layout.showsLabels)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository actions")
    }

    private var repositoryPath: String { controller.session.info?.topLevel ?? controller.session.path }

    private func newBranchAction(_ operations: OperationsController) -> some View {
        BarAction(title: "Branch", symbol: "arrow.triangle.branch", help: "New branch from HEAD") {
            operations.newBranch(at: "HEAD", label: controller.session.status?.branch.head ?? "HEAD")
        }
    }

    private var terminalAction: some View {
        BarAction(title: "Terminal", symbol: "apple.terminal", help: "Open in Terminal (⌥⌘T)") {
            RepositoryActions.openInTerminal(repositoryPath)
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(layout.overflow, id: \.self) { group in
                switch group {
                case .terminal:
                    Button("Open in Terminal") { RepositoryActions.openInTerminal(repositoryPath) }
                case .branch:
                    Button("New Branch…") { controller.operations?.newBranch(at: "HEAD", label: "HEAD") }
                case .stash:
                    Button("Stash Changes…") { controller.operations?.createStash() }
                    Button("Pop Latest Stash") { controller.operations?.popLatest() }
                        .disabled(controller.session.stashes?.isEmpty ?? true)
                default: EmptyView()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .symbolSize(IconSize.md, weight: .medium)
                .frame(width: BarMetrics.iconBox, height: BarMetrics.iconBox)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}

/// Sizes of the action bar's items (also used to decide what fits).
enum BarMetrics {
    static let iconBox: CGFloat = IconSize.md + Space.s1
    static let itemPadding: CGFloat = Space.s3
    static let itemMinWidth: CGFloat = 40

    /// Width of one item with its title, or with the icon alone.
    @MainActor static func itemWidth(_ title: String?) -> CGFloat {
        guard let title else { return iconBox + 2 * itemPadding }
        let text = ceil((title as NSString).size(withAttributes: [.font: TypeToken.caption.nsFont]).width)
        return max(itemMinWidth, max(text, iconBox) + 2 * itemPadding)
    }
}

extension EnvironmentValues {
    /// View ▸ Command Bar ▸ Show Labels, or the bar is too narrow for titles.
    @Entry var barShowsTitles = true
}

/// One command of the action bar: an icon with its title underneath. Plain content with a hover wash — no
/// border, no glass of its own.
struct BarAction: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.barShowsTitles) private var showsTitles

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s1) {
                Image(systemName: symbol)
                    .symbolSize(IconSize.md - 2, weight: .medium)
                    .frame(width: BarMetrics.iconBox, height: BarMetrics.iconBox)
                    .accessibilityHidden(true)
                if showsTitles {
                    Text(title)
                        .typeStyle(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(.token(isEnabled ? .textPrimary : .textDisabled))
            .padding(.horizontal, BarMetrics.itemPadding)
            .padding(.vertical, Space.s1)
            .frame(minWidth: showsTitles ? BarMetrics.itemMinWidth : nil)
            .background(
                isHovered && isEnabled ? ColorToken.stateHover.color : .clear,
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

/// Pull · Push. The click runs the main action; the other ways to pull are in the item's context menu and in
/// the Repository menu.
struct SyncActions: View {
    let operations: OperationsController

    private var branch: BranchHeader? { operations.session.status?.branch }

    var body: some View {
        BarAction(
            title: pullTitle, symbol: "arrow.down.to.line",
            help: branch?.upstream == nil
                ? "This branch has no upstream" : "Pull (fast-forward only) — right-click for merge or rebase"
        ) {
            operations.pull(.fastForwardOnly)
        }
        .disabled(branch?.upstream == nil)
        .contextMenu {
            Button("Pull — Fast-Forward Only") { operations.pull(.fastForwardOnly) }
            Button("Pull with Merge") { operations.pull(.merge) }
            Button("Pull with Rebase") { operations.pull(.rebase) }
        }
        BarAction(
            title: pushTitle, symbol: "arrow.up.to.line",
            help: branch?.upstream == nil ? "Publish this branch" : "Push to \(branch?.upstream ?? "upstream")"
        ) {
            operations.push()
        }
        .disabled(branch?.isDetached ?? true)
    }

    private var pullTitle: String {
        if let behind = branch?.behind, behind > 0 { return "Pull ↓\(behind)" }
        return "Pull"
    }

    private var pushTitle: String {
        guard let branch else { return "Push" }
        if branch.upstream == nil, !branch.isDetached { return "Publish" }
        if let ahead = branch.ahead, ahead > 0 { return "Push ↑\(ahead)" }
        return "Push"
    }
}

/// Fetch: the click fetches the upstream's remote; prune and all-remotes are in the context menu.
struct FetchAction: View {
    let operations: OperationsController

    private var branch: BranchHeader? { operations.session.status?.branch }

    var body: some View {
        BarAction(
            title: "Fetch", symbol: "arrow.triangle.2.circlepath",
            help: "Fetch \(defaultRemoteLabel) (never integrates) — right-click for more"
        ) {
            operations.fetch()
        }
        .contextMenu {
            Button("Fetch \(defaultRemoteLabel)") { operations.fetch() }
            Button("Fetch All Remotes") { operations.fetchAll() }
            Divider()
            Button("Fetch and Prune Deleted Branches") { operations.fetch(prune: true) }
            Button("Fetch Without Pruning") { operations.fetch(prune: false) }
        }
    }

    private var defaultRemoteLabel: String {
        branch?.upstream.flatMap { $0.split(separator: "/").first.map(String.init) } ?? "origin"
    }
}

/// Stash / Pop: Stash opens the create sheet (⌥-click stashes now, including untracked); Pop pops
/// `stash@{0}` and is disabled with a tooltip when there are no stashes.
struct StashActions: View {
    let operations: OperationsController

    var body: some View {
        BarAction(
            title: "Stash", symbol: "tray.and.arrow.down",
            help: "Stash changes (⌥⌘S) — ⌥-click to stash everything now"
        ) {
            if NSEvent.modifierFlags.contains(.option) {
                operations.quickStash()
            } else {
                operations.createStash()
            }
        }
        .disabled(operations.session.status?.summary?.isClean ?? true)
        BarAction(
            title: "Pop", symbol: "tray.and.arrow.up",
            help: (operations.session.stashes?.isEmpty ?? true) ? "No stashes" : "Pop the latest stash"
        ) {
            operations.popLatest()
        }
        .disabled(operations.session.stashes?.isEmpty ?? true)
        .onAppear { if operations.session.stashes == nil { operations.session.loadStashes() } }
    }
}
