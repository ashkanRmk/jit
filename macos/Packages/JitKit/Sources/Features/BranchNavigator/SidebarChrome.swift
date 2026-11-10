import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// The sidebar's top row (0.0.3; it was the command bar's breadcrumb): the current branch with its
/// ahead/behind counts. A click lists every branch with a filter; choosing one switches to it.
struct SidebarBranchHeader: View {
    /// Held weakly: a hosted SwiftUI view can outlive its tab, and must not keep the graph alive (P6.6).
    final class Source {
        weak var controller: GraphViewController?
        init(_ controller: GraphViewController) { self.controller = controller }
    }

    let source: Source
    @State private var showsBranches = false
    @State private var isHovered = false

    var body: some View {
        if let controller = source.controller { content(controller) }
    }

    private func content(_ controller: GraphViewController) -> some View {
        let path = controller.session.info?.topLevel ?? controller.session.path
        let location = CommandBarLocation(
            repository: (path as NSString).lastPathComponent,
            branch: controller.session.status?.branch ?? BranchHeader())
        return Button {
            showsBranches = true
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: "arrow.triangle.branch")
                    .symbolSize(IconSize.md, weight: .medium)
                    .foregroundStyle(.token(.accentBase))
                    .frame(width: IconSize.lg)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Current branch")
                        .typeStyle(.caption)
                        .foregroundStyle(.secondary)
                    Text(location.branchTitle)
                        .typeStyle(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s2)
                if let tracking = location.tracking {
                    Text(tracking)
                        .typeStyle(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Image(systemName: "chevron.up.chevron.down")
                    .symbolSize(IconSize.sm - 2, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isHovered ? ColorToken.statePressed : ColorToken.stateHover).color.opacity(SidebarMetrics.cardOpacity),
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Branches — choose one to switch to it")
        .popover(isPresented: $showsBranches, arrowEdge: .trailing) {
            BranchPopover(controller: controller, isPresented: $showsBranches)
        }
        .padding(.horizontal, Space.s3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(location.accessibilityLabel)
        .accessibilityHint("Shows branches")
        .accessibilityAddTraits(.isButton)
    }
}

/// Values shared by the sidebar's own drawing (section containers, header, footer).
enum SidebarMetrics {
    /// The containers are a light wash so the sidebar's glass shows through them (0.0.3).
    static let cardOpacity: Double = 0.45
    static let rowHeight: CGFloat = 26
    static let footerHeight: CGFloat = 44
    static let logotypeHeight: CGFloat = 22
    /// Centres the logotype on the window controls.
    static let logotypeTop: CGFloat = 15
}

/// The sidebar's bottom row (0.0.3; the profile used to be a toolbar item): the active Git profile, which
/// opens the profile switcher, and the Settings button.
struct SidebarFooter: View {
    let store: ProfileStore
    @State private var hoversProfile = false

    var body: some View {
        HStack(spacing: Space.s3) {
            Button {
                NSApp.sendAction(Selector(("showProfileSwitcher:")), to: nil, from: nil)
            } label: {
                HStack(spacing: Space.s4) {
                    if let profile = store.activeProfile {
                        ProfileAvatar(profile: profile, size: ProfileMetrics.largeAvatar - 4)
                        Text(profile.displayName)
                            .typeStyle(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .symbolSize(IconSize.lg)
                            .foregroundStyle(.token(.statusWarning))
                            .accessibilityHidden(true)
                        Text("No Profile")
                            .typeStyle(.body)
                            .foregroundStyle(.token(.statusWarning))
                    }
                    Image(systemName: "chevron.down")
                        .symbolSize(IconSize.sm - 3, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .background(
                    hoversProfile ? ColorToken.stateHover.color : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoversProfile = $0 }
            .help(profileHelp)
            .accessibilityLabel(profileAccessibility)
            Button {
                NSApp.sendAction(CommandRegistry.showSettings, to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
                    .symbolSize(IconSize.md, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: IconSize.lg + Space.s4, height: IconSize.lg + Space.s4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Space.s4)
        .frame(height: SidebarMetrics.footerHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(ColorToken.borderSubtle.color).frame(height: Border.hairline)
        }
    }

    private var profileHelp: String {
        guard let profile = store.activeProfile else { return "No Git profile — commits need an identity" }
        return "\(profile.author.name) <\(profile.author.email)>"
    }

    private var profileAccessibility: String {
        guard let profile = store.activeProfile else { return "No profile. Choose a Git profile" }
        return "Profile \(profile.displayName), \(profile.author.email). Switch profile"
    }
}

/// Branch list with a filter: current first, then local and remote branches. Choosing a branch switches to
/// it (a remote branch checks out its local tracking branch); the context menu reveals it in the graph.
struct BranchPopover: View {
    let controller: GraphViewController
    @Binding var isPresented: Bool
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { if let first = sections.first?.refs.first { choose(first) } }
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
                                    choose(ref)
                                } label: {
                                    BranchRow(ref: ref)
                                }
                                .buttonStyle(.plain)
                                .disabled(ref.commit == nil)
                                .contextMenu {
                                    Button("Show in Graph") { reveal(ref) }
                                    Button("New Branch Here…") {
                                        isPresented = false
                                        controller.operations?.newBranch(at: ref.fullName, label: ref.shortName)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: 320, height: 300)
            }
            Text("Choose a branch to switch to it. Right-click for more.")
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

    private func choose(_ ref: GitRef) {
        isPresented = false
        if ref.isHead { return reveal(ref) }
        controller.operations?.checkout(ref: ref)
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
        .accessibilityHint(ref.isHead ? "Current branch" : "Switches to this branch")
    }
}
