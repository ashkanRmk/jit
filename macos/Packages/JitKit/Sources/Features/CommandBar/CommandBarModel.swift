import CoreGraphics
import GitCore

/// The groups of the repository command bar (P3.0 spec). Declared in display order.
enum CommandBarGroup: String, CaseIterable, Sendable {
    case location, changes, sync, branch, stash, history, terminal, find

    /// Groups that exist in this build. An action appears only when the phase that implements it ships
    /// ("Unbuilt = absent"): sync/branch/stash arrive in Phase 4, undo/redo in Phase 8.
    static let shipped: [CommandBarGroup] = [.location, .changes, .terminal, .find]

    /// The order in which groups move into the trailing `⋯` menu when the bar is too narrow. Location,
    /// changes, sync and find never overflow.
    static let overflowOrder: [CommandBarGroup] = [.terminal, .history, .stash, .branch]

    var canOverflow: Bool { Self.overflowOrder.contains(self) }
}

/// Which groups show, whether they carry labels, and what moved into the overflow menu.
struct CommandBarLayout: Equatable, Sendable {
    var showsLabels: Bool
    var visible: [CommandBarGroup]
    var overflow: [CommandBarGroup]

    /// Widths of one group with and without its text label.
    struct GroupWidth: Sendable {
        var labelled: CGFloat
        var iconOnly: CGFloat
    }

    /// Labels drop first; then whole groups move into the overflow menu in `CommandBarGroup.overflowOrder`.
    /// - Parameters:
    ///   - available: the bar's width.
    ///   - groups: the groups present right now, in display order (e.g. `changes` is absent when clean).
    ///   - widths: measured widths per group; a missing entry counts as zero.
    ///   - spacing: gap between groups.
    ///   - overflowButton: width the `⋯` menu adds once anything overflows.
    ///   - labelsAllowed: View ▸ Command Bar ▸ Show Labels.
    static func make(
        available: CGFloat,
        groups: [CommandBarGroup],
        widths: [CommandBarGroup: GroupWidth],
        spacing: CGFloat,
        overflowButton: CGFloat,
        labelsAllowed: Bool
    ) -> CommandBarLayout {
        func total(_ shown: [CommandBarGroup], labels: Bool, overflowing: Bool) -> CGFloat {
            var sum = shown.reduce(CGFloat(0)) { partial, group in
                let width = widths[group] ?? GroupWidth(labelled: 0, iconOnly: 0)
                return partial + (labels ? width.labelled : width.iconOnly)
            }
            let count = shown.count + (overflowing ? 1 : 0)
            sum += spacing * CGFloat(max(count - 1, 0))
            if overflowing { sum += overflowButton }
            return sum
        }

        if labelsAllowed, total(groups, labels: true, overflowing: false) <= available {
            return CommandBarLayout(showsLabels: true, visible: groups, overflow: [])
        }
        var visible = groups
        var overflow: [CommandBarGroup] = []
        for candidate in CommandBarGroup.overflowOrder {
            if total(visible, labels: false, overflowing: !overflow.isEmpty) <= available { break }
            guard let index = visible.firstIndex(of: candidate) else { continue }
            visible.remove(at: index)
            overflow.append(candidate)
        }
        return CommandBarLayout(showsLabels: false, visible: visible, overflow: overflow)
    }
}

/// The breadcrumb's text: repository › branch, with ahead/behind (P3.0 spec, Location group).
struct CommandBarLocation: Equatable, Sendable {
    var repository: String
    /// `main`, `HEAD 1a2b3c4` (detached) or `main — no commits` (unborn).
    var branchTitle: String
    /// `↑1 ↓0` when the branch has an upstream; `nil` otherwise.
    var tracking: String?
    var accessibilityLabel: String

    init(repository: String, branch: BranchHeader) {
        self.repository = repository
        var spoken = "Repository \(repository)"
        switch (branch.head, branch.oid) {
        case let (name?, nil):
            branchTitle = "\(name) — no commits"
            spoken += ", branch \(name), no commits yet"
        case let (nil, oid):
            let short = String((oid ?? "").prefix(7))
            branchTitle = short.isEmpty ? "HEAD" : "HEAD \(short)"
            spoken += short.isEmpty ? ", detached HEAD" : ", detached HEAD at \(short)"
        case let (name?, _):
            branchTitle = name
            spoken += ", branch \(name)"
        }
        if branch.head != nil, branch.oid != nil, let ahead = branch.ahead, let behind = branch.behind {
            tracking = "↑\(ahead) ↓\(behind)"
            if ahead > 0 { spoken += ", \(ahead) \(ahead == 1 ? "commit" : "commits") ahead" }
            if behind > 0 { spoken += ", \(behind) \(behind == 1 ? "commit" : "commits") behind" }
            if ahead == 0, behind == 0 { spoken += ", up to date with \(branch.upstream ?? "upstream")" }
        } else {
            tracking = nil
        }
        accessibilityLabel = spoken
    }
}

/// The `◌ 23 changes` item: hidden when the working tree is clean.
enum CommandBarChanges {
    /// Changed paths (a partially staged file counts once); `nil` hides the item.
    static func count(_ summary: StatusSummary?) -> Int? {
        guard let summary, !summary.isClean else { return nil }
        return summary.changedFiles
    }

    static func title(_ count: Int, labels: Bool) -> String {
        labels ? "\(count) \(count == 1 ? "change" : "changes")" : "\(count)"
    }
}
