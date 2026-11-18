import Foundation

public enum RebaseAction: String, CaseIterable, Sendable, Hashable, Codable {
    case pick, reword, edit, squash, fixup, drop

    public var title: String { rawValue.capitalized }
    public var combinesWithPrevious: Bool { self == .squash || self == .fixup }
}

public struct RebaseStep: Sendable, Hashable, Codable, Identifiable {
    public let oid: String
    public var action: RebaseAction = .pick
    /// Reword: replacement message. Squash: complete combined message, not just an appended subject.
    public var message: String
    public var id: String { oid }
}

public struct RebaseCommit: Sendable, Hashable, Identifiable {
    public let oid: String
    public let subject: String
    public let message: String
    public let author: String
    public let diffstat: String
    public let paths: Set<String>
    public let published: Bool
    public var id: String { oid }
}

public struct RebaseResultCommit: Sendable, Equatable, Identifiable {
    public var sourceOIDs: [String]
    public var message: String
    public var stopsForEdit: Bool
    public var id: String { sourceOIDs[0] }
}

/// Immutable provenance plus editable steps. Only a repository read can create one.
public struct InteractiveRebasePlan: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let expected: RepoStateToken
    public let base: String
    public let onto: String
    public let commits: [RebaseCommit]
    public var steps: [RebaseStep]

    public var publishedCount: Int { commits.filter(\.published).count }
    public var resultCount: Int { resultCommits.count }
    public var resultCommits: [RebaseResultCommit] {
        var result: [RebaseResultCommit] = []
        for step in steps where step.action != .drop {
            if step.action.combinesWithPrevious, !result.isEmpty {
                result[result.count - 1].sourceOIDs.append(step.oid)
                if step.action == .squash { result[result.count - 1].message = step.message }
            } else {
                let message =
                    step.action == .reword ? step.message : commits.first { $0.oid == step.oid }?.message ?? ""
                result.append(
                    RebaseResultCommit(sourceOIDs: [step.oid], message: message, stopsForEdit: step.action == .edit))
            }
        }
        return result
    }
    /// Reordering edits to the same path is a risk hint, not a conflict prediction.
    public var reorderConflictPaths: [String] {
        let retained = Set(steps.filter { $0.action != .drop }.map(\.oid))
        let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.oid, $0) })
        var original: [String: [String]] = [:]
        var edited: [String: [String]] = [:]
        for commit in commits where retained.contains(commit.oid) {
            for path in commit.paths { original[path, default: []].append(commit.oid) }
        }
        for step in steps where retained.contains(step.oid) {
            for path in byID[step.oid]?.paths ?? [] { edited[path, default: []].append(step.oid) }
        }
        return original.keys.filter { original[$0] != edited[$0] }.sorted()
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if steps.isEmpty || steps.count != commits.count || Set(steps.map(\.oid)) != Set(commits.map(\.oid)) {
            issues.append("Every original commit must appear exactly once. Use Drop to remove a commit.")
        }
        let messageBytes =
            commits.reduce(0) { $0 + $1.message.utf8.count }
            + steps.filter { [.reword, .squash].contains($0.action) }.reduce(0) { $0 + $1.message.utf8.count }
        if messageBytes > 16 * 1024 * 1024 {
            issues.append("The plan's messages exceed 16 MB. Choose a smaller range.")
        }
        var hasPrevious = false
        for step in steps {
            if step.action == .drop { continue }
            if step.action.combinesWithPrevious && !hasPrevious {
                issues.append("The first retained commit cannot be Squash or Fixup.")
            }
            if [.reword, .squash].contains(step.action)
                && step.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                issues.append("Reword and Squash need a non-empty message.")
            }
            if step.message.utf8.contains(0) || step.message.utf8.count > 1024 * 1024 {
                issues.append("Commit messages must be at most 1 MB and cannot contain NUL bytes.")
            }
            hasPrevious = true
        }
        return Array(Set(issues)).sorted()
    }

    public func confirmation(context: String) -> ConfirmationRequest {
        let dropped = steps.filter { $0.action == .drop }.count
        return ConfirmationRequest(
            action: .interactiveRebase(planID: id, steps: steps),
            title: "Rewrite \(expected.branch ?? "HEAD") with interactive rebase?", context: context,
            changes:
                "Replay \(commits.count) commits as \(resultCount) commits onto \(onto.prefix(7)). Authors are preserved; the active profile becomes the committer. Other branches stay in place.",
            losses: (dropped > 0 ? ["\(dropped) commits are dropped from this branch."] : [])
                + (publishedCount > 0
                    ? [
                        "\(publishedCount) commits are reachable from remote-tracking branches. Others may have them; pushing rewritten history requires force-with-lease."
                    ] : []),
            recoverability:
                "Recover the previous branch tip through Repository → Reflog. Abort restores the branch while the rebase is in progress.",
            recoveryValue: expected.head, verb: "Rewrite History")
    }
}

extension RepositoryHandle {
    /// The range is strictly after base. `onto` allows transplanting that linear range to another commit.
    public nonisolated func interactiveRebasePlan(after base: String, onto: String? = nil)
        async throws(GitCoreError) -> InteractiveRebasePlan
    {
        _ = try requireWorkingTree()
        let expected = try await captureState()
        guard expected.operation == .none, expected.headRef != nil, let head = expected.head else {
            throw .refused(summary: "Interactive rebase needs a checked-out branch and no operation in progress.")
        }
        let baseOID = try await rebaseCommitID(base)
        let ontoOID = try await rebaseCommitID(onto ?? base)
        let ancestor = try await gitEngine.run(
            GitCommand(
                ["merge-base", "--is-ancestor", baseOID, head], in: workingDirectory, acceptedExitCodes: [0, 1]))
        guard ancestor.exitCode == 0 else {
            throw .refused(summary: "The base must be an ancestor of the current branch.")
        }
        let range = baseOID + ".." + head
        let count = String(
            decoding: try await runRead(["rev-list", "--count", range, "--"], limit: 1024), as: UTF8.self)
        guard let total = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)), total > 0, total <= 500 else {
            throw .refused(summary: "Choose a range containing between 1 and 500 commits after the base.")
        }
        let unpublishedBytes = try await runRead(["rev-list", range, "--not", "--remotes", "--"], limit: 128 * 1024)
        let unpublished = Set(
            String(decoding: unpublishedBytes, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
        let bytes = try await runRead(
            ["log", "--reverse", "--topo-order", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%B", range, "--"],
            limit: 64 * 1024 * 1024)
        let fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
        let ids = stride(from: 0, to: max(0, fields.count - 4), by: 5).map {
            String(decoding: fields[$0], as: UTF8.self)
        }
        let stats = try await rebaseDiffStatistics(ids)
        var commits: [RebaseCommit] = []
        var index = 0
        while index + 4 < fields.count {
            let oid = String(decoding: fields[index], as: UTF8.self)
            let parents = fields[index + 1].split(separator: 0x20)
            guard parents.count == 1 else {
                throw .refused(
                    summary:
                        "This range contains a merge or root commit. Choose a linear range; preserving merges is not supported yet."
                )
            }
            let message = String(decoding: fields[index + 4], as: UTF8.self).trimmingCharacters(in: .newlines)
            commits.append(
                RebaseCommit(
                    oid: oid,
                    subject: String(message.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""),
                    message: message,
                    author: String(decoding: fields[index + 2], as: UTF8.self) + " <"
                        + String(decoding: fields[index + 3], as: UTF8.self) + ">",
                    diffstat: stats[oid]?.label ?? "Empty commit", paths: stats[oid]?.paths ?? [],
                    published: !unpublished.contains(oid)))
            index += 5
        }
        guard commits.count == total else { throw .refused(summary: "The rebase range could not be read completely.") }
        guard try await captureState() == expected else {
            throw .staleSnapshot(summary: "The repository changed while preparing the rebase. Try again.")
        }
        return InteractiveRebasePlan(
            id: UUID(), expected: expected, base: baseOID, onto: ontoOID, commits: commits,
            steps: commits.map { RebaseStep(oid: $0.oid, message: $0.message) })
    }

    private nonisolated func rebaseDiffStatistics(_ ids: [String]) async throws(GitCoreError) -> [String:
        RebaseDiffStatistics]
    {
        let output = try await gitEngine.run(
            GitCommand(
                [
                    "diff-tree", "--stdin", "--root", "--numstat", "-z", "-r", "--no-renames", "--no-ext-diff",
                    "--no-textconv",
                ],
                in: workingDirectory, stdoutLimit: 16 * 1024 * 1024,
                stdin: Array((ids.joined(separator: "\n") + "\n").utf8)))
        var result: [String: RebaseDiffStatistics] = [:]
        var current: String?
        let validIDs = Set(ids)
        for record in output.stdout.split(separator: 0) {
            let fields = record.split(separator: 0x09, maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 1 {
                let oid = String(decoding: record, as: UTF8.self)
                current = validIDs.contains(oid) ? oid : nil
            } else if fields.count == 3, let current {
                var stat = result[current, default: RebaseDiffStatistics()]
                stat.paths.insert(String(decoding: fields[2], as: UTF8.self))
                stat.additions += Int(String(decoding: fields[0], as: UTF8.self)) ?? 0
                stat.deletions += Int(String(decoding: fields[1], as: UTF8.self)) ?? 0
                result[current] = stat
            }
        }
        return result
    }

    private nonisolated func rebaseCommitID(_ name: String) async throws(GitCoreError) -> String {
        try Self.requireSafeName(name, what: "rebase base")
        return String(
            decoding: try await runRead(
                ["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], limit: 1024), as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RebaseDiffStatistics {
    var additions = 0
    var deletions = 0
    var paths: Set<String> = []
    var label: String { "\(paths.count) \(paths.count == 1 ? "file" : "files") · +\(additions) −\(deletions)" }
}
