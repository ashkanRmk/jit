import Foundation

extension RepositoryHandle {
    /// Pull the chosen branch using its upstream or the explicitly selected remote. Inactive branches
    /// advance directly; active branches integrate with --ff-only. Other worktrees stay protected by Git.
    public func pullBranch(
        _ branch: String, remote selectedRemote: String? = nil, remoteBranch selectedBranch: String? = nil,
        context: ExecContext, expected: RepoStateToken?
    ) async throws(GitCoreError) {
        try Self.requireSafeName(branch, what: "branch")
        let upstream = try await upstream(of: branch)
        guard let remoteName = selectedRemote ?? upstream?.remote,
            let remote = try await remotes().first(where: { $0.name == remoteName })
        else {
            throw .refused(summary: "Set an upstream for “\(branch)” before pulling.")
        }
        try Self.requireSafeName(remote.name, what: "remote")
        let destination =
            selectedBranch ?? upstream.map { String($0.shortName.dropFirst($0.remote.count + 1)) } ?? branch
        try await requireValidBranchRef(destination)
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Pull \(branch)", invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            guard try await Self.readRef(engine: engine, in: directory, "refs/heads/\(branch)") != nil else {
                throw .refused(
                    summary: "Check out the remote branch to create local branch “\(branch)” before pulling.")
            }
            let before = try await Self.readState(engine: engine, in: directory, gitDirectory: gitDirectory)
            let isCurrent = before.headRef == "refs/heads/\(branch)"
            let target = isCurrent ? "refs/remotes/\(remote.name)/\(destination)" : "refs/heads/\(branch)"
            let lease = try await context.prepareAccess(for: remote.fetchURLs, purpose: .fetch)
            defer { lease?.release() }
            _ = try await Self.runClassified(
                GitEnvironment.remoteCommand(
                    ["fetch", "--no-tags", remote.name, "refs/heads/\(destination):\(target)"],
                    in: directory, context: context, access: lease?.access), engine: engine, gitDirectory: gitDirectory)
            if isCurrent {
                let after = try await Self.readState(engine: engine, in: directory, gitDirectory: gitDirectory)
                guard after.headRef == before.headRef, after.head == before.head else {
                    throw .staleSnapshot(
                        summary: "The checked-out branch changed while fetching. Nothing was integrated.")
                }
                guard let tip = try await Self.readRef(engine: engine, in: directory, target) else {
                    throw .refused(summary: "The fetched branch no longer exists.")
                }
                _ = try await Self.runClassified(
                    GitCommand(["merge", "--ff-only", tip], in: directory, kind: .write),
                    engine: engine, gitDirectory: gitDirectory)
            }
        }
    }

    public func fastForwardBranch(_ branch: String, to commit: String, expected: RepoStateToken?)
        async throws(GitCoreError)
    {
        try Self.requireSafeName(branch, what: "branch")
        try Self.requireObjectID(commit)
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Fast-forward \(branch)", invalidating: [.refs]) { () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            let ancestor = try await engine.run(
                GitCommand(
                    ["merge-base", "--is-ancestor", "refs/heads/\(branch)", commit], in: directory,
                    kind: .read, acceptedExitCodes: [0, 1]))
            guard ancestor.exitCode == 0 else {
                throw .refused(summary: "“\(branch)” cannot be fast-forwarded to this commit.")
            }
            _ = try await Self.runClassified(
                GitEnvironment.remoteCommand(
                    ["fetch", "--no-tags", "--no-write-fetch-head", ".", "\(commit):refs/heads/\(branch)"],
                    in: directory, context: .anonymous), engine: engine, gitDirectory: gitDirectory)
        }
    }

    public nonisolated func commitPatch(_ commit: String) async throws(GitCoreError) -> [UInt8] {
        try Self.requireObjectID(commit)
        let parents = try await runRead(["rev-list", "--parents", "-n", "1", commit, "--"], limit: 1024 * 1024)
        if parents.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }).count > 2 {
            // format-patch skips merges and may export an earlier commit instead. Use the first-parent diff.
            return try await runRead(["diff", "--binary", "\(commit)^1", commit, "--"], limit: 64 * 1024 * 1024)
        }
        return try await runRead(
            ["format-patch", "--always", "-1", "--stdout", "--binary", commit], limit: 64 * 1024 * 1024)
    }

    public func createWorktree(at path: String, commit: String, expected: RepoStateToken?) async throws(GitCoreError) {
        try Self.requireObjectID(commit)
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Create worktree", invalidating: [.refs, .config]) { () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            _ = try await Self.runClassified(
                GitCommand(
                    ["worktree", "add", "--detach", "--", path, commit],
                    in: directory, kind: .write), engine: engine, gitDirectory: gitDirectory)
        }
    }

}
