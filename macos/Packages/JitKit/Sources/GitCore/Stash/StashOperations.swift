import Foundation

/// One `stash@{n}` entry (design §3.11, §4.15).
public struct StashEntry: Sendable, Hashable, Identifiable {
    public let index: Int
    public let oid: String
    /// Parents: base commit, index commit, and (with untracked files) the untracked commit.
    public let parents: [String]
    public let date: Date
    /// The reflog subject: "WIP on main: abc1234 Subject" or "On main: message".
    public let subject: String

    public var id: String { oid }
    public var name: String { "stash@{\(index)}" }
    public var hasUntracked: Bool { parents.count >= 3 }

    /// Branch the stash was created on (`main` of "On main: …"), if recorded.
    public var branch: String? {
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            if let colon = rest.firstIndex(of: ":") { return String(rest[..<colon]) }
        }
        return nil
    }

    /// The user's message (after "On <branch>: "), or the WIP subject.
    public var message: String {
        guard let colon = subject.firstIndex(of: ":") else { return subject }
        return subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}

public struct StashPushRequest: Sendable, Hashable {
    public var message: String?
    public var includeUntracked: Bool
    /// `--keep-index`.
    public var keepIndex: Bool
    /// `--staged`: stash only staged changes.
    public var stagedOnly: Bool
    /// Only these paths (empty = everything).
    public var paths: [String]

    public init(
        message: String? = nil, includeUntracked: Bool = false, keepIndex: Bool = false, stagedOnly: Bool = false,
        paths: [String] = []
    ) {
        self.message = message
        self.includeUntracked = includeUntracked
        self.keepIndex = keepIndex
        self.stagedOnly = stagedOnly
        self.paths = paths
    }
}

public enum StashApplyOutcome: Sendable, Equatable {
    case applied
    /// Applied with conflicts. A pop keeps the stash (Git's behavior) — the UI says so.
    case conflicts(paths: [String], stashKept: Bool)
}

/// Parses `git stash list -z --format=%gd%x00%H%x00%P%x00%ct%x00%gs` (five NUL-separated fields per entry;
/// subjects may contain newlines and any Unicode).
public enum StashListParser {
    public static func parse(_ bytes: [UInt8]) -> [StashEntry] {
        let fields = bytes.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var entries: [StashEntry] = []
        var position = 0
        while position + 4 < fields.count {
            let selector = fields[position]
            guard selector.hasPrefix("stash@{"), selector.hasSuffix("}"),
                let index = Int(selector.dropFirst(7).dropLast())
            else {
                position += 1
                continue
            }
            let seconds = TimeInterval(fields[position + 3]) ?? 0
            entries.append(
                StashEntry(
                    index: index, oid: fields[position + 1],
                    parents: fields[position + 2].split(separator: " ").map(String.init),
                    date: Date(timeIntervalSince1970: seconds), subject: fields[position + 4]))
            position += 5
        }
        return entries
    }
}

extension RepositoryHandle {
    /// Stash entries, newest first (read-only).
    public nonisolated func stashes() async throws(GitCoreError) -> [StashEntry] {
        let output = try await gitEngine.run(
            GitCommand(
                ["stash", "list", "-z", "--format=%gd%x00%H%x00%P%x00%ct%x00%gs"], in: workingDirectory, kind: .read,
                stdoutLimit: 64 * 1024 * 1024, acceptedExitCodes: [0, 1]))
        return StashListParser.parse(output.stdout)
    }

    /// `git stash push [-m] [-u] [--keep-index] [--staged] [-- paths]`. Stash commits use the profile identity.
    @discardableResult
    public func stashPush(_ request: StashPushRequest, context: ExecContext) async throws(GitCoreError) -> StashEntry? {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let identity = try context.requireIdentity()
        return try await performExclusive("Stash changes", invalidating: [.index, .worktree, .refs]) {
            () throws(GitCoreError) -> StashEntry? in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.pushStash(
                request, identity: identity, engine: engine, topLevel: topLevel, gitDirectory: gitDirectory)
            return StashListParser.parse(
                try await engine.run(
                    GitCommand(
                        ["stash", "list", "-z", "-n", "1", "--format=%gd%x00%H%x00%P%x00%ct%x00%gs"], in: topLevel,
                        kind: .read, acceptedExitCodes: [0, 1])
                ).stdout
            ).first
        }
    }

    static func pushStash(
        _ request: StashPushRequest, identity: IdentitySnapshot, engine: GitEngine, topLevel: String,
        gitDirectory: String
    ) async throws(GitCoreError) {
        var arguments = ["stash", "push", "--quiet"]
        if let message = request.message, !message.isEmpty { arguments += ["-m", message] }
        if request.includeUntracked { arguments.append("--include-untracked") }
        if request.keepIndex { arguments.append("--keep-index") }
        if request.stagedOnly { arguments.append("--staged") }
        var stdin: [UInt8]?
        if !request.paths.isEmpty {
            arguments = ["--literal-pathspecs"] + arguments + ["--pathspec-from-file=-", "--pathspec-file-nul"]
            var input: [UInt8] = []
            for path in request.paths {
                input += Array(path.utf8)
                input.append(0)
            }
            stdin = input
        }
        let before = try await readRef(engine: engine, in: topLevel, "refs/stash")
        let command = GitEnvironment.integrationCommand(
            arguments, in: topLevel, identity: identity, use: .authorAndCommitter, stdin: stdin)
        _ = try await runClassified(command, engine: engine, gitDirectory: gitDirectory)
        let after = try await readRef(engine: engine, in: topLevel, "refs/stash")
        if before == after { throw .refused(summary: "There are no local changes to stash.") }
    }

    /// Validates that `stash@{index}` still names `oid` (indices shift when stashes are added or dropped).
    static func requireStash(index: Int, oid: String, engine: GitEngine, in directory: String)
        async throws(GitCoreError)
    {
        let current = try await readRef(engine: engine, in: directory, "refs/stash@{\(index)}")
        guard current == oid else {
            throw .staleSnapshot(summary: "The stash list changed. Review the stashes and try again.")
        }
    }

    /// `git stash apply|pop stash@{n}` after checking the entry's OID. Conflicts are an outcome.
    public func applyStash(index: Int, oid: String, pop: Bool, context: ExecContext) async throws(GitCoreError)
        -> StashApplyOutcome
    {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireObjectID(oid)
        return try await performExclusive(
            pop ? "Pop stash@{\(index)}" : "Apply stash@{\(index)}", invalidating: [.index, .worktree, .refs]
        ) { () throws(GitCoreError) -> StashApplyOutcome in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.requireStash(index: index, oid: oid, engine: engine, in: topLevel)
            return try await Self.applyStash(
                index: index, pop: pop, identity: context.identity, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory)
        }
    }

    static func applyStash(
        index: Int, pop: Bool, identity: IdentitySnapshot?, engine: GitEngine, topLevel: String, gitDirectory: String
    ) async throws(GitCoreError) -> StashApplyOutcome {
        let command = GitEnvironment.integrationCommand(
            ["stash", pop ? "pop" : "apply", "--quiet", "stash@{\(index)}"], in: topLevel, identity: identity,
            use: .authorAndCommitter, acceptedExitCodes: [0, 1])
        let output: ProcessOutput
        do {
            output = try await engine.run(command)
        } catch .processFailed(let code, _, let detail) {
            throw .failed(GitErrorClassifier.classify(exitCode: code, stderr: detail))
        }
        let unmerged = try await unmergedPathList(engine: engine, in: topLevel)
        if !unmerged.isEmpty { return .conflicts(paths: unmerged, stashKept: true) }
        if output.exitCode != 0 {
            throw .failed(GitErrorClassifier.classify(exitCode: output.exitCode, stderr: output.stderrText))
        }
        return .applied
    }

    /// Pops `stash@{0}` in a task the caller's cancellation cannot reach (restore after a failed switch).
    static func restoreStash(identity: IdentitySnapshot, engine: GitEngine, topLevel: String, gitDirectory: String)
        async
        -> Result<StashApplyOutcome, GitCoreError>
    {
        do throws(GitCoreError) {
            return .success(
                try await uncancellable { () throws(GitCoreError) -> StashApplyOutcome in
                    try await applyStash(
                        index: 0, pop: true, identity: identity, engine: engine, topLevel: topLevel,
                        gitDirectory: gitDirectory)
                })
        } catch {
            return .failure(error)
        }
    }

    /// `git stash drop stash@{n}` after checking the OID. Destructive (recoverable only by SHA).
    public func dropStash(index: Int, oid: String, token: ConfirmationToken) async throws(GitCoreError) {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try token.verify(.dropStash(index: index, oid: oid))
        _ = try await performExclusive("Drop stash@{\(index)}", invalidating: [.refs]) { () throws(GitCoreError) in
            try await Self.requireStash(index: index, oid: oid, engine: engine, in: topLevel)
            _ = try await Self.runClassified(
                GitCommand(["stash", "drop", "--quiet", "stash@{\(index)}"], in: topLevel, kind: .write),
                engine: engine, gitDirectory: gitDirectory)
        }
    }

    /// `git stash clear`. Destructive.
    public func clearStashes(token: ConfirmationToken) async throws(GitCoreError) {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try token.verify(.clearStashes)
        _ = try await performExclusive("Clear stashes", invalidating: [.refs]) { () throws(GitCoreError) in
            _ = try await Self.runClassified(
                GitCommand(["stash", "clear"], in: topLevel, kind: .write), engine: engine, gitDirectory: gitDirectory)
        }
    }

    /// "Stash and Switch" (design §3.6, §4.15): stash everything (including untracked), switch, and leave the
    /// stash in place. If the switch fails the stash is popped back, so nothing is lost; one serialized
    /// operation.
    public func stashAndSwitch(_ target: SwitchTarget, context: ExecContext, expected: RepoStateToken?)
        async throws(GitCoreError) -> StashEntry?
    {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let identity = try context.requireIdentity()
        let arguments: [String]
        switch target {
        case .branch(let name):
            try Self.requireSafeName(name, what: "branch")
            arguments = ["switch", "--no-guess", name]
        case .trackRemote(let remote, let branch, let localName):
            try Self.requireSafeName(remote, what: "remote")
            try Self.requireSafeName(branch, what: "branch")
            _ = try await validateBranchName(localName)
            arguments = ["switch", "-c", localName, "--track", "refs/remotes/\(remote)/\(branch)"]
        case .detach(let oid):
            try Self.requireObjectID(oid)
            arguments = ["switch", "--detach", oid]
        }
        return try await performExclusive("Stash and switch", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> StashEntry? in
            try await Self.ensureCurrent(expected, engine: engine, in: topLevel, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let branch = try await engine.run(
                GitCommand(
                    ["symbolic-ref", "-q", "--short", "HEAD"], in: topLevel, kind: .read, acceptedExitCodes: [0, 1])
            ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Self.pushStash(
                StashPushRequest(
                    message: "Jit: stashed before switching from \(branch.isEmpty ? "detached HEAD" : branch)",
                    includeUntracked: true), identity: identity, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory)
            do throws(GitCoreError) {
                let outcome = try await Self.runSwitch(
                    arguments, engine: engine, in: topLevel, gitDirectory: gitDirectory)
                guard outcome == .switched else {
                    throw GitCoreError.refused(summary: "Git still refused to switch.")
                }
            } catch {
                // Put everything back where it was — even if this operation is being cancelled — and say exactly
                // what happened: "restored" only when the pop applied cleanly.
                let stashOID =
                    (try? await Self.uncancellable { () throws(GitCoreError) -> String? in
                        try await Self.readRef(engine: engine, in: topLevel, "refs/stash")
                    }) ?? nil
                let restore = await Self.restoreStash(
                    identity: identity, engine: engine, topLevel: topLevel, gitDirectory: gitDirectory)
                switch restore {
                case .success(.applied):
                    throw .refused(
                        summary: "Switching failed, so your changes were restored from the stash: \(error.summary)")
                default:
                    throw .refused(
                        summary:
                            "Switching failed and your changes could not be put back automatically. They are safe in stash@{0}\(stashOID.map { " (\($0.prefix(10)))" } ?? ""). \(error.summary)"
                    )
                }
            }
            return StashListParser.parse(
                try await engine.run(
                    GitCommand(
                        ["stash", "list", "-z", "-n", "1", "--format=%gd%x00%H%x00%P%x00%ct%x00%gs"], in: topLevel,
                        kind: .read, acceptedExitCodes: [0, 1])
                ).stdout
            ).first
        }
    }
}
