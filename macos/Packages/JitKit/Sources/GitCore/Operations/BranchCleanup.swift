import Foundation

/// A reviewed set of merged local branches, verified against every configured remote.
public struct BranchCleanupPlan: Sendable {
    public let branches: [String]
    public let kept: [String]
    public let expected: RepoStateToken
}

extension RefSnapshot {
    /// A hint for the sidebar. Cleanup verifies the live remotes before offering bulk deletion.
    public func hasRemoteCounterpart(_ branch: GitRef) -> Bool {
        guard branch.kind == .local else { return true }
        if let upstream = branch.upstream, !branch.upstreamGone,
            refs.contains(where: { $0.kind == .remote && $0.shortName == upstream })
        {
            return true
        }
        return refs.contains { $0.kind == .remote && $0.remoteBranchName == branch.shortName }
    }
}

extension RepositoryHandle {
    /// Read live heads, not just remote-tracking refs (which may be stale or limited by fetch refspecs).
    private func branchesWithoutRemote(context: ExecContext) async throws(GitCoreError) -> [String] {
        let remotes = try await remotes()
        guard !remotes.isEmpty else {
            throw .refused(summary: "There are no remotes to check. Delete individual local branches instead.")
        }
        var heads: [String: Set<String>] = [:]
        for remote in remotes {
            let lease = try await context.prepareAccess(for: remote.fetchURLs, purpose: .fetch)
            defer { lease?.release() }
            let output = try await Self.runClassified(
                GitEnvironment.remoteCommand(
                    ["ls-remote", "--heads", remote.name], in: workingDirectory, context: context,
                    access: lease?.access), engine: gitEngine, gitDirectory: info.gitDirectory)
            heads[remote.name] = Set(
                output.stdoutText.split(separator: "\n").compactMap { line in
                    line.split(separator: "\t", maxSplits: 1).last.map(String.init)
                })
        }
        // Read branch configuration directly: upstream atoms can be empty when a narrow fetch
        // refspec excludes the configured merge ref, even though that branch exists on the server.
        let config = try await gitEngine.run(
            GitCommand(
                ["config", "-z", "--get-regexp", #"^branch\..*\.(remote|merge)$"#],
                in: workingDirectory, kind: .read, acceptedExitCodes: [0, 1]))
        var branchRemotes: [String: String] = [:]
        var branchMerges: [String: Set<String>] = [:]
        for record in config.stdout.split(separator: 0) {
            let pair = record.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(decoding: pair[0].dropFirst("branch.".utf8.count), as: UTF8.self)
            let value = String(decoding: pair[1], as: UTF8.self)
            if key.hasSuffix(".remote") {
                branchRemotes[String(key.dropLast(".remote".count))] = value
            } else if key.hasSuffix(".merge") {
                branchMerges[String(key.dropLast(".merge".count)), default: []].insert(value)
            }
        }
        let locals = try await gitEngine.run(
            GitCommand(["for-each-ref", "--format=%(refname)", "refs/heads/"], in: workingDirectory, kind: .read))
        return locals.stdoutText.split(separator: "\n").compactMap { ref in
            let name = String(ref.dropFirst("refs/heads/".count))
            if heads.values.contains(where: { $0.contains(String(ref)) }) { return nil }
            if let remote = branchRemotes[name] {
                // Local upstreams and removed/unverifiable remotes are kept conservatively.
                guard let upstreamHeads = heads[remote], let merges = branchMerges[name], !merges.isEmpty else {
                    return nil
                }
                if !upstreamHeads.isDisjoint(with: merges) { return nil }
            } else if branchMerges[name] != nil {
                return nil
            }
            return name
        }.sorted()
    }

    public func prepareBranchCleanup(context: ExecContext) async throws(GitCoreError) -> BranchCleanupPlan {
        let expected = try await captureState()
        let candidates = try await branchesWithoutRemote(context: context)
        guard expected.head != nil else {
            return BranchCleanupPlan(branches: [], kept: candidates, expected: expected)
        }
        let worktrees = try await gitEngine.run(
            GitCommand(["worktree", "list", "--porcelain"], in: workingDirectory, kind: .read))
        let checkedOut = Set(
            worktrees.stdoutText.split(separator: "\n").filter { $0.hasPrefix("branch ") }
                .map { String($0.dropFirst("branch refs/heads/".count)) })
        let mergedOutput = try await gitEngine.run(
            GitCommand(
                ["for-each-ref", "--merged=HEAD", "--format=%(refname)", "refs/heads/"],
                in: workingDirectory, kind: .read))
        let merged = Set(mergedOutput.stdoutText.split(separator: "\n").map(String.init))
        var branches: [String] = []
        var kept: [String] = []
        for name in candidates {
            if name != expected.branch, !checkedOut.contains(name), merged.contains("refs/heads/\(name)") {
                branches.append(name)
            } else {
                kept.append(name)
            }
        }
        try await Self.ensureCurrent(expected, engine: gitEngine, in: workingDirectory, gitDirectory: info.gitDirectory)
        return BranchCleanupPlan(branches: branches, kept: kept, expected: expected)
    }

    public func deleteLocalBranches(
        _ plan: BranchCleanupPlan, token: ConfirmationToken, context: ExecContext
    ) async throws(GitCoreError) {
        try token.verify(.deleteLocalBranches(names: plan.branches))
        guard !plan.branches.isEmpty else { return }
        // Recheck the cloud before taking the write gate; a failed check never authorizes deletion.
        let eligible = Set(try await branchesWithoutRemote(context: context))
        guard plan.branches.allSatisfy(eligible.contains) else {
            throw .refused(summary: "A branch now exists on a remote. Review local branch cleanup again.")
        }
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Clean up local branches", invalidating: [.refs, .config]) {
            () throws(GitCoreError) in
            try await Self.ensureCurrent(plan.expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            // Git protects unmerged branches and branches checked out in any worktree, even if those
            // conditions changed since the preview. Report any refusal rather than claiming full success.
            _ = try await Self.runClassified(
                GitCommand(["branch", "-d", "--"] + plan.branches, in: directory, kind: .write),
                engine: engine, gitDirectory: gitDirectory)
        }
    }
}
