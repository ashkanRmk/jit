import Foundation

/// What a refs change means for a loaded history view (ADR-0024).
public enum HistoryRefreshDecision: Sendable, Equatable {
    /// Nothing visible changed.
    case unchanged
    /// Only labels (and HEAD's marker) moved between commits that are already loaded: update labels in
    /// place, keep the loaded rows and their lanes.
    case labelsOnly
    /// New commits or commits that may have left the scope: load a new history in the background and swap.
    case reload
}

public enum HistoryInvalidation {
    /// Decides between an in-place label update and a reload.
    ///
    /// `labelsOnly` requires that (1) every ref in scope (and HEAD) now points at a loaded commit, and
    /// (2) every loaded branch tip that a ref used to point at is still pointed at — otherwise its commits
    /// may have become unreachable (branch deleted, force-moved), and only Git can tell.
    public static func decide(old: RefSnapshot, new: RefSnapshot, history: HistorySnapshot, query: HistoryQuery)
        -> HistoryRefreshDecision
    {
        if old.revision == new.revision { return .unchanged }
        // A path filter or a solo/pinned view depends on more than labels; history changes are rare there.
        let newCommits = commitsInScope(new, query: query)
        for commit in newCommits where history.row(for: commit) == nil {
            // A ref (or HEAD) points at a commit we have not loaded. If history is complete, it is new.
            if history.complete || !history.chunks.isEmpty { return .reload }
        }
        let stillPointed = Set(newCommits)
        for commit in commitsInScope(old, query: query) where !stillPointed.contains(commit) {
            guard let row = history.row(for: commit) else { continue }
            if history.row(row).flags.contains(.tip) { return .reload }
        }
        if !sameScopeShape(old, new, query: query) { return .reload }
        return .labelsOnly
    }

    static func commitsInScope(_ refs: RefSnapshot, query: HistoryQuery) -> [ObjectID] {
        var result: [ObjectID] = []
        if let head = refs.head.commit, !isSolo(query) { result.append(head) }
        for ref in refs.refs {
            guard let commit = ref.commit else { continue }
            switch query.scope {
            case .all:
                if ref.kind != .other { result.append(commit) }
            case .current:
                continue
            case .local:
                if ref.kind == .local { result.append(commit) }
            case .refs(let names):
                if names.contains(ref.fullName) { result.append(commit) }
            case .solo(let name):
                if ref.fullName == name { result.append(commit) }
            }
        }
        return result
    }

    private static func isSolo(_ query: HistoryQuery) -> Bool {
        if case .solo = query.scope { return true }
        return false
    }

    /// Pinned refs that appeared or disappeared change lane seeding: reload.
    private static func sameScopeShape(_ old: RefSnapshot, _ new: RefSnapshot, query: HistoryQuery) -> Bool {
        query.pinned.allSatisfy { (old.ref(named: $0)?.commit) == (new.ref(named: $0)?.commit) }
    }
}
