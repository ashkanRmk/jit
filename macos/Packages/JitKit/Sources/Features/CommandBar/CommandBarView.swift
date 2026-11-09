import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// The repository command bar's leading groups (P3.0 spec): location breadcrumb, changes, tools and the
/// `⋯` overflow. Chrome, so Liquid Glass in one `GlassEffectContainer`; it holds no Git state of its own
/// and observes `RepositorySession` (no polling). The find group (scope + search) is drawn by `GraphBar`.
struct CommandBarLeading: View {
    let controller: GraphViewController
    let layout: CommandBarLayout
    let location: CommandBarLocation
    let changes: Int?
    @State private var showsBranches = false

    var body: some View {
        GlassControlGroup(spacing: Space.s4) {
            ForEach(layout.visible, id: \.self) { group in
                switch group {
                case .location: locationGroup
                case .changes: if let changes { changesButton(changes) }
                case .terminal: terminalButton
                default: EmptyView()
                }
            }
            if !layout.overflow.isEmpty { overflowMenu }
        }
        .labelStyle(CommandBarLabelStyle(showsTitle: layout.showsLabels))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository command bar")
    }

    private var repositoryPath: String { controller.session.info?.topLevel ?? controller.session.path }

    // MARK: Location

    private var locationGroup: some View {
        HStack(spacing: Space.s3) {
            if layout.showsLabels {
                Menu {
                    Button("Reveal in Finder") { RepositoryActions.revealInFinder(repositoryPath) }
                    Button("Copy Path") { RepositoryActions.copyPath(repositoryPath) }
                } label: {
                    Text(location.repository)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(1)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Repository \(location.repository)")
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.token(.textTertiary))
                    .accessibilityHidden(true)
            }
            Button {
                showsBranches = true
            } label: {
                HStack(spacing: Space.s3) {
                    Image(systemName: "arrow.triangle.branch")
                        .symbolSize(IconSize.sm)
                        .accessibilityHidden(true)
                    Text(location.branchTitle)
                        .typeStyle(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                    if let tracking = location.tracking {
                        Text(tracking)
                            .typeStyle(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.token(.textSecondary))
                    }
                    Image(systemName: "chevron.down")
                        .symbolSize(IconSize.sm - 3, weight: .semibold)
                        .foregroundStyle(.token(.textSecondary))
                        .accessibilityHidden(true)
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Branches")
            .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
                BranchPopover(controller: controller, isPresented: $showsBranches)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .jitGlass(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(location.accessibilityLabel)
        .accessibilityHint("Shows branches")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showsBranches = true }
    }

    // MARK: Changes & tools

    private func changesButton(_ count: Int) -> some View {
        Button {
            controller.selectWorkingDirectory()
        } label: {
            Label(CommandBarChanges.title(count, labels: true), systemImage: "circle.dashed")
                .monospacedDigit()
        }
        .buttonStyle(.glass)
        .help("\(CommandBarChanges.title(count, labels: true)) in the working directory")
        .accessibilityLabel("\(CommandBarChanges.title(count, labels: true)), show working directory")
    }

    private var terminalButton: some View {
        Button {
            RepositoryActions.openInTerminal(repositoryPath)
        } label: {
            Label("Terminal", systemImage: "apple.terminal")
        }
        .buttonStyle(.glass)
        .help("Open in Terminal (⌥⌘T)")
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(layout.overflow, id: \.self) { group in
                switch group {
                case .terminal:
                    Button("Open in Terminal") { RepositoryActions.openInTerminal(repositoryPath) }
                default: EmptyView()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}

/// Title + icon when the bar has room (or Show Labels is on), icon only otherwise.
struct CommandBarLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s3) {
            configuration.icon
            if showsTitle { configuration.title.typeStyle(.callout) }
        }
    }
}

/// Branch list with a filter: current first, then local and remote branches. Phase 3 reveals the chosen
/// branch in the graph; switching branches arrives with Phase 4.
private struct BranchPopover: View {
    let controller: GraphViewController
    @Binding var isPresented: Bool
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { if let first = sections.first?.refs.first { reveal(first) } }
            if sections.isEmpty {
                Text(filter.isEmpty ? "No branches yet" : "No matching branches")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .frame(width: 300, height: 60)
            } else {
                List {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.refs, id: \.fullName) { ref in
                                Button {
                                    reveal(ref)
                                } label: {
                                    BranchRow(ref: ref)
                                }
                                .buttonStyle(.plain)
                                .disabled(ref.commit == nil)
                            }
                        }
                    }
                }
                .frame(width: 320, height: 300)
            }
            Text("Switching branches arrives with branch operations.")
                .typeStyle(.caption)
                .foregroundStyle(.token(.textTertiary))
        }
        .padding(Space.s6)
        .onAppear { filterFocused = true }
    }

    private struct BranchSection {
        let title: String
        let refs: [GitRef]
    }

    private var sections: [BranchSection] {
        let refs = controller.currentRefs?.refs ?? []
        func matching(_ list: [GitRef]) -> [GitRef] {
            filter.isEmpty ? list : list.filter { FuzzyMatch.matches(filter, $0.shortName) }
        }
        let current = matching(refs.filter { $0.isHead && $0.kind == .local })
        let local = matching(refs.filter { $0.kind == .local && !$0.isHead })
        let remote = matching(refs.filter { $0.kind == .remote && !$0.fullName.hasSuffix("/HEAD") })
        return [
            BranchSection(title: "Current", refs: current), BranchSection(title: "Local", refs: local),
            BranchSection(title: "Remote", refs: remote),
        ].filter { !$0.refs.isEmpty }
    }

    private func reveal(_ ref: GitRef) {
        guard let commit = ref.commit else { return }
        controller.select(oid: commit)
        isPresented = false
    }
}

private struct BranchRow: View {
    let ref: GitRef

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: ref.isHead ? "checkmark" : "arrow.triangle.branch")
                .symbolSize(IconSize.sm)
                .foregroundStyle(ref.isHead ? .token(.accentBase) : .token(.textSecondary))
                .frame(width: IconSize.md)
                .accessibilityHidden(true)
            Text(ref.shortName)
                .typeStyle(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.s4)
            if ref.upstream != nil, ref.ahead > 0 || ref.behind > 0 {
                Text("↑\(ref.ahead) ↓\(ref.behind)")
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textSecondary))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this branch in the graph")
    }
}
