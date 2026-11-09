import Foundation

public enum MergeStrategy: String, Sendable, Hashable, CaseIterable {
    /// `--ff`: fast-forward when possible (default).
    case fastForwardIfPossible
    /// `--no-ff`: always create a merge commit.
    case noFastForward
    /// `--ff-only`.
    case fastForwardOnly
}

public struct MergeRequest: Sendable, Hashable {
    /// What to merge: a full ref name or a commit ID.
    public var source: String
    public var strategy: MergeStrategy
    /// `nil` keeps Git's message (`--no-edit`).
    public var message: String?

    public init(source: String, strategy: MergeStrategy = .fastForwardIfPossible, message: String? = nil) {
        self.source = source
        self.strategy = strategy
        self.message = message
    }
}

/// What a rebase would replay (sheet preview).
public struct RebasePlan: Sendable, Equatable {
    public var commits: [CommitSummary]
    /// Commits already in the branch's upstream (a later push needs force-with-lease).
    public var pushedCount: Int
}

extension RepositoryHandle {
    /// `git merge [--ff|--no-ff|--ff-only] [--no-edit|-m <msg>] <source>` (design §4.8). Merge commits use the
    /// snapshot identity (author and committer). Conflicts are an outcome, not an error.
    public func merge(_ request: MergeRequest, context: ExecContext, expected: RepoStateToken?)
        async throws(GitCoreError)
        -> IntegrationOutcome
    {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(request.source, what: "merge source")
        let identity = request.strategy == .fastForwardOnly ? context.identity : try context.requireIdentity()
        var arguments = ["merge"]
        switch request.strategy {
        case .fastForwardIfPossible: arguments.append("--ff")
        case .noFastForward: arguments.append("--no-ff")
        case .fastForwardOnly: arguments.append("--ff-only")
        }
        if let message = request.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-m", message]
        } else {
            arguments.append("--no-edit")
        }
        arguments.append(request.source)
        let mergeArguments = arguments
        return try await performExclusive("Merge \(request.source)", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.ensureCurrent(expected, engine: engine, in: topLevel, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            if request.strategy == .fastForwardOnly {
                let counts = try await Self.aheadBehind(engine: engine, in: topLevel, "HEAD", request.source)
                if counts.behind == 0 { return .upToDate }
                if counts.ahead > 0 { return .notFastForward(ahead: counts.ahead, behind: counts.behind) }
            }
            return try await Self.runIntegration(
                mergeArguments, identity: identity, use: .authorAndCommitter, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory, headBefore: head)
        }
    }

    /// Optional preflight (Git ≥ 2.38): paths `git merge-tree --write-tree` reports as conflicting. Read-only.
    public nonisolated func predictMergeConflicts(source: String) async throws(GitCoreError) -> [String] {
        try Self.requireSafeName(source, what: "merge source")
        let output = try await gitEngine.run(
            GitCommand(
                ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "HEAD", source],
                in: workingDirectory, kind: .read, stdoutLimit: 16 * 1024 * 1024, acceptedExitCodes: [0, 1]))
        guard output.exitCode == 1 else { return [] }
        // Output: <tree>\0<path>\0<path>\0…\0 (the conflicted file list follows the tree OID).
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: true).dropFirst()
        var seen = Set<String>()
        return fields.map { String(decoding: $0, as: UTF8.self) }.filter { seen.insert($0).inserted }
    }

    /// Commits `git rebase <onto>` would replay, oldest first, and how many are already pushed.
    public nonisolated func rebasePlan(onto: String) async throws(GitCoreError) -> RebasePlan {
        try Self.requireSafeName(onto, what: "rebase target")
        let commits = try await commits(in: "HEAD", notIn: onto, limit: 500).reversed()
        var pushed = 0
        if let upstream = try await upstream() {
            let unpushed = Set(try await self.commits(in: "HEAD", notIn: upstream.ref, limit: 5000).map(\.oid))
            pushed = commits.filter { !unpushed.contains($0.oid) }.count
        }
        return RebasePlan(commits: Array(commits), pushedCount: pushed)
    }

    /// `git rebase --no-autostash --no-autosquash --no-update-refs <onto>` (explicit flags so the sheet's
    /// promise holds whatever the user's configuration says — ADR-0030). Requires a clean working tree.
    /// Replayed commits keep their authors; the committer is the profile.
    public func rebase(onto: String, context: ExecContext, expected: RepoStateToken?) async throws(GitCoreError)
        -> IntegrationOutcome
    {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(onto, what: "rebase target")
        let identity = try context.requireIdentity()
        return try await performExclusive("Rebase onto \(onto)", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.ensureCurrent(expected, engine: engine, in: topLevel, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.requireCleanTrackedTree(engine: engine, in: topLevel)
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            let counts = try await Self.aheadBehind(engine: engine, in: topLevel, "HEAD", onto)
            return try await Self.runIntegration(
                ["rebase", "--no-autostash", "--no-autosquash", "--no-update-refs", onto], identity: identity,
                use: .committerOnly, engine: engine, topLevel: topLevel, gitDirectory: gitDirectory, headBefore: head,
                ahead: counts.ahead, isRebase: true)
        }
    }

    static func requireCleanTrackedTree(engine: GitEngine, in directory: String) async throws(GitCoreError) {
        let output = try await engine.run(
            GitCommand(
                ["--no-optional-locks", "status", "--porcelain=v2", "-z", "--untracked-files=no"], in: directory,
                kind: .read, stdoutLimit: 64 * 1024 * 1024))
        guard output.stdout.isEmpty else {
            throw .failed(
                ClassifiedFailure(
                    kind: .dirtyWorkingTree,
                    summary: "Commit or stash your changes first: rebase needs a clean working tree."))
        }
    }

    /// `git cherry-pick [-m <parent>] <oid>…` applied oldest → newest. Authors are preserved; the committer
    /// is the profile. Merge commits require a mainline.
    public func cherryPick(
        _ commits: [String], mainline: Int? = nil, context: ExecContext, expected: RepoStateToken?
    ) async throws(GitCoreError) -> IntegrationOutcome {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        guard !commits.isEmpty else { return .upToDate }
        for oid in commits { try Self.requireObjectID(oid) }
        let identity = try context.requireIdentity()
        let ordered = try await orderOldestFirst(commits)
        try await requireMainlineIfMerge(ordered, mainline: mainline)
        var arguments = ["cherry-pick", "--allow-empty-message"]
        if let mainline { arguments += ["-m", "\(mainline)"] }
        arguments += ordered
        let pickArguments = arguments
        return try await performExclusive(
            ordered.count == 1 ? "Cherry-pick \(ordered[0].prefix(7))" : "Cherry-pick \(ordered.count) commits",
            invalidating: Set(InvalidationKind.allCases)
        ) { () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.ensureCurrent(expected, engine: engine, in: topLevel, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            return try await Self.runIntegration(
                pickArguments, identity: identity, use: .committerOnly, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory, headBefore: head)
        }
    }

    /// `git revert --no-edit [-m <parent>] <oid>`: a new commit by the profile (author and committer).
    public func revert(_ commit: String, mainline: Int? = nil, context: ExecContext, expected: RepoStateToken?)
        async throws(GitCoreError) -> IntegrationOutcome
    {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireObjectID(commit)
        let identity = try context.requireIdentity()
        try await requireMainlineIfMerge([commit], mainline: mainline)
        var arguments = ["revert", "--no-edit"]
        if let mainline { arguments += ["-m", "\(mainline)"] }
        arguments.append(commit)
        let revertArguments = arguments
        return try await performExclusive("Revert \(commit.prefix(7))", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.ensureCurrent(expected, engine: engine, in: topLevel, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            return try await Self.runIntegration(
                revertArguments, identity: identity, use: .authorAndCommitter, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory, headBefore: head)
        }
    }

    /// Parents of a commit (mainline choice for merge commits).
    public nonisolated func parents(of commit: String) async throws(GitCoreError) -> [CommitSummary] {
        try Self.requireObjectID(commit)
        let line = String(
            decoding: try await runRead(["rev-list", "--parents", "-n", "1", commit, "--"], limit: 64 * 1024),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [CommitSummary] = []
        for parent in line.split(separator: " ").dropFirst() {
            let subject = String(
                decoding: try await runRead(["log", "-1", "--format=%s", String(parent), "--"], limit: 64 * 1024),
                as: UTF8.self
            ).trimmingCharacters(in: .newlines)
            result.append(CommitSummary(oid: String(parent), subject: subject))
        }
        return result
    }

    private nonisolated func requireMainlineIfMerge(_ commits: [String], mainline: Int?) async throws(GitCoreError) {
        for commit in commits {
            let count = try await parents(of: commit).count
            if count > 1, mainline == nil {
                throw .refused(summary: "\(commit.prefix(7)) is a merge commit: choose which parent is the mainline.")
            }
            if let mainline, mainline > count || mainline < 1 || count < 2 {
                throw .refused(summary: "\(commit.prefix(7)) has no parent \(mainline) to use as mainline.")
            }
        }
    }

    /// Sorts commits oldest → newest by topology (ancestors first), ties by commit date.
    nonisolated func orderOldestFirst(_ commits: [String]) async throws(GitCoreError) -> [String] {
        guard commits.count > 1 else { return commits }
        let output = String(
            decoding: try await runRead(
                ["rev-list", "--no-walk=sorted", "--topo-order", "--reverse"] + commits + ["--"], limit: 4 * 1024 * 1024
            ),
            as: UTF8.self)
        let ordered = output.split(whereSeparator: \.isNewline).map(String.init)
        let wanted = Set(commits)
        let result = ordered.filter { wanted.contains($0) }
        return result.count == commits.count ? result : commits
    }

    // MARK: Continue / skip / abort

    /// `--continue` for the current operation (`GIT_EDITOR=true` keeps Git's prepared message). Refused
    /// while unmerged paths remain.
    public func continueOperation(context: ExecContext) async throws(GitCoreError) -> IntegrationOutcome {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let identity = try context.requireIdentity()
        return try await performExclusive("Continue", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let unmerged = try await Self.unmergedPathList(engine: engine, in: topLevel)
            guard unmerged.isEmpty else {
                throw .failed(
                    ClassifiedFailure(
                        kind: .unmergedIndex, summary: "Resolve the remaining conflicts first.", paths: unmerged))
            }
            let state = OperationStateDetector.detect(gitDirectory: gitDirectory)
            let (command, use): (String, IdentityUse)
            switch state {
            case .merging: (command, use) = ("merge", .authorAndCommitter)
            case .rebasing: (command, use) = ("rebase", .committerOnly)
            case .cherryPicking: (command, use) = ("cherry-pick", .committerOnly)
            case .reverting: (command, use) = ("revert", .authorAndCommitter)
            case .none:
                if FileManager.default.fileExists(atPath: gitDirectory + "/sequencer") {
                    (command, use) = ("cherry-pick", .committerOnly)
                } else {
                    return .finished
                }
            case .bisecting, .applyingMailbox:
                throw .refused(summary: "Jit doesn't drive this operation. Finish it in Terminal.")
            }
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            let outcome = try await Self.runIntegration(
                [command, "--continue"], identity: identity, use: use, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory, headBefore: head)
            return Self.finalize(outcome, gitDirectory: gitDirectory)
        }
    }

    /// `--skip` (rebase, cherry-pick, revert): drops the current commit. Destructive.
    public func skipCurrent(context: ExecContext, token: ConfirmationToken) async throws(GitCoreError)
        -> IntegrationOutcome
    {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try token.verify(.skipCurrent)
        let identity = try context.requireIdentity()
        return try await performExclusive("Skip commit", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let command: String
            switch OperationStateDetector.detect(gitDirectory: gitDirectory) {
            case .rebasing: command = "rebase"
            case .cherryPicking: command = "cherry-pick"
            case .reverting: command = "revert"
            default: throw .refused(summary: "There's no commit to skip.")
            }
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            let outcome = try await Self.runIntegration(
                [command, "--skip"], identity: identity, use: .committerOnly, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory, headBefore: head)
            return Self.finalize(outcome, gitDirectory: gitDirectory)
        }
    }

    /// `--abort`: returns to the state before the operation. Destructive (resolutions are lost).
    public func abortOperation(token: ConfirmationToken) async throws(GitCoreError) {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try token.verify(.abortOperation)
        _ = try await performExclusive("Abort", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let command: String
            switch OperationStateDetector.detect(gitDirectory: gitDirectory) {
            case .merging: command = "merge"
            case .rebasing: command = "rebase"
            case .cherryPicking: command = "cherry-pick"
            case .reverting: command = "revert"
            case .none where FileManager.default.fileExists(atPath: gitDirectory + "/sequencer"):
                command = "cherry-pick"
            default: throw .refused(summary: "There's no operation to abort.")
            }
            _ = try await Self.runClassified(
                GitCommand([command, "--abort"], in: topLevel, kind: .write, timeout: nil), engine: engine,
                gitDirectory: gitDirectory)
        }
    }

    /// After continue/skip: `.upToDate` from the head comparison means the step finished without moving
    /// HEAD; report `.finished` when no operation remains.
    static func finalize(_ outcome: IntegrationOutcome, gitDirectory: String) -> IntegrationOutcome {
        switch outcome {
        case .stoppedWithConflicts, .stoppedInProgress: return outcome
        default:
            return OperationStateDetector.detect(gitDirectory: gitDirectory) == .none ? .finished : outcome
        }
    }
}
