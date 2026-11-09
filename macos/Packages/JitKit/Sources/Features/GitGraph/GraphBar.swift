import DesignSystem
import GitCore
import Services
import SwiftUI

/// The repository command bar (P3.0, replacing the Phase 2 graph bar): location, changes and tools on the
/// leading side (`CommandBarLeading`), then the find group — scope menu, search, match navigation and
/// transient chips. Chrome, so Liquid Glass in `GlassEffectContainer`s (`GlassControlGroup`) so the pieces
/// morph instead of stacking. Rows scroll underneath; nothing in the bar is a row.
struct GraphBar: View {
    let controller: GraphViewController
    @FocusState private var searchFocused: Bool
    @State private var showsBranchPicker = false
    @State private var barWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: GraphViewModel { controller.viewModel }

    var body: some View {
        let location = commandLocation
        let changes = CommandBarChanges.count(controller.session.status?.summary)
        let layout = commandLayout(location: location, changes: changes)
        HStack(spacing: Space.s4) {
            CommandBarLeading(controller: controller, layout: layout, location: location, changes: changes)
                .fixedSize()
            Spacer(minLength: 0)
            GlassControlGroup(spacing: Space.s3) {
                scopeMenu
                searchField
                if model.isSearching { matchControls }
                ForEach(chips, id: \.id) { chip in
                    ChipView(chip: chip)
                        .transition(RevealTransition.transition(reduceMotion: reduceMotion))
                }
            }
            Spacer(minLength: 0)
            // A merge/rebase/… in progress stays visible (it was in the Phase 1 header).
            if let operation = controller.session.status?.operation, let title = OperationChip.title(for: operation) {
                OperationChip(title: title)
            }
            if controller.isSlow || isDeepRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(isDeepRunning ? "Searching all history" : "Loading history")
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .animation(reduceMotion ? nil : MotionToken.glassMorph.animation, value: chips.map(\.id))
        .onChange(of: model.focusSearchToken) { searchFocused = true }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            barWidth = $0
        }
    }

    // MARK: Command bar layout

    private var commandLocation: CommandBarLocation {
        let path = controller.session.info?.topLevel ?? controller.session.path
        let repository = (path as NSString).lastPathComponent
        return CommandBarLocation(repository: repository, branch: controller.session.status?.branch ?? BranchHeader())
    }

    /// Labels drop first, then groups overflow (P3.0 spec). Widths are measured from the label strings with
    /// the bar's font; the find group keeps its minimum search width.
    private func commandLayout(location: CommandBarLocation, changes: Int?) -> CommandBarLayout {
        var groups: [CommandBarGroup] = [.location]
        if changes != nil { groups.append(.changes) }
        groups.append(.terminal)
        let font = TypeToken.callout.nsFont
        func text(_ string: String) -> CGFloat { ceil((string as NSString).size(withAttributes: [.font: font]).width) }
        let capsule = 2 * Space.s5  // horizontal padding of a glass capsule / button
        let icon = IconSize.md + Space.s3
        let tracking = location.tracking.map { text($0) + Space.s3 } ?? 0
        let branch = min(text(location.branchTitle), 220) + tracking + icon + IconSize.sm + Space.s3
        var widths: [CommandBarGroup: CommandBarLayout.GroupWidth] = [
            .location: .init(
                labelled: capsule + text(location.repository) + IconSize.sm + 2 * Space.s3 + branch,
                iconOnly: capsule + branch),
            .terminal: .init(labelled: capsule + icon + text("Terminal"), iconOnly: capsule + IconSize.md),
        ]
        if let changes {
            widths[.changes] = .init(
                labelled: capsule + icon + text(CommandBarChanges.title(changes, labels: true)),
                iconOnly: capsule + icon + text(CommandBarChanges.title(changes, labels: false)))
        }
        // The find group (scope menu + search at its minimum width + chips) sits on the trailing side.
        let find =
            capsule + icon + text(scopeTitle) + 140 + 2 * capsule + icon + Space.s3
            + CGFloat(chips.count) * 160
        let available = max(barWidth - 2 * Space.s5 - Space.s4 - find, 0)
        return CommandBarLayout.make(
            available: available, groups: groups, widths: widths, spacing: Space.s4,
            overflowButton: capsule + IconSize.md, labelsAllowed: controller.model.preferences.commandBarShowsLabels)
    }

    private var isDeepRunning: Bool {
        if case .running = model.deepSearch { return true }
        return false
    }

    // MARK: Scope

    private var scopeMenu: some View {
        Menu {
            ForEach(GraphViewModel.ScopeChoice.allCases, id: \.self) { choice in
                Button {
                    if choice == .selected {
                        showsBranchPicker = true
                    } else {
                        model.scope = choice
                        controller.applyQuery()
                    }
                } label: {
                    if model.scope == choice {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            Label(scopeTitle, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
                .typeStyle(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Which branches the graph shows")
        .popover(isPresented: $showsBranchPicker, arrowEdge: .bottom) {
            BranchPicker(controller: controller, isPresented: $showsBranchPicker)
        }
    }

    private var scopeTitle: String {
        switch model.scope {
        case .all: "All Branches"
        case .current: "Current Branch"
        case .local: "Local Branches"
        case .selected: model.selectedRefs.count == 1 ? "1 Branch" : "\(model.selectedRefs.count) Branches"
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search  (text, sha:, author:, ref:)", text: Bindable(model).searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .frame(minWidth: 140, idealWidth: 220, maxWidth: 280)
                .onChange(of: model.searchText) { controller.searchTextChanged() }
                .onSubmit { controller.nextMatch(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) {
                    controller.clearModes()
                    return .handled
                }
                .accessibilityLabel("Search commits")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    controller.searchTextChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .jitGlass(in: Capsule())
    }

    private var matchControls: some View {
        HStack(spacing: Space.s2) {
            Text(counterText)
                .typeStyle(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(counterText)
            Button {
                controller.nextMatch(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous match (⇧⌘G)")
            .disabled(model.matches.isEmpty)
            Button {
                controller.nextMatch(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next match (⌘G)")
            .disabled(model.matches.isEmpty)
            Menu {
                Picker("Show", selection: filterBinding) {
                    Text("Highlight Matches").tag(GraphViewModel.FilterMode.highlight)
                    Text("Show Only Matches").tag(GraphViewModel.FilterMode.onlyMatches)
                }
                .pickerStyle(.inline)
                Divider()
                deepSearchItems
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuIndicator(.hidden)
            .help("Filter and search options")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .jitGlass(in: Capsule())
    }

    @ViewBuilder private var deepSearchItems: some View {
        switch model.deepSearch {
        case .idle:
            Button("Search All History") { controller.searchAllHistory() }
                .disabled(!canSearchDeep)
        case .running(let found):
            Button("Stop Searching (\(found) found)") { controller.cancelDeepSearch() }
        case .finished(let found, let limited):
            if !model.deepMatches.isEmpty {
                Button("Show First Match in Unloaded History") { controller.revealFirstDeepMatch() }
            }
            Text(limited ? "First \(found) matches in all history" : "\(found) matches in all history")
        case .failed(let message):
            Text(message)
        }
    }

    private var canSearchDeep: Bool {
        let query = HistorySearchQuery(model.searchText)
        return !query.text.isEmpty || !query.authors.isEmpty
    }

    private var filterBinding: Binding<GraphViewModel.FilterMode> {
        Binding(get: { model.filterMode }, set: { controller.setFilterMode($0) })
    }

    private var counterText: String {
        guard !model.matches.isEmpty else { return "No matches" }
        let current = (model.currentMatch ?? 0) + 1
        return "\(current) of \(model.matches.count)"
    }

    // MARK: Chips

    struct Chip {
        let id: String
        let title: String
        let tooltip: String?
        let remove: () -> Void
    }

    private var chips: [Chip] {
        var result: [Chip] = []
        if let solo = model.solo {
            result.append(
                Chip(id: "solo", title: "Solo: \(Self.shortName(solo))", tooltip: nil) {
                    model.solo = nil
                    controller.applyQuery()
                })
        }
        if let history = model.fileHistory {
            result.append(
                Chip(
                    id: "history", title: "History: \(history.path)",
                    tooltip: history.follow ? "Rename tracking is heuristic (git log --follow)." : nil
                ) {
                    model.fileHistory = nil
                    controller.applyQuery()
                })
        }
        return result
    }

    static func shortName(_ fullName: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }
}

private struct ChipView: View {
    let chip: GraphBar.Chip

    var body: some View {
        HStack(spacing: Space.s3) {
            Text(chip.title)
                .typeStyle(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260)
            Button(action: chip.remove) {
                Image(systemName: "xmark")
                    .symbolSize(IconSize.sm, weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit \(chip.title)")
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .jitGlass(in: Capsule())
        .help(chip.tooltip ?? chip.title)
    }
}

/// "Selected Branches…" checklist with a filter field.
private struct BranchPicker: View {
    let controller: GraphViewController
    @Binding var isPresented: Bool
    @State private var filter = ""
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(candidates, id: \.fullName) { ref in
                Toggle(
                    isOn: Binding(
                        get: { chosen.contains(ref.fullName) },
                        set: { on in
                            if on { chosen.insert(ref.fullName) } else { chosen.remove(ref.fullName) }
                        })
                ) {
                    Text(ref.shortName).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(width: 300, height: 280)
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Show") {
                    controller.viewModel.selectedRefs = chosen.sorted()
                    controller.viewModel.scope = chosen.isEmpty ? .all : .selected
                    controller.applyQuery()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s6)
        .onAppear { chosen = Set(controller.viewModel.selectedRefs) }
    }

    private var candidates: [GitRef] {
        let refs = (controller.currentRefs?.refs ?? []).filter { $0.kind == .local || $0.kind == .remote }
        guard !filter.isEmpty else { return refs }
        return refs.filter { FuzzyMatch.matches(filter, $0.shortName) }
    }
}

/// Loading skeleton, empty state and error banner over the table (design §3.2 States).
struct GraphStateOverlay: View {
    let controller: GraphViewController

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.viewModel.historyError {
                ErrorBanner(error: error, retry: controller.retry)
                    .padding(.top, 52)
                    .padding(.horizontal, Space.s6)
            }
            if controller.viewModel.paneState == .loading {
                SkeletonRows()
                    .padding(.top, 52)
                    .allowsHitTesting(false)
            } else if controller.viewModel.paneState == .empty {
                Spacer()
                VStack(spacing: Space.s3) {
                    Text("No commits yet")
                        .typeStyle(.title)
                        .foregroundStyle(.token(.textSecondary))
                }
                .accessibilityElement(children: .combine)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(controller.viewModel.historyError != nil)
    }
}

private struct ErrorBanner: View {
    let error: GitCoreError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.token(.statusDanger))
                .accessibilityHidden(true)
            Text("History could not be read: \(error.summary)")
                .typeStyle(.callout)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
        }
        .padding(Space.s5)
        .background(ColorToken.surfaceRaised.color, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline))
    }
}

/// 12 static placeholder rows — no shimmer (no perpetual animation, §3.4).
private struct SkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<12, id: \.self) { index in
                HStack(spacing: Space.s6) {
                    Circle()
                        .fill(ColorToken.borderSubtle.color)
                        .frame(width: 8, height: 8)
                        .padding(.leading, Space.s6)
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(ColorToken.borderSubtle.color)
                        .frame(width: CGFloat(180 + (index * 53) % 220), height: 8)
                    Spacer()
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(ColorToken.borderSubtle.color.opacity(0.7))
                        .frame(width: 90, height: 8)
                        .padding(.trailing, Space.s6)
                }
                .frame(height: 30)
            }
        }
        .accessibilityLabel("Loading history")
    }
}

/// Fuzzy subsequence match (navigator filter, branch picker): every query character appears in order,
/// case-insensitively.
enum FuzzyMatch {
    static func matches(_ query: String, _ candidate: String) -> Bool {
        var remaining = query.lowercased()[...]
        guard !remaining.isEmpty else { return true }
        for character in candidate.lowercased() where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }
}
