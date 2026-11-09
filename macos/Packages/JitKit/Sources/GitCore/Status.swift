import Foundation

/// `# branch.*` headers of `git status --porcelain=v2 --branch`.
public struct BranchHeader: Sendable, Equatable {
    /// Commit HEAD points at; `nil` on an unborn branch (`(initial)`).
    public var oid: String?
    /// Branch name; `nil` when HEAD is detached.
    public var head: String?
    public var upstream: String?
    /// Present only when the upstream exists (`# branch.ab +A -B`).
    public var ahead: Int?
    public var behind: Int?

    public init(oid: String? = nil, head: String? = nil, upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil)
    {
        self.oid = oid
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    public var isDetached: Bool { head == nil }
    public var isUnborn: Bool { oid == nil }

    /// The same information as `RepositoryInfo.Head`.
    public var repositoryHead: RepositoryInfo.Head {
        switch (head, oid) {
        case let (name?, oid?): .branch(name: name, commit: oid)
        case let (name?, nil): .unborn(branch: name)
        case let (nil, oid?): .detached(commit: oid)
        case (nil, nil): .detached(commit: "")
        }
    }
}

/// Counts shown in Phase 1. A partially staged file counts in both `staged` and `unstaged`.
public struct StatusSummary: Sendable, Equatable {
    public var staged = 0
    public var unstaged = 0
    public var untracked = 0
    public var conflicted = 0
    public var ignored = 0
    /// Changed paths: staged, unstaged, untracked and conflicted entries, each path counted once (a
    /// partially staged file is one path). Ignored files don't count.
    public var changedFiles = 0
    /// Files with both staged and unstaged changes.
    public var partiallyStaged = 0

    public init(
        staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0, ignored: Int = 0,
        changedFiles: Int? = nil, partiallyStaged: Int = 0
    ) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.ignored = ignored
        self.changedFiles = changedFiles ?? (staged + unstaged + untracked + conflicted - partiallyStaged)
        self.partiallyStaged = partiallyStaged
    }

    /// No staged, unstaged, untracked or conflicted entries (ignored files don't count).
    public var isClean: Bool { staged == 0 && unstaged == 0 && untracked == 0 && conflicted == 0 }
}

/// Compact storage of every status record (ADR-0005): Git's own output buffer plus parallel arrays of
/// small fixed fields. No object or `String` per entry; paths are materialized on demand.
public struct StatusEntries: Sendable {
    public enum Kind: UInt8, Sendable {
        case ordinary, renamedOrCopied, unmerged, untracked, ignored
    }

    /// The raw `-z` output; ranges below point into it.
    let bytes: [UInt8]
    let kinds: [Kind]
    /// `X` in the high byte, `Y` in the low byte (ASCII). `0` for untracked/ignored.
    let xy: [UInt16]
    /// Submodule field: bit 0 = is submodule, 1 = commit changed, 2 = tracked changes, 3 = untracked changes.
    let submodule: [UInt8]
    /// Space-separated metadata between `XY` and the path (modes, object names, score), unparsed.
    let metadata: [Range<Int32>]
    let paths: [Range<Int32>]
    /// Original path of renames/copies; empty range otherwise.
    let originalPaths: [Range<Int32>]

    static let empty = StatusEntries(
        bytes: [], kinds: [], xy: [], submodule: [], metadata: [], paths: [], originalPaths: [])

    public var count: Int { kinds.count }
    public func kind(at index: Int) -> Kind { kinds[index] }

    /// `(X, Y)` status letters, e.g. `("M", ".")`. `("?", "?")` / `("!", "!")` for untracked/ignored.
    public func statusCodes(at index: Int) -> (index: Character, worktree: Character) {
        switch kinds[index] {
        case .untracked: return ("?", "?")
        case .ignored: return ("!", "!")
        default:
            let value = xy[index]
            return (Character(Unicode.Scalar(UInt8(value >> 8))), Character(Unicode.Scalar(UInt8(value & 0xFF))))
        }
    }

    public func isSubmodule(at index: Int) -> Bool { submodule[index] & 1 != 0 }
    public func path(at index: Int) -> String { string(paths[index]) }

    public func originalPath(at index: Int) -> String? {
        let range = originalPaths[index]
        return range.isEmpty ? nil : string(range)
    }

    /// Raw metadata fields (`mH mI mW hH hI` for ordinary entries, plus `Xscore` for renames).
    public func metadataFields(at index: Int) -> [String] {
        string(metadata[index]).split(separator: " ").map(String.init)
    }

    private func string(_ range: Range<Int32>) -> String {
        String(decoding: bytes[Int(range.lowerBound)..<Int(range.upperBound)], as: UTF8.self)
    }

    /// The path as Git wrote it (bytes, not normalized); used to build argv without a lossy round trip.
    public func pathBytes(at index: Int) -> ArraySlice<UInt8> {
        bytes[Int(paths[index].lowerBound)..<Int(paths[index].upperBound)]
    }

    // MARK: Typed views (P3.1)

    /// Staged and unstaged changes in one file.
    public func isPartiallyStaged(at index: Int) -> Bool {
        guard kinds[index] == .ordinary || kinds[index] == .renamedOrCopied else { return false }
        let (x, y) = statusCodes(at: index)
        return x != "." && y != "."
    }

    /// `true` when the index (`X`) side has a change.
    public func hasStagedChange(at index: Int) -> Bool {
        guard kinds[index] == .ordinary || kinds[index] == .renamedOrCopied else { return false }
        return statusCodes(at: index).index != "."
    }

    /// `true` when the worktree (`Y`) side has a change, or the file is untracked.
    public func hasUnstagedChange(at index: Int) -> Bool {
        switch kinds[index] {
        case .untracked: return true
        case .ordinary, .renamedOrCopied: return statusCodes(at: index).worktree != "."
        case .unmerged, .ignored: return false
        }
    }

    /// File type changed (regular file ↔ symlink ↔ submodule) in the index or the worktree.
    public func isTypeChange(at index: Int) -> Bool {
        let (x, y) = statusCodes(at: index)
        return x == "T" || y == "T"
    }

    public enum RenameKind: Sendable, Equatable { case renamed, copied }

    /// For `2` records: renamed or copied, with Git's similarity score (0–100).
    public func rename(at index: Int) -> (kind: RenameKind, score: Int)? {
        guard kinds[index] == .renamedOrCopied, let field = metadataFields(at: index).last, let letter = field.first
        else { return nil }
        guard let score = Int(field.dropFirst()) else { return nil }
        return (letter == "C" ? .copied : .renamed, score)
    }

    /// Submodule sub-states from the `S<c><m><u>` field.
    public struct SubmoduleState: Sendable, Hashable {
        public var commitChanged: Bool
        public var hasTrackedChanges: Bool
        public var hasUntrackedChanges: Bool
    }

    public func submoduleState(at index: Int) -> SubmoduleState? {
        let flags = submodule[index]
        guard flags & 1 != 0 else { return nil }
        return SubmoduleState(
            commitChanged: flags & 2 != 0, hasTrackedChanges: flags & 4 != 0, hasUntrackedChanges: flags & 8 != 0)
    }

    /// The seven unmerged combinations Git reports (`git status` "Unmerged paths").
    public enum ConflictKind: String, Sendable, Equatable {
        case bothDeleted = "DD", addedByUs = "AU", deletedByThem = "UD", addedByThem = "UA"
        case deletedByUs = "DU", bothAdded = "AA", bothModified = "UU"

        public var title: String {
            switch self {
            case .bothDeleted: "Both deleted"
            case .addedByUs: "Added by us"
            case .deletedByThem: "Deleted by them"
            case .addedByThem: "Added by them"
            case .deletedByUs: "Deleted by us"
            case .bothAdded: "Both added"
            case .bothModified: "Both modified"
            }
        }
    }

    public func conflict(at index: Int) -> ConflictKind? {
        guard kinds[index] == .unmerged else { return nil }
        let (x, y) = statusCodes(at: index)
        return ConflictKind(rawValue: String([x, y]))
    }

    /// Octal file modes. Ordinary/renamed: HEAD, index, worktree. Unmerged: stage 1, 2, 3, worktree.
    public func modes(at index: Int) -> [UInt32] {
        let fields = metadataFields(at: index)
        let count: Int
        switch kinds[index] {
        case .ordinary, .renamedOrCopied: count = 3
        case .unmerged: count = 4
        case .untracked, .ignored: return []
        }
        return fields.prefix(count).compactMap { UInt32($0, radix: 8) }
    }
}

/// One complete status result.
public struct StatusSnapshot: Sendable {
    public let revision: UInt64
    public let branch: BranchHeader
    public let entries: StatusEntries
    public let summary: StatusSummary
}

/// Parses `git status --porcelain=v2 -z --branch` output at the byte level.
public enum StatusParser {
    public static func parse(_ bytes: [UInt8], revision: UInt64 = 0) throws(GitCoreError) -> StatusSnapshot {
        var parser = Parser(bytes: bytes)
        try parser.run()
        return StatusSnapshot(
            revision: revision,
            branch: parser.branch,
            entries: StatusEntries(
                bytes: bytes, kinds: parser.kinds, xy: parser.xy, submodule: parser.submodule,
                metadata: parser.metadata, paths: parser.paths, originalPaths: parser.originalPaths),
            summary: parser.summary)
    }

    static func malformed(_ what: String) -> GitCoreError {
        .internalError(summary: "Git returned status output Jit couldn't read (\(what)).")
    }

    private struct Parser {
        let bytes: [UInt8]
        var branch = BranchHeader()
        var summary = StatusSummary()
        var kinds: [StatusEntries.Kind] = []
        var xy: [UInt16] = []
        var submodule: [UInt8] = []
        var metadata: [Range<Int32>] = []
        var paths: [Range<Int32>] = []
        var originalPaths: [Range<Int32>] = []

        private static let space = UInt8(ascii: " ")
        private static let nul: UInt8 = 0

        mutating func run() throws(GitCoreError) {
            guard bytes.count < Int(Int32.max) else { throw StatusParser.malformed("output too large") }
            if bytes.isEmpty { return }
            guard bytes.last == Self.nul else { throw StatusParser.malformed("truncated record") }
            var start = 0
            let end = bytes.count
            while start < end {
                guard let recordEnd = nextNUL(from: start) else { throw StatusParser.malformed("truncated record") }
                switch bytes[start] {
                case UInt8(ascii: "#"): parseHeader(start, recordEnd)
                case UInt8(ascii: "1"): try parseChanged(start, recordEnd, fields: 8, kind: .ordinary)
                case UInt8(ascii: "2"):
                    try parseChanged(start, recordEnd, fields: 9, kind: .renamedOrCopied)
                    // The `-z` form carries the original path as the next NUL-terminated token.
                    let originalStart = recordEnd + 1
                    guard originalStart < end, let originalEnd = nextNUL(from: originalStart) else {
                        throw StatusParser.malformed("rename without original path")
                    }
                    originalPaths[originalPaths.count - 1] = Int32(originalStart)..<Int32(originalEnd)
                    start = originalEnd + 1
                    continue
                case UInt8(ascii: "u"): try parseChanged(start, recordEnd, fields: 10, kind: .unmerged)
                case UInt8(ascii: "?"): try parseSimple(start, recordEnd, kind: .untracked)
                case UInt8(ascii: "!"): try parseSimple(start, recordEnd, kind: .ignored)
                default: throw StatusParser.malformed("unknown record type")
                }
                start = recordEnd + 1
            }
        }

        private func nextNUL(from index: Int) -> Int? {
            bytes.withUnsafeBufferPointer { buffer -> Int? in
                guard let base = buffer.baseAddress, index < buffer.count else { return nil }
                guard let found = memchr(base + index, 0, buffer.count - index) else { return nil }
                return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
        }

        /// Index of the `n`-th space at or after `from` (exclusive of `end`), or nil.
        private func spaces(_ count: Int, from: Int, to end: Int) -> [Int]? {
            var found: [Int] = []
            found.reserveCapacity(count)
            var index = from
            while index < end, found.count < count {
                if bytes[index] == Self.space { found.append(index) }
                index += 1
            }
            return found.count == count ? found : nil
        }

        private mutating func parseHeader(_ start: Int, _ end: Int) {
            // "# branch.<key> <value>"; unknown headers are ignored (forward compatibility).
            guard let keySpace = spaces(2, from: start, to: end)?.last else { return }
            let key = string(start + 2, keySpace)
            let value = string(keySpace + 1, end)
            switch key {
            case "branch.oid": branch.oid = value == "(initial)" ? nil : value
            case "branch.head": branch.head = value == "(detached)" ? nil : value
            case "branch.upstream": branch.upstream = value
            case "branch.ab":
                let parts = value.split(separator: " ")
                if parts.count == 2, parts[0].first == "+", parts[1].first == "-" {
                    branch.ahead = Int(parts[0].dropFirst())
                    branch.behind = Int(parts[1].dropFirst())
                }
            default: break
            }
        }

        /// `1`/`2`/`u` records: `fields` space-separated fields precede the path (which may contain spaces).
        private mutating func parseChanged(
            _ start: Int, _ end: Int, fields: Int, kind: StatusEntries.Kind
        ) throws(GitCoreError) {
            guard let separators = spaces(fields, from: start, to: end), separators[0] == start + 1,
                separators[1] == start + 4
            else { throw StatusParser.malformed("short record") }
            let x = bytes[start + 2]
            let y = bytes[start + 3]
            let pathStart = separators[fields - 1] + 1
            guard pathStart < end else { throw StatusParser.malformed("empty path") }
            let sub = parseSubmodule(separators[1] + 1, separators[2])

            kinds.append(kind)
            xy.append(UInt16(x) << 8 | UInt16(y))
            submodule.append(sub)
            metadata.append(Int32(separators[2] + 1)..<Int32(separators[fields - 1]))
            paths.append(Int32(pathStart)..<Int32(end))
            originalPaths.append(0..<0)

            summary.changedFiles += 1
            if kind == .unmerged {
                summary.conflicted += 1
            } else {
                let dot = UInt8(ascii: ".")
                if x != dot { summary.staged += 1 }
                if y != dot { summary.unstaged += 1 }
                if x != dot, y != dot { summary.partiallyStaged += 1 }
            }
        }

        private mutating func parseSimple(_ start: Int, _ end: Int, kind: StatusEntries.Kind) throws(GitCoreError) {
            guard end - start > 2, bytes[start + 1] == Self.space else { throw StatusParser.malformed("short record") }
            kinds.append(kind)
            xy.append(0)
            submodule.append(0)
            metadata.append(0..<0)
            paths.append(Int32(start + 2)..<Int32(end))
            originalPaths.append(0..<0)
            if kind == .untracked {
                summary.untracked += 1
                summary.changedFiles += 1
            } else {
                summary.ignored += 1
            }
        }

        /// `N...` or `S<c><m><u>`.
        private func parseSubmodule(_ start: Int, _ end: Int) -> UInt8 {
            guard end - start == 4, bytes[start] == UInt8(ascii: "S") else { return 0 }
            var flags: UInt8 = 1
            if bytes[start + 1] == UInt8(ascii: "C") { flags |= 2 }
            if bytes[start + 2] == UInt8(ascii: "M") { flags |= 4 }
            if bytes[start + 3] == UInt8(ascii: "U") { flags |= 8 }
            return flags
        }

        private func string(_ start: Int, _ end: Int) -> String {
            String(decoding: bytes[start..<end], as: UTF8.self)
        }
    }
}

/// A multi-step operation left in progress in the repository.
public enum OperationState: Sendable, Hashable {
    case none
    case merging
    case rebasing(step: Int?, total: Int?)
    case cherryPicking
    case reverting
    case bisecting
    case applyingMailbox
}

/// Reads operation markers from a (per-worktree) git directory. File reads only — no Git process.
public enum OperationStateDetector {
    public static func detect(gitDirectory: String) -> OperationState {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: gitDirectory + "/" + name) }
        func number(_ name: String) -> Int? {
            guard let data = fileManager.contents(atPath: gitDirectory + "/" + name) else { return nil }
            return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if exists("rebase-merge") {
            return .rebasing(step: number("rebase-merge/msgnum"), total: number("rebase-merge/end"))
        }
        if exists("rebase-apply") {
            if exists("rebase-apply/applying") { return .applyingMailbox }
            return .rebasing(step: number("rebase-apply/next"), total: number("rebase-apply/last"))
        }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_LOG") { return .bisecting }
        return .none
    }
}

/// What changed on disk, as classified from file-system events (ADR-0008).
public enum InvalidationKind: Sendable, Hashable, CaseIterable {
    case worktree, index, refs, head, config, operationState
}
