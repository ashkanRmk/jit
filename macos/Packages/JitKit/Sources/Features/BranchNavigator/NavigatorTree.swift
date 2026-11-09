import Foundation
import GitCore

/// One navigator row: a section, a folder (`/` hierarchy) or a ref. Reference type because
/// `NSOutlineView` identifies items by object; there is one per ref or folder (refs are few, not commits).
final class NavigatorNode {
    enum Kind: Equatable {
        case section(Section)
        /// A remote's group inside the Remote section.
        case remote(String)
        case folder
        case ref(GitRef)
        /// "No tags", "main — no commits".
        case note(String)
        /// A `stash@{n}` entry (P4.16).
        case stash(StashEntry)
    }

    enum Section: String, CaseIterable {
        case local = "Local"
        case remote = "Remote"
        case tags = "Tags"
        case stashes = "Stashes"
    }

    let kind: Kind
    /// Last path component(s) shown (`tabs`, or `feature/ui` for a collapsed folder chain).
    let title: String
    /// Stable identity for expand state: `section/Local/feature/ui`.
    let id: String
    var children: [NavigatorNode]

    init(kind: Kind, title: String, id: String, children: [NavigatorNode] = []) {
        self.kind = kind
        self.title = title
        self.id = id
        self.children = children
    }

    var ref: GitRef? {
        if case .ref(let ref) = kind { return ref }
        return nil
    }

    var stash: StashEntry? {
        if case .stash(let entry) = kind { return entry }
        return nil
    }

    var isExpandable: Bool { !children.isEmpty }

    /// Number of refs below (section headers show it).
    var refCount: Int {
        if ref != nil || stash != nil { return 1 }
        return children.reduce(0) { $0 + $1.refCount }
    }

    /// Ids of every folder/section on the path to refs matching `predicate` (auto-expansion).
    func expandableIDs(containing predicate: (GitRef) -> Bool) -> Set<String> {
        var result = Set<String>()
        func visit(_ node: NavigatorNode) -> Bool {
            if let ref = node.ref { return predicate(ref) }
            var any = false
            for child in node.children where visit(child) { any = true }
            if any { result.insert(node.id) }
            return any
        }
        _ = visit(self)
        return result
    }
}

/// Builds the navigator tree from a `RefSnapshot` (design §3.5). Pure and testable.
enum NavigatorTreeBuilder {
    /// - Parameter filter: fuzzy subsequence over short names; empty keeps everything.
    /// - Parameter stashes: shown as a "Stashes" section once loaded (`nil` hides it).
    static func build(_ refs: RefSnapshot, filter: String = "", stashes: [StashEntry]? = nil) -> [NavigatorNode] {
        let keep: (GitRef) -> Bool = { filter.isEmpty || FuzzyMatch.matches(filter, $0.shortName) }
        var sections: [NavigatorNode] = []

        let locals = refs.refs.filter { $0.kind == .local && keep($0) }
        var localChildren = tree(locals, prefix: "section/Local", name: { $0.shortName }, current: refs.head.branchName)
        if case .unborn(let branch) = refs.head, filter.isEmpty {
            localChildren.insert(
                NavigatorNode(kind: .note("\(branch) — no commits"), title: branch, id: "note/unborn"), at: 0)
        }
        if !localChildren.isEmpty || filter.isEmpty {
            sections.append(
                NavigatorNode(kind: .section(.local), title: "Local", id: "section/Local", children: localChildren))
        }

        let remotes = refs.refs.filter { $0.kind == .remote && keep($0) }
        if !remotes.isEmpty {
            let grouped = Dictionary(grouping: remotes) { $0.remoteName ?? "" }
            let remoteNodes = grouped.keys.sorted(by: natural).map { remote in
                let id = "section/Remote/\(remote)"
                return NavigatorNode(
                    kind: .remote(remote), title: remote, id: id,
                    children: tree(
                        grouped[remote] ?? [], prefix: id, name: { $0.remoteBranchName ?? $0.shortName }, current: nil))
            }
            sections.append(
                NavigatorNode(kind: .section(.remote), title: "Remote", id: "section/Remote", children: remoteNodes))
        }

        let tags = refs.refs.filter { $0.kind == .tag && keep($0) }
        if !tags.isEmpty || filter.isEmpty {
            var tagChildren = tree(tags, prefix: "section/Tags", name: { $0.shortName }, current: nil)
            if tagChildren.isEmpty {
                tagChildren = [NavigatorNode(kind: .note("No tags"), title: "No tags", id: "note/notags")]
            }
            sections.append(
                NavigatorNode(kind: .section(.tags), title: "Tags", id: "section/Tags", children: tagChildren))
        }

        if let stashes {
            let matching = stashes.filter { filter.isEmpty || FuzzyMatch.matches(filter, $0.message) }
            var children = matching.map {
                NavigatorNode(kind: .stash($0), title: $0.message, id: "stash/\($0.oid)")
            }
            if children.isEmpty, filter.isEmpty {
                children = [
                    NavigatorNode(
                        kind: .note("No stashes"), title: "",
                        id: "note/nostashes")
                ]
            }
            if !children.isEmpty {
                sections.append(
                    NavigatorNode(kind: .section(.stashes), title: "Stashes", id: "section/Stashes", children: children)
                )
            }
        }
        return sections
    }

    /// `/`-hierarchy with single-child folder chains collapsed (`feature/ui ▸ tabs`), natural order,
    /// the current branch first.
    static func tree(_ refs: [GitRef], prefix: String, name: (GitRef) -> String, current: String?) -> [NavigatorNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var leaves: [(String, GitRef)] = []
        }
        let root = Folder()
        for ref in refs {
            let parts = name(ref).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var folder = root
            for part in parts.dropLast() {
                if let existing = folder.folders[part] {
                    folder = existing
                } else {
                    let created = Folder()
                    folder.folders[part] = created
                    folder = created
                }
            }
            folder.leaves.append((parts.last ?? name(ref), ref))
        }
        func nodes(_ folder: Folder, path: String) -> [NavigatorNode] {
            var result: [NavigatorNode] = []
            for key in folder.folders.keys.sorted(by: natural) {
                guard var child = folder.folders[key] else { continue }
                var title = key
                // Collapse a chain of folders that each hold exactly one folder and nothing else.
                while child.leaves.isEmpty, child.folders.count == 1, let only = child.folders.first {
                    title += "/" + only.key
                    child = only.value
                }
                let id = path + "/" + title
                result.append(NavigatorNode(kind: .folder, title: title, id: id, children: nodes(child, path: id)))
            }
            for (leaf, ref) in folder.leaves {
                result.append(NavigatorNode(kind: .ref(ref), title: leaf, id: ref.fullName))
            }
            result.sort { lhs, rhs in
                let lhsCurrent = lhs.ref.map { $0.isHead && $0.kind == .local } ?? false
                let rhsCurrent = rhs.ref.map { $0.isHead && $0.kind == .local } ?? false
                if lhsCurrent != rhsCurrent { return lhsCurrent }
                return natural(lhs.title, rhs.title)
            }
            return result
        }
        _ = current
        return nodes(root, path: prefix)
    }

    /// Finder-like order: `feature-2` before `feature-10`, case-insensitive.
    static func natural(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
