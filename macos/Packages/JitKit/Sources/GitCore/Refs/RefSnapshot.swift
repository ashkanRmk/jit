import Foundation

/// Where HEAD points.
public enum HeadState: Sendable, Equatable {
    /// `name` is the short branch name (`main`, `feature/x`).
    case branch(name: String, commit: ObjectID)
    case detached(commit: ObjectID)
    case unborn(branch: String)

    public var commit: ObjectID? {
        switch self {
        case .branch(_, let commit), .detached(let commit): commit
        case .unborn: nil
        }
    }

    public var branchName: String? {
        switch self {
        case .branch(let name, _), .unborn(let name): name
        case .detached: nil
        }
    }
}

/// One ref from `git for-each-ref` (design §4.1). Names are kept as `String`s: refs are few compared to
/// commits (10k branches ≈ 1 MB), and the navigator needs them as text anyway.
public struct GitRef: Sendable, Hashable {
    public enum Kind: UInt8, Sendable, Hashable, Comparable {
        case local, remote, tag, other

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Full name, e.g. `refs/heads/main`, `refs/remotes/origin/main`, `refs/tags/v1`.
    public let fullName: String
    public let kind: Kind
    /// The object the ref names directly (the tag object for annotated tags).
    public let object: ObjectID
    /// The commit the ref resolves to (peeled through annotated tags); `nil` for refs to trees/blobs.
    public let commit: ObjectID?
    public let isAnnotatedTag: Bool
    /// Short upstream name (`origin/main`) for local branches with a configured upstream.
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// The configured upstream no longer exists (`[gone]`).
    public let upstreamGone: Bool
    /// The branch HEAD points at.
    public let isHead: Bool

    public init(
        fullName: String, kind: Kind, object: ObjectID, commit: ObjectID?, isAnnotatedTag: Bool = false,
        upstream: String? = nil, ahead: Int = 0, behind: Int = 0, upstreamGone: Bool = false, isHead: Bool = false
    ) {
        self.fullName = fullName
        self.kind = kind
        self.object = object
        self.commit = commit
        self.isAnnotatedTag = isAnnotatedTag
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isHead = isHead
    }

    /// Name without the namespace: `main`, `origin/main`, `v1.0`.
    public var shortName: String {
        let prefix: String
        switch kind {
        case .local: prefix = "refs/heads/"
        case .remote: prefix = "refs/remotes/"
        case .tag: prefix = "refs/tags/"
        case .other: prefix = "refs/"
        }
        return fullName.hasPrefix(prefix) ? String(fullName.dropFirst(prefix.count)) : fullName
    }

    /// For remote refs, the remote's name (`origin` of `origin/feature/x`).
    public var remoteName: String? {
        guard kind == .remote else { return nil }
        return shortName.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// For remote refs, the branch part (`feature/x` of `origin/feature/x`).
    public var remoteBranchName: String? {
        guard kind == .remote else { return nil }
        let parts = shortName.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}

/// All refs of a repository at one moment, plus HEAD. Immutable; `revision` changes whenever anything
/// visible changes (ADR-0024 compares it to decide what to refresh).
public struct RefSnapshot: Sendable, Equatable {
    public let head: HeadState
    /// Local, remote, tag and other refs in Git's refname order. Symbolic refs (`origin/HEAD`) excluded.
    public let refs: [GitRef]
    /// Symbolic remote HEADs: `origin` → `refs/remotes/origin/main`.
    public let remoteHeads: [String: String]
    public let format: ObjectFormat
    /// FNV-1a over Git's raw output and HEAD — equal revisions mean identical refs.
    public let revision: UInt64

    public init(head: HeadState, refs: [GitRef], remoteHeads: [String: String] = [:], format: ObjectFormat, revision: UInt64) {
        self.head = head
        self.refs = refs
        self.remoteHeads = remoteHeads
        self.format = format
        self.revision = revision
    }

    public static let empty = RefSnapshot(head: .unborn(branch: "main"), refs: [], format: .sha1, revision: 0)

    public var locals: [GitRef] { refs.filter { $0.kind == .local } }
    public var remotes: [GitRef] { refs.filter { $0.kind == .remote } }
    public var tags: [GitRef] { refs.filter { $0.kind == .tag } }

    /// Refs grouped by the commit they resolve to (labels in the graph).
    public func refsByCommit() -> [ObjectID: [Int]] {
        var result: [ObjectID: [Int]] = [:]
        for (index, ref) in refs.enumerated() {
            if let commit = ref.commit { result[commit, default: []].append(index) }
        }
        return result
    }

    public func ref(named fullName: String) -> GitRef? { refs.first { $0.fullName == fullName } }
}
