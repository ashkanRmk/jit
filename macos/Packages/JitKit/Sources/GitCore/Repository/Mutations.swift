import Foundation

// MARK: - Write gate

extension RepositoryHandle {
    /// What the write gate is running and what waits behind it.
    public func writeGateState() -> WriteGateState { gate.state }

    /// Runs `body` while holding the write gate: mutations run one at a time in arrival order, even across
    /// the suspension points inside `body` (ADR-0027). Reads (`status()`, diffs) never take the gate.
    /// A caller cancelled while queued leaves the queue and gets `.cancelled`; nothing ran.
    public func performExclusive<T: Sendable>(
        _ description: String,
        invalidating kinds: Set<InvalidationKind> = [.index, .worktree],
        _ body: @Sendable () async throws(GitCoreError) -> T
    ) async throws(GitCoreError) -> T {
        try await acquireGate(description)
        defer {
            mutationFinished(kinds)
            gate.release()
        }
        if Task.isCancelled { throw .cancelled }
        return try await body()
    }

    private func acquireGate(_ description: String) async throws(GitCoreError) {
        if Task.isCancelled { throw .cancelled }
        if gate.tryAcquire(description) { return }
        let ticket = gate.makeTicket()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.enqueue(ticket, description, continuation)
            }
        } onCancel: {
            Task { await self.cancelGateWaiter(ticket) }
        }
        guard acquired else { throw .cancelled }
    }

    private func cancelGateWaiter(_ ticket: UInt64) { gate.cancel(ticket) }
}

// MARK: - File-level stage / unstage (P3.1)

extension RepositoryHandle {
    /// Stages whole paths (`git add --all`): modifications, new files, deletions; for a rename made in the
    /// working tree pass both the old and the new path. Returns the revision after the mutation.
    @discardableResult
    public func stage(_ paths: [String]) async throws(GitCoreError) -> RepoRevision {
        let topLevel = try requireWorkingTree()
        guard !paths.isEmpty else { return repoRevision }
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        _ = try await performExclusive("Stage \(Self.describe(paths))") { () throws(GitCoreError) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.runPathspecCommand(
                ["add", "--all"], paths: paths, engine: engine, in: topLevel, gitDirectory: gitDirectory)
        }
        return repoRevision
    }

    /// Removes the staged changes of whole paths, keeping the working tree as it is. A staged new file
    /// becomes untracked again; on an unborn branch every staged path does. For a staged rename pass both
    /// paths (`StatusEntries.originalPath(at:)`).
    @discardableResult
    public func unstage(_ paths: [String]) async throws(GitCoreError) -> RepoRevision {
        let topLevel = try requireWorkingTree()
        guard !paths.isEmpty else { return repoRevision }
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        _ = try await performExclusive("Unstage \(Self.describe(paths))") { () throws(GitCoreError) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let hasHead = try await Self.headExists(engine: engine, in: topLevel)
            // `restore --staged` copies HEAD's version into the index (removing paths HEAD lacks). Without
            // a HEAD there is nothing to restore from, so the entries are removed from the index only;
            // `--cached` never touches the working tree, and `-f` skips the "staged content differs" guard
            // that exists to protect the working tree.
            let arguments =
                hasHead ? ["restore", "--staged"] : ["rm", "--cached", "-r", "-f", "-q"]
            try await Self.runPathspecCommand(
                arguments, paths: paths, engine: engine, in: topLevel, gitDirectory: gitDirectory)
        }
        return repoRevision
    }

    // MARK: Helpers

    nonisolated func requireWorkingTree() throws(GitCoreError) -> String {
        guard let topLevel = info.topLevel else {
            throw .internalError(summary: "This repository has no working tree.")
        }
        return topLevel
    }

    static func describe(_ paths: [String]) -> String {
        paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)”" : "\(paths.count) files"
    }

    static func refuseIfIndexLocked(gitDirectory: String) throws(GitCoreError) {
        let lock = gitDirectory + "/index.lock"
        if FileManager.default.fileExists(atPath: lock) { throw .indexLocked(path: lock) }
    }

    static func headExists(engine: GitEngine, in directory: String) async throws(GitCoreError) -> Bool {
        let output = try await engine.run(
            GitCommand(
                ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"], in: directory,
                kind: .read, stdoutLimit: 1024, acceptedExitCodes: [0, 1]))
        return output.exitCode == 0
    }

    /// Runs a pathspec command with paths on stdin (NUL-separated, so newlines and any byte survive; no
    /// argv length limit) and literal pathspecs (`*`, `:(…)` and leading dashes mean nothing special).
    static func runPathspecCommand(
        _ arguments: [String], paths: [String], engine: GitEngine, in directory: String, gitDirectory: String
    ) async throws(GitCoreError) {
        var input: [UInt8] = []
        for path in paths {
            input.append(contentsOf: path.utf8)
            input.append(0)
        }
        let command = GitCommand(
            ["--literal-pathspecs"] + arguments + ["--pathspec-from-file=-", "--pathspec-file-nul"],
            in: directory, kind: .write, timeout: .seconds(300), stdoutLimit: 1024 * 1024, stdin: input)
        do {
            _ = try await engine.run(command)
        } catch {
            throw mapWriteError(error, gitDirectory: gitDirectory)
        }
    }

    /// Git's "Unable to create '…/index.lock': File exists." becomes `.indexLocked`.
    static func mapWriteError(_ error: GitCoreError, gitDirectory: String) -> GitCoreError {
        if case let .processFailed(_, _, detail) = error, detail.contains("index.lock") {
            return .indexLocked(path: gitDirectory + "/index.lock")
        }
        return error
    }
}
