import Foundation

public struct LostCommit: Identifiable, Sendable, Equatable {
    public let oid: ObjectID
    public let subject: String
    public let timestamp: Int64
    public let looksLikeStash: Bool
    public var id: ObjectID { oid }
}

public struct LostCommitResult: Sendable {
    public let commits: [LostCommit]
    public let truncated: Bool
}

extension RepositoryHandle {
    /// Explicit, cancellable read. Never creates lost-found files or backup refs. A damaged object store
    /// reports fsck's error rather than claiming that an incomplete scan found every lost commit.
    public nonisolated func findUnreachable(
        limit: Int = 2000, progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> LostCommitResult {
        guard (1...2000).contains(limit) else { throw .refused(summary: "Choose a lost-commit limit from 1 to 2000.") }
        progress?.yield(OperationProgress(phase: "Checking unreachable objects"))
        let sink = ProgressSink(progress)
        var command = GitCommand(
            ["fsck", "--unreachable", "--no-reflogs", "--no-lost-found", "--progress"],
            in: workingDirectory, kind: .read, timeout: nil, stdoutLimit: 64 * 1024 * 1024)
        command.stderrObserver = sink.observer
        let output = try await gitEngine.run(command)
        if Task.isCancelled { throw .cancelled }
        var ids: [ObjectID] = []
        var seen: Set<ObjectID> = []
        var truncated = false
        for line in output.stdout.split(separator: 0x0A) {
            let fields = line.split(separator: 0x20)
            guard fields.count == 3, fields[0].elementsEqual("unreachable".utf8),
                fields[1].elementsEqual("commit".utf8), let oid = ObjectID(hex: fields[2]), !seen.contains(oid)
            else { continue }
            if ids.count < limit {
                seen.insert(oid)
                ids.append(oid)
            } else {
                truncated = true
            }
        }
        guard !ids.isEmpty else { return LostCommitResult(commits: [], truncated: false) }
        progress?.yield(OperationProgress(phase: "Reading lost commits", completed: ids.count))
        let format = try await objectFormat()
        let input = ids.map { $0.hex(format) }.joined(separator: "\n") + "\n"
        let metadata = try await gitEngine.run(
            GitCommand(
                ReadOnlyPolicy.configOverrides + [
                    "log", "--no-walk=unsorted", "--no-show-signature", "--no-decorate", "-z",
                    "--format=%H%x00%P%x00%ct%x00%s", "--stdin", "--",
                ], in: workingDirectory, kind: .read, stdoutLimit: 16 * 1024 * 1024, stdin: Array(input.utf8)))
        var fields = metadata.stdout.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count == ids.count * 4 else {
            throw .internalError(summary: "Git returned incomplete lost-commit details.")
        }
        var commits: [LostCommit] = []
        for index in stride(from: 0, to: fields.count, by: 4) {
            if Task.isCancelled { throw .cancelled }
            guard let oid = ObjectID(hex: fields[index]),
                let timestamp = Int64(String(decoding: fields[index + 2], as: UTF8.self))
            else { throw .internalError(summary: "Git returned invalid lost-commit details.") }
            let subject = String(decoding: fields[index + 3], as: UTF8.self)
            let parents = fields[index + 1].split(separator: 0x20).count
            let stash = (2...3).contains(parents) && (subject.hasPrefix("WIP on ") || subject.hasPrefix("On "))
            commits.append(LostCommit(oid: oid, subject: subject, timestamp: timestamp, looksLikeStash: stash))
        }
        commits.sort { $0.timestamp == $1.timestamp ? $0.oid < $1.oid : $0.timestamp > $1.timestamp }
        return LostCommitResult(commits: commits, truncated: truncated)
    }
}
