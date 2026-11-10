import DesignSystem
import GitCore
import Services
import SwiftUI

/// The repository action bar: the everyday commands in the middle (`CommandBarActions`: Fetch, Branch, Pull,
/// Push, Stash, Pop, Terminal), then Search; transient chips at the trailing end. Since 0.0.4 it
/// has no glass and no container: plain tools with their names on an opaque strip. Rows scroll underneath.
/// The current branch and the profile moved to the sidebar; the branch scope menu is gone.
struct GraphBar: View {
    let controller: GraphViewController
    @FocusState private var searchFocused: Bool
    /// The search field is a magnifier button until it is used: the bar stays short enough to fit beside an
    /// open inspector.
    @State private var searchExpanded = false
    @State private var barWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: GraphViewModel { controller.viewModel }

    var body: some View {
        let layout = commandLayout()
        VStack(spacing: Space.s3) {
            // The tools sit in the middle; chips and the open search field keep the trailing end.
            ZStack {
                // One centred row: the commands, then Search (the working directory is the graph's WIP row).
                HStack(spacing: Space.s2) {
                    CommandBarActions(controller: controller, layout: layout)
                    if !showsSearchField {
                        BarAction(title: "Search", symbol: "magnifyingglass", help: "Search Commits (⌘F)") {
                            expandSearch()
                        }
                        .environment(\.barShowsTitles, layout.showsLabels)
                    }
                }
                .fixedSize()
                // Transient things keep the trailing end: progress, chips, the open search field.
                HStack(spacing: Space.s2) {
                    Spacer(minLength: 0)
                    if controller.isSlow || isDeepRunning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(isDeepRunning ? "Searching all history" : "Loading history")
                    }
                    ForEach(chips, id: \.id) { chip in
                        ChipView(chip: chip)
                            .transition(RevealTransition.transition(reduceMotion: reduceMotion))
                    }
                    if showsSearchField {
                        searchField
                        if model.isSearching { matchControls }
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(maxWidth: .infinity)
            if let operations = controller.operations {
                OperationBanner(controller: operations)
            }
        }
        .animation(reduceMotion ? nil : MotionToken.panel.animation, value: controller.session.operationState == .clean)
        .padding(.vertical, Space.s2)
        // No glass and no container (0.0.4): an opaque strip of the canvas, so rows scrolling underneath do not
        // show through the tools.
        .background(ColorToken.surfaceCanvas.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ColorToken.borderSubtle.color).frame(height: Border.hairline)
        }
        .animation(reduceMotion ? nil : MotionToken.glassMorph.animation, value: chips.map(\.id))
        .animation(reduceMotion ? nil : MotionToken.glassMorph.animation, value: showsSearchField)
        .onChange(of: model.focusSearchToken) { expandSearch() }
        .onChange(of: searchFocused) { _, focused in
            // Leaving an empty field folds it back into the button.
            if !focused, model.searchText.isEmpty { searchExpanded = false }
        }
        // A flexible frame reports the width the pane offers, even while a child would overflow; measuring the
        // content itself would report the overflowing width and nothing would ever move into `⋯`.
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            barWidth = $0
        }
    }

    // MARK: Layout

    /// Titles drop first, then groups move into `⋯` (`CommandBarLayout`). Widths are measured from the titles
    /// with the bar's font; the trailing side keeps what it needs.
    private func commandLayout() -> CommandBarLayout {
        let groups: [CommandBarGroup] = [.branch, .sync, .stash, .terminal]
        func item(_ title: String) -> CommandBarLayout.GroupWidth {
            .init(labelled: BarMetrics.itemWidth(title), iconOnly: BarMetrics.itemWidth(nil))
        }
        func sum(_ titles: [String]) -> CommandBarLayout.GroupWidth {
            let widths = titles.map(item)
            let gaps = Space.s1 * CGFloat(titles.count - 1)
            return .init(
                labelled: widths.reduce(gaps) { $0 + $1.labelled }, iconOnly: widths.reduce(gaps) { $0 + $1.iconOnly })
        }
        let widths: [CommandBarGroup: CommandBarLayout.GroupWidth] = [
            .sync: sum(["Pull ↓99", "Publish", "Fetch"]), .branch: item("Branch"), .stash: sum(["Stash", "Pop"]),
            .terminal: item("Terminal"),
        ]
        // In the centred row with the commands: the Search item.
        let extras = showsSearchField ? 0 : BarMetrics.itemWidth("Search") + Space.s2
        // At the trailing end; the centred row must stay clear of it, so it counts on both sides.
        var trailing: CGFloat = showsSearchField ? 140 + 3 * Space.s5 + IconSize.md : 0
        if model.isSearching { trailing += 150 }
        trailing += CGFloat(chips.count) * 160
        let available = max(barWidth - 2 * Space.s4 - extras - 2 * trailing, 0)
        return CommandBarLayout.make(
            available: available, groups: groups, widths: widths, spacing: Space.s1,
            overflowButton: BarMetrics.itemWidth(nil), labelsAllowed: controller.model.preferences.commandBarShowsLabels
        )
    }

    private var isDeepRunning: Bool {
        if case .running = model.deepSearch { return true }
        return false
    }

    // MARK: Search

    private var showsSearchField: Bool { searchExpanded || !model.searchText.isEmpty }

    private func expandSearch() {
        searchExpanded = true
        // The field exists after this update; focus it then.
        Task { @MainActor in searchFocused = true }
    }

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
                    if model.searchText.isEmpty {
                        searchExpanded = false
                        searchFocused = false
                    } else {
                        controller.clearModes()
                    }
                    return .handled
                }
                .accessibilityLabel("Search commits")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    controller.searchTextChanged()
                    if !searchFocused { searchExpanded = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(ColorToken.stateHover.color, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
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
        .padding(.horizontal, Space.s3)
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
                .frame(maxWidth: 200)
            Button(action: chip.remove) {
                Image(systemName: "xmark")
                    .symbolSize(IconSize.sm, weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit \(chip.title)")
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(ColorToken.stateHover.color, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .help(chip.tooltip ?? chip.title)
    }
}

/// Loading skeleton, empty state and error banner over the table (design §3.2 States).
struct GraphStateOverlay: View {
    let controller: GraphViewController

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.viewModel.historyError {
                ErrorBanner(error: error, retry: controller.retry)
                    .padding(.top, 56)
                    .padding(.horizontal, Space.s6)
            }
            if controller.viewModel.paneState == .loading {
                SkeletonRows()
                    .padding(.top, 56)
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
