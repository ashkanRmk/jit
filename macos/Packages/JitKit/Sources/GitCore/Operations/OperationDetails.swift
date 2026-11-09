import Foundation

/// A commit as the banner and resolver labels show it: short SHA and subject.
public struct CommitSummary: Sendable, Hashable {
    public let oid: String
    public let subject: String

    public init(oid: String, subject: String) {
        self.oid = oid
        self.subject = subject
    }

    public var shortOID: String { String(oid.prefix(7)) }
}

/// The repository's in-progress operation with what the banner needs (design §4.9). Read from the
/// per-worktree git directory (works in linked worktrees, where `rev-parse --git-dir` already points at
/// `.git/worktrees/<name>`); file reads plus at most a couple of `git log` calls for subjects.
public enum RepoOperationState: Sendable, Equatable {
    case clean
    case merging(source: String, conflicted: Int)
    case rebasing(headName: String, onto: String, step: Int, total: Int, stoppedAt: CommitSummary?, conflicted: Int)
    case cherryPicking(commit: CommitSummary?, remaining: Int, conflicted: Int)
    case reverting(commit: CommitSummary?, remaining: Int, conflicted: Int)
    /// A multi-commit cherry-pick/revert between steps (`sequencer/` without `*_HEAD`).
    case sequencer(conflicted: Int)
    case applyingMailbox
    case bisecting

    public var conflicted: Int {
        switch self {
        case .merging(_, let count), .rebasing(_, _, _, _, _, let count), .cherryPicking(_, _, let count),
            .reverting(_, _, let count), .sequencer(let count):
            count
        case .clean, .applyingMailbox, .bisecting: 0
        }
    }

    /// Jit can continue/skip/abort this state (am and bisect are informational only).
    public var isDrivable: Bool {
        switch self {
        case .merging, .rebasing, .cherryPicking, .reverting, .sequencer: true
        case .clean, .applyingMailbox, .bisecting: false
        }
    }

    /// Skip applies to rebase, cherry-pick and revert steps (never to a merge).
    public var canSkip: Bool {
        switch self {
        case .rebasing, .cherryPicking, .reverting, .sequencer: true
        default: false
        }
    }
}

extension RepositoryHandle {
    /// The detailed operation state for the banner (read-only).
    public nonisolated func operationState() async throws(GitCoreError) -> RepoOperationState {
        let gitDirectory = info.gitDirectory
        let base = OperationStateDetector.detect(gitDirectory: gitDirectory)
        if case .none = base { return .clean }
        let conflicted = (try? await unmergedPaths().count) ?? 0
        func read(_ name: String) -> String? {
            guard let data = FileManager.default.contents(atPath: gitDirectory + "/" + name) else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func summary(_ oid: String?) async -> CommitSummary? {
            guard let oid, !oid.isEmpty, oid.allSatisfy(\.isHexDigit) else { return nil }
            let subject =
                (try? await runRead(["log", "-1", "--format=%s", "--end-of-options", oid], limit: 64 * 1024))
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) } ?? ""
            return CommitSummary(oid: oid, subject: subject)
        }
        func remainingTodo() -> Int {
            guard let todo = read("sequencer/todo") else { return 0 }
            return todo.split(whereSeparator: \.isNewline).filter {
                !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }.count
        }
        switch base {
        case .none:
            return .clean
        case .merging:
            return .merging(source: Self.mergeSource(message: read("MERGE_MSG")), conflicted: conflicted)
        case .rebasing:
            let directory =
                FileManager.default.fileExists(atPath: gitDirectory + "/rebase-merge") ? "rebase-merge" : "rebase-apply"
            let headName =
                read("\(directory)/head-name").map {
                    $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0
                } ?? "HEAD"
            let onto = read("\(directory)/onto") ?? ""
            let step = Int(read(directory == "rebase-merge" ? "rebase-merge/msgnum" : "rebase-apply/next") ?? "") ?? 0
            let total = Int(read(directory == "rebase-merge" ? "rebase-merge/end" : "rebase-apply/last") ?? "") ?? 0
            let stopped = read("rebase-merge/stopped-sha") ?? read("REBASE_HEAD")
            return .rebasing(
                headName: headName, onto: onto, step: step, total: total, stoppedAt: await summary(stopped),
                conflicted: conflicted)
        case .cherryPicking:
            return .cherryPicking(
                commit: await summary(read("CHERRY_PICK_HEAD")), remaining: remainingTodo(), conflicted: conflicted)
        case .reverting:
            return .reverting(
                commit: await summary(read("REVERT_HEAD")), remaining: remainingTodo(), conflicted: conflicted)
        case .bisecting:
            return .bisecting
        case .applyingMailbox:
            return .applyingMailbox
        }
    }

    /// "Merge branch 'feature/x' into main" → `feature/x`; falls back to the first line.
    static func mergeSource(message: String?) -> String {
        guard let first = message?.split(whereSeparator: \.isNewline).first.map(String.init) else { return "" }
        for prefix in ["Merge branch '", "Merge remote-tracking branch '", "Merge tag '", "Merge commit '"] {
            if first.hasPrefix(prefix), let end = first.dropFirst(prefix.count).firstIndex(of: "'") {
                return String(first[first.index(first.startIndex, offsetBy: prefix.count)..<end])
            }
        }
        return first
    }

    /// Paths with unmerged index entries (`ls-files -u -z`, deduplicated, in index order).
    public nonisolated func unmergedPaths() async throws(GitCoreError) -> [String] {
        let output = try await runRead(["ls-files", "-u", "-z"], limit: 64 * 1024 * 1024)
        var paths: [String] = []
        var seen = Set<String>()
        for record in output.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }
}
