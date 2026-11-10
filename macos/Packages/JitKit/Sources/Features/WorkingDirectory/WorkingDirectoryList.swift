import Foundation
import GitCore

/// The working-directory panel's sections (design §3.1).
enum WDSection: String, CaseIterable, Sendable, Hashable {
    case conflicts, staged, unstaged

    /// The order the panel shows them in (0.0.3): what is not staged yet comes before what is.
    static let displayOrder: [WDSection] = [.conflicts, .unstaged, .staged]

    var title: String {
        switch self {
        case .conflicts: "Conflicts"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        }
    }
}

/// How one file changed on one side (index or working tree).
enum WDChange: Sendable, Hashable {
    case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted

    /// The status glyph (design §3.1: A M D R C T U). Conflicts show `!` in their own section.
    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var spoken: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .typeChanged: "type changed"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        }
    }

    /// Status sort order.
    var rank: Int {
        switch self {
        case .conflicted: 0
        case .added: 1
        case .modified: 2
        case .renamed: 3
        case .copied: 4
        case .typeChanged: 5
        case .deleted: 6
        case .untracked: 7
        }
    }

    init?(code: Character) {
        switch code {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        default: return nil
        }
    }
}

/// A badge after the file name (design §3.1).
enum WDBadge: Sendable, Hashable {
    /// The executable bit was set (`+x`) or cleared (`−x`).
    case executable(Bool)
    case symlink
    case submodule
}

/// One file row in one section. A partially staged file has a row in Staged and one in Unstaged.
struct WDFile: Sendable, Hashable, Identifiable {
    let section: WDSection
    let path: String
    /// Source of a staged rename/copy.
    let originalPath: String?
    let change: WDChange
    let isPartial: Bool
    let badges: [WDBadge]
    let conflict: StatusEntries.ConflictKind?
    let submodule: StatusEntries.SubmoduleState?

    var id: String { Self.id(section, path) }
    static func id(_ section: WDSection, _ path: String) -> String { "\(section.rawValue):\(path)" }

    /// Untracked directories (`--untracked-files=normal`) end in `/`.
    var isDirectory: Bool { path.hasSuffix("/") }
    var name: String {
        let trimmed = isDirectory ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent + (isDirectory ? "/" : "")
    }
    var directory: String {
        let trimmed = isDirectory ? String(path.dropLast()) : path
        return (trimmed as NSString).deletingLastPathComponent
    }

    /// The paths a stage/unstage of this row passes: a staged rename needs both of its paths.
    var operationPaths: [String] {
        if section == .staged, change == .renamed, let originalPath { return [originalPath, path] }
        return [path]
    }

    var canStageOrUnstage: Bool { section != .conflicts }
}

/// Everything the panel lists for one status snapshot, before filtering and sorting.
struct WorkingDirectoryList: Sendable, Equatable {
    var conflicts: [WDFile] = []
    var staged: [WDFile] = []
    var unstaged: [WDFile] = []
    var revision: UInt64 = 0

    static let empty = WorkingDirectoryList()

    func files(_ section: WDSection) -> [WDFile] {
        switch section {
        case .conflicts: conflicts
        case .staged: staged
        case .unstaged: unstaged
        }
    }

    var isClean: Bool { conflicts.isEmpty && staged.isEmpty && unstaged.isEmpty }
    var totalRows: Int { conflicts.count + staged.count + unstaged.count }

    /// Builds the sections from Git's status (pure; runs off the main thread for large snapshots).
    init(snapshot: StatusSnapshot) {
        let entries = snapshot.entries
        revision = snapshot.revision
        for index in 0..<entries.count {
            switch entries.kind(at: index) {
            case .ignored:
                continue
            case .untracked:
                let path = entries.path(at: index)
                unstaged.append(
                    WDFile(
                        section: .unstaged, path: path, originalPath: nil, change: .untracked, isPartial: false,
                        badges: [], conflict: nil, submodule: nil))
            case .unmerged:
                conflicts.append(
                    WDFile(
                        section: .conflicts, path: entries.path(at: index), originalPath: nil, change: .conflicted,
                        isPartial: false, badges: [], conflict: entries.conflict(at: index), submodule: nil))
            case .ordinary, .renamedOrCopied:
                let path = entries.path(at: index)
                let (x, y) = entries.statusCodes(at: index)
                let partial = entries.isPartiallyStaged(at: index)
                let modes = entries.modes(at: index)
                let submodule = entries.submoduleState(at: index)
                if let change = WDChange(code: x) {
                    staged.append(
                        WDFile(
                            section: .staged, path: path, originalPath: entries.originalPath(at: index), change: change,
                            isPartial: partial,
                            badges: Self.badges(
                                old: modes.count > 1 ? modes[0] : 0, new: modes.count > 1 ? modes[1] : 0,
                                submodule: submodule != nil),
                            conflict: nil, submodule: submodule))
                }
                if let change = WDChange(code: y) {
                    unstaged.append(
                        WDFile(
                            section: .unstaged, path: path, originalPath: nil, change: change, isPartial: partial,
                            badges: Self.badges(
                                old: modes.count > 2 ? modes[1] : 0, new: modes.count > 2 ? modes[2] : 0,
                                submodule: submodule != nil),
                            conflict: nil, submodule: submodule))
                }
            }
        }
    }

    private init() {}

    static func badges(old: UInt32, new: UInt32, submodule: Bool) -> [WDBadge] {
        if submodule { return [.submodule] }
        var result: [WDBadge] = []
        if new & 0o170000 == 0o120000 { result.append(.symlink) }
        if old & 0o170000 == 0o100000, new & 0o170000 == 0o100000, old & 0o111 != new & 0o111 {
            result.append(.executable(new & 0o111 != 0))
        }
        return result
    }
}

// MARK: - Display (filter, sort, tree)

enum WDSort: String, CaseIterable, Sendable {
    case path, name, status, size

    var title: String {
        switch self {
        case .path: "Path"
        case .name: "Name"
        case .status: "Status"
        case .size: "Size of Change"
        }
    }
}

/// One line of a section as shown: a file, or (tree mode) a folder that groups files.
enum WDItem: Sendable, Hashable, Identifiable {
    case file(WDFile, depth: Int)
    case folder(WDFolder)

    var id: String {
        switch self {
        case .file(let file, _): file.id
        case .folder(let folder): folder.id
        }
    }
}

struct WDFolder: Sendable, Hashable, Identifiable {
    let section: WDSection
    /// Directory path without a trailing slash.
    let path: String
    let depth: Int
    /// Every file below this folder (all depths) — what a folder action stages/unstages.
    let files: [WDFile]
    let isExpanded: Bool

    var id: String { Self.id(section, path) }
    static func id(_ section: WDSection, _ path: String) -> String { "\(section.rawValue):dir:\(path)" }
    var name: String { (path as NSString).lastPathComponent }
}

enum WDDisplay {
    /// Filters (fuzzy, on the path), sorts and, in tree mode, groups a section's files.
    static func items(
        _ files: [WDFile], section: WDSection, filter: String, sort: WDSort, tree: Bool,
        collapsed: Set<String>, stats: [String: LineStats]
    ) -> [WDItem] {
        let matching = filter.isEmpty ? files : files.filter { FuzzyMatch.matches(filter, $0.path) }
        guard tree else { return sorted(matching, by: sort, stats: stats).map { .file($0, depth: 0) } }
        return treeItems(matching, section: section, sort: sort, collapsed: collapsed, stats: stats)
    }

    static func sorted(_ files: [WDFile], by sort: WDSort, stats: [String: LineStats]) -> [WDFile] {
        switch sort {
        case .path:
            return files.sorted { $0.path < $1.path }
        case .name:
            return files.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
        case .status:
            return files.sorted { ($0.change.rank, $0.path) < ($1.change.rank, $1.path) }
        case .size:
            // Largest first; files without counts yet (or untracked) after, by path.
            return files.sorted { a, b in
                let sa = stats[a.id]?.total ?? -1
                let sb = stats[b.id]?.total ?? -1
                return sa != sb ? sa > sb : a.path < b.path
            }
        }
    }

    /// Folders first (by name), then files (by the chosen sort), at every level.
    static func treeItems(
        _ files: [WDFile], section: WDSection, sort: WDSort, collapsed: Set<String>, stats: [String: LineStats]
    ) -> [WDItem] {
        final class Node {
            var folders: [String: Node] = [:]
            var files: [WDFile] = []
            var all: [WDFile] = []
        }
        let root = Node()
        for file in files {
            var node = root
            let components = file.directory.isEmpty ? [] : file.directory.split(separator: "/").map(String.init)
            for component in components {
                let next = node.folders[component] ?? Node()
                node.folders[component] = next
                next.all.append(file)
                node = next
            }
            node.files.append(file)
        }
        var result: [WDItem] = []
        func emit(_ node: Node, prefix: String, depth: Int) {
            for name in node.folders.keys.sorted() {
                guard let child = node.folders[name] else { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let id = WDFolder.id(section, path)
                let expanded = !collapsed.contains(id)
                result.append(
                    .folder(
                        WDFolder(section: section, path: path, depth: depth, files: child.all, isExpanded: expanded)))
                if expanded { emit(child, prefix: path, depth: depth + 1) }
            }
            for file in sorted(node.files, by: sort, stats: stats) { result.append(.file(file, depth: depth)) }
        }
        emit(root, prefix: "", depth: 0)
        return result
    }
}

/// The header's `3 staged · 5 unstaged · 1 untracked` line.
enum WDCounts {
    static func line(_ summary: StatusSummary?) -> String {
        guard let summary, !summary.isClean else { return "No changes" }
        var parts: [String] = []
        if summary.conflicted > 0 { parts.append("\(summary.conflicted) conflicted") }
        if summary.staged > 0 { parts.append("\(summary.staged) staged") }
        if summary.unstaged > 0 { parts.append("\(summary.unstaged) unstaged") }
        if summary.untracked > 0 { parts.append("\(summary.untracked) untracked") }
        return parts.joined(separator: " · ")
    }
}
