import Foundation

public enum SwitchTarget: Sendable, Hashable {
    /// An existing local branch.
    case branch(String)
    /// Create local `localName` tracking `remote`/`branch` and switch to it.
    case trackRemote(remote: String, branch: String, localName: String)
    /// Detached HEAD at a commit.
    case detach(String)
}

public enum SwitchOutcome: Sendable, Equatable {
    case switched
    /// Git refused: these files have changes that would be overwritten. Nothing changed.
    case wouldOverwrite(paths: [String], untracked: Bool)
}

extension RepositoryHandle {
    /// `git check-ref-format --branch <name>` (run, not reimplemented). Returns the normalized name.
    public nonisolated func validateBranchName(_ name: String) async throws(GitCoreError) -> String {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw .refused(summary: "Enter a branch name.") }
        let output = try await gitEngine.run(
            GitCommand(
                ["check-ref-format", "--branch", name], in: workingDirectory, kind: .read,
                acceptedExitCodes: [0, 1, 128]))
        let normalized = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.exitCode == 0, !normalized.isEmpty, normalized == name else {
            throw .failed(ClassifiedFailure(kind: .invalidName, summary: "“\(name)” isn't a valid branch name."))
        }
        let exists = try await Self.readRef(engine: gitEngine, in: workingDirectory, "refs/heads/\(name)")
        if exists != nil {
            throw .failed(ClassifiedFailure(kind: .alreadyExists, summary: "A branch named “\(name)” already exists."))
        }
        return normalized
    }

    /// `git branch --no-track <name> <start>` or, with `switchTo`, `git switch --no-track -c <name> <start>`.
    public func createBranch(
        _ name: String, startPoint: String, switchTo: Bool, expected: RepoStateToken?
    ) async throws(GitCoreError) -> SwitchOutcome {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        _ = try await validateBranchName(name)
        try Self.requireSafeName(startPoint, what: "start point")
        return try await performExclusive("Create branch \(name)", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> SwitchOutcome in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            if switchTo {
                return try await Self.runSwitch(
                    ["switch", "--no-track", "-c", name, startPoint], engine: engine, in: directory,
                    gitDirectory: gitDirectory)
            }
            _ = try await Self.runClassified(
                GitCommand(["branch", "--no-track", name, startPoint], in: directory, kind: .write),
                engine: engine, gitDirectory: gitDirectory)
            return .switched
        }
    }

    /// `git switch` (design §3.6). A dirty-tree refusal is an outcome listing the blocking paths.
    public func switchTo(_ target: SwitchTarget, expected: RepoStateToken?) async throws(GitCoreError) -> SwitchOutcome
    {
        let directory = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let arguments: [String]
        let title: String
        switch target {
        case .branch(let name):
            try Self.requireSafeName(name, what: "branch")
            arguments = ["switch", "--no-guess", name]
            title = "Switch to \(name)"
        case .trackRemote(let remote, let branch, let localName):
            try Self.requireSafeName(remote, what: "remote")
            try Self.requireSafeName(branch, what: "branch")
            _ = try await validateBranchName(localName)
            arguments = ["switch", "-c", localName, "--track", "refs/remotes/\(remote)/\(branch)"]
            title = "Check out \(remote)/\(branch)"
        case .detach(let oid):
            try Self.requireObjectID(oid)
            arguments = ["switch", "--detach", oid]
            title = "Check out \(oid.prefix(7))"
        }
        return try await performExclusive(title, invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> SwitchOutcome in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            return try await Self.runSwitch(arguments, engine: engine, in: directory, gitDirectory: gitDirectory)
        }
    }

    static func runSwitch(_ arguments: [String], engine: GitEngine, in directory: String, gitDirectory: String)
        async throws(GitCoreError) -> SwitchOutcome
    {
        do {
            _ = try await runClassified(
                GitCommand(arguments, in: directory, kind: .write, timeout: nil), engine: engine,
                gitDirectory: gitDirectory)
            return .switched
        } catch .failed(let failure) where failure.kind == .dirtyWorkingTree && !failure.paths.isEmpty {
            return .wouldOverwrite(paths: failure.paths, untracked: false)
        } catch .failed(let failure) where failure.kind == .untrackedWouldBeOverwritten {
            return .wouldOverwrite(paths: failure.paths, untracked: true)
        }
    }

    /// `git branch -m <old> <new>`: the upstream configuration follows; the remote branch is not renamed.
    public func renameBranch(_ old: String, to new: String, expected: RepoStateToken?) async throws(GitCoreError) {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(old, what: "branch")
        _ = try await validateBranchName(new)
        _ = try await performExclusive("Rename \(old) to \(new)", invalidating: [.refs, .head, .config]) {
            () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            _ = try await Self.runClassified(
                GitCommand(["branch", "-m", old, new], in: directory, kind: .write), engine: engine,
                gitDirectory: gitDirectory)
        }
    }

    /// `git branch -d` (or `-D` with a force token). An unmerged branch with `-d` throws
    /// `.failed(kind: .branchNotFullyMerged)`; the UI then shows the unmerged commits and asks again.
    public func deleteBranch(_ name: String, token: ConfirmationToken, expected: RepoStateToken?)
        async throws(GitCoreError)
    {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(name, what: "branch")
        let force: Bool
        switch token.action {
        case .deleteBranch(let confirmed, let isForce) where confirmed == name: force = isForce
        default: throw .refused(summary: "This action wasn't confirmed. Nothing was changed.")
        }
        _ = try await performExclusive("Delete branch \(name)", invalidating: [.refs, .config]) {
            () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            _ = try await Self.runClassified(
                GitCommand(["branch", force ? "-D" : "-d", name], in: directory, kind: .write), engine: engine,
                gitDirectory: gitDirectory)
        }
    }

    /// `git push --force-with-lease=refs/heads/<b>:<expected> <remote> --delete refs/heads/<b>` (high-risk
    /// destructive): the remote branch is deleted only while it still points at the tip the sheet showed.
    public func deleteRemoteBranch(
        remote: String, branch: String, expectedTip: String, token: ConfirmationToken, context: ExecContext = .anonymous
    ) async throws(GitCoreError) -> PushOutcome {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(remote, what: "remote")
        try await requireValidBranchRef(branch)
        try Self.requireObjectID(expectedTip)
        try token.verify(.deleteRemoteBranch(remote: remote, branch: branch))
        guard try await remotes().contains(where: { $0.name == remote }) else {
            throw .refused(summary: "There's no remote named “\(remote)”.")
        }
        return try await performExclusive("Delete \(remote)/\(branch)", invalidating: [.refs]) {
            () throws(GitCoreError) -> PushOutcome in
            let command = GitEnvironment.remoteCommand(
                [
                    "push", "--porcelain", "--force-with-lease=refs/heads/\(branch):\(expectedTip)", remote, "--delete",
                    "refs/heads/\(branch)",
                ], in: directory, context: context,
                acceptedExitCodes: [0, 1])
            let output = try await Self.runClassified(command, engine: engine, gitDirectory: gitDirectory)
            let refs = PushPorcelainParser.parse(output.stdoutText)
            if refs.isEmpty, output.exitCode != 0 {
                throw .failed(GitErrorClassifier.classify(exitCode: output.exitCode, stderr: output.stderrText))
            }
            return PushOutcome(
                refs: refs, remoteLines: [], rejection: PushPorcelainParser.rejection(refs), cancelled: false)
        }
    }

    /// `git branch --set-upstream-to=<remote>/<branch> <local>`, or `--unset-upstream` when `upstream` is nil.
    public func setUpstream(of branch: String, to upstream: String?) async throws(GitCoreError) {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(branch, what: "branch")
        if let upstream { try Self.requireSafeName(upstream, what: "upstream") }
        let arguments =
            upstream.map { ["branch", "--set-upstream-to=refs/remotes/\($0)", branch] }
            ?? ["branch", "--unset-upstream", branch]
        _ = try await performExclusive(
            upstream == nil ? "Unset upstream of \(branch)" : "Set upstream of \(branch)",
            invalidating: [.config, .refs]
        ) { () throws(GitCoreError) in
            _ = try await Self.runClassified(
                GitCommand(arguments, in: directory, kind: .write), engine: engine, gitDirectory: gitDirectory)
        }
    }
}
