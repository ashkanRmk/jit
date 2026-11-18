import Darwin
import Foundation

extension RepositoryHandle {
    public func resetPreview(to commit: String, mode: ResetMode) async throws(GitCoreError) -> ResetPreview {
        try Self.requireObjectID(commit)
        _ = try requireWorkingTree()
        let resolved = try await runRead(
            ["rev-parse", "--verify", "--end-of-options", commit + "^{commit}"], limit: 256)
        let target = String(decoding: resolved, as: UTF8.self).trimmingCharacters(in: .newlines)
        try Self.requireObjectID(target)
        let (snapshot, changes) = try await resetSnapshot(mode: mode)
        guard let head = snapshot.state.head else {
            throw .refused(summary: "Create a first commit before resetting this branch.")
        }
        let obstructions =
            mode == .hard || mode == .keep ? try await resetObstructions(target: target, index: snapshot.index) : []
        let removed = try await resetCount([head, "^" + target])
        let unpublished = try await resetCount([head, "^" + target], excludingRemotes: true)
        let excluded = Set(snapshot.references.filter { $0.key != snapshot.state.headRef }.values)
        let revisions = [head, "^" + target] + excluded.sorted().map { "^" + $0 }
        let unreachable = try await resetCount(revisions)
        var summaries: [CommitSummary] = []
        if unreachable > 0 {
            let input = revisions.joined(separator: "\n") + "\n"
            let output = try await gitEngine.run(
                GitCommand(
                    ReadOnlyPolicy.configOverrides + [
                        "log", "-z", "--no-show-signature", "--no-decorate", "-n", "5", "--format=%H%x00%s", "--stdin",
                        "--",
                    ], in: workingDirectory, kind: .read, stdoutLimit: 2 * 1024 * 1024, stdin: Array(input.utf8)))
            var fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
            if fields.last?.isEmpty == true { fields.removeLast() }
            guard fields.count % 2 == 0 else {
                throw .internalError(summary: "Git returned an incomplete reset preview.")
            }
            for index in stride(from: 0, to: fields.count, by: 2) {
                summaries.append(
                    CommitSummary(
                        oid: String(decoding: fields[index], as: UTF8.self),
                        subject: String(decoding: fields[index + 1], as: UTF8.self)))
            }
        }
        let (after, _) = try await resetSnapshot(mode: mode)
        guard snapshot == after else {
            throw .staleSnapshot(summary: "The repository changed while preparing reset. Refresh the preview.")
        }
        return ResetPreview(
            target: target, mode: mode, previousHead: head, branch: snapshot.state.branch,
            localChanges: changes, obstructingPaths: obstructions, removedCount: removed,
            unreachableCount: unreachable, unreachableCommits: summaries, publishedCount: removed - unpublished,
            snapshot: snapshot)
    }

    func resetSnapshot(mode: ResetMode) async throws(GitCoreError) -> (ResetSnapshot, [ResetChange]) {
        let root = try requireWorkingTree()
        let state = try await captureState()
        guard state.operation == .none else {
            throw .refused(summary: "Finish or abort the current Git operation before resetting.")
        }
        let index = try await runRead(["ls-files", "--stage", "-v", "-z"], limit: 64 * 1024 * 1024)
        if mode == .hard || mode == .keep {
            guard index.split(separator: 0).allSatisfy({ $0.first == UInt8(ascii: "H") }) else {
                throw .refused(
                    summary:
                        "Reset cannot safely preview skip-worktree or assume-unchanged entries. Clear those flags or use Git directly."
                )
            }
        }
        let bytes = try await runRead(
            [
                "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all",
                "--ignore-submodules=none",
            ], limit: 64 * 1024 * 1024)
        let status = try StatusParser.parse(bytes, revision: 0)
        var changes: [ResetChange] = []
        var files: [String: ResetFileState] = [:]
        guard status.entries.count <= 100_000 else {
            throw .refused(summary: "Too many local changes to safely preview reset.")
        }
        for index in 0..<status.entries.count {
            if Task.isCancelled { throw .cancelled }
            guard status.entries.kind(at: index) != .unmerged else {
                throw .refused(summary: "Resolve or abort the conflicts before resetting.")
            }
            let raw = status.entries.pathBytes(at: index)
            let path = try Self.resetPath(raw)
            let file = try ResetFileState.read(path, root: root)
            files[path] = file
            if let old = status.entries.originalPath(at: index) {
                files[old] = try ResetFileState.read(old, root: root)
            }
            changes.append(
                ResetChange(
                    path: path, staged: status.entries.hasStagedChange(at: index),
                    unstaged: status.entries.hasUnstagedChange(at: index),
                    untracked: status.entries.kind(at: index) == .untracked,
                    isSubmodule: status.entries.isSubmodule(at: index),
                    cannotStash: status.entries.isSubmodule(at: index) || file.type == UInt16(S_IFDIR)
                        || ![0, UInt16(S_IFREG), UInt16(S_IFLNK)].contains(file.type)))
        }
        let refBytes = try await runRead(
            ["for-each-ref", "--format=%(refname)%00%(objectname)"], limit: 64 * 1024 * 1024)
        var refs: [String: String] = [:]
        for line in refBytes.split(separator: 0x0A) {
            let fields = line.split(separator: 0)
            guard fields.count == 2 else { throw .internalError(summary: "Couldn't read reset reference state.") }
            refs[String(decoding: fields[0], as: UTF8.self)] = String(decoding: fields[1], as: UTF8.self)
        }
        guard try await captureState() == state else {
            throw .staleSnapshot(summary: "The repository changed while reading reset state.")
        }
        return (
            ResetSnapshot(root: root, state: state, index: index, status: bytes, files: files, references: refs),
            changes.sorted { $0.path < $1.path }
        )
    }

    func resetObstructions(target: String, index: [UInt8]) async throws(GitCoreError) -> [String] {
        let root = try requireWorkingTree()
        var tracked: Set<String> = []
        for entry in index.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 0x09) else {
                throw .internalError(summary: "Couldn't read the reset index.")
            }
            tracked.insert(try Self.resetPath(entry[(tab + 1)...]))
        }
        let tree = try await runRead(["ls-tree", "-r", "-z", "--full-tree", target, "--"], limit: 64 * 1024 * 1024)
        var blocked: Set<String> = []
        for entry in tree.split(separator: 0) {
            if Task.isCancelled { throw .cancelled }
            guard let tab = entry.firstIndex(of: 0x09) else {
                throw .internalError(summary: "Couldn't read the reset target tree.")
            }
            if entry.prefix(6).elementsEqual("160000".utf8) { continue }  // never recurse into submodules
            let path = try Self.resetPath(entry[(tab + 1)...])
            let parts = path.split(separator: "/")
            var parentObstructs = false
            if parts.count > 1 {
                for count in 1..<parts.count {
                    let parent = parts.prefix(count).joined(separator: "/")
                    let state = try ResetFileState.read(parent, root: root, hashContent: false)
                    if state.type != 0 && state.type != UInt16(S_IFDIR) {
                        if !tracked.contains(parent) { blocked.insert(parent) }
                        parentObstructs = true; break
                    }
                }
            }
            if parentObstructs { continue }
            let file = try ResetFileState.read(path, root: root, hashContent: false)
            if file.type == UInt16(S_IFDIR) || file.type != 0 && !tracked.contains(path) { blocked.insert(path) }
        }
        return blocked.sorted()
    }

    private func resetCount(_ revisions: [String], excludingRemotes: Bool = false) async throws(GitCoreError) -> Int {
        let output = try await gitEngine.run(
            GitCommand(
                ["rev-list", "--count"] + (excludingRemotes ? ["--not", "--remotes", "--not"] : []) + ["--stdin"],
                in: workingDirectory, kind: .read, stdoutLimit: 256,
                stdin: Array((revisions.joined(separator: "\n") + "\n").utf8)))
        guard let count = Int(output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 else {
            throw .internalError(summary: "Couldn't count reset history.")
        }
        return count
    }

    static func resetPath(_ bytes: ArraySlice<UInt8>) throws(GitCoreError) -> String {
        let path = String(decoding: bytes, as: UTF8.self)
        guard path.utf8.elementsEqual(bytes) else {
            throw .refused(summary: "A path cannot be displayed safely in the reset preview.")
        }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        try ResetFileState.validate(normalized)
        return normalized
    }
}
