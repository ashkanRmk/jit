import Foundation
import os

/// Which commits a history view shows (design §3.3).
public enum HistoryScope: Sendable, Hashable, Codable {
    /// Local branches, remote branches, tags and HEAD.
    case all
    /// HEAD only.
    case current
    /// Local branches and HEAD.
    case local
    /// The given full ref names, plus HEAD.
    case refs([String])
    /// Only commits reachable from one ref (HEAD not added).
    case solo(String)
}

public struct HistoryQuery: Sendable, Hashable {
    public var scope: HistoryScope
    /// Path filter (file history). Passed after `--`.
    public var path: String?
    /// `--follow` (only honoured for a single file path).
    public var follow: Bool
    /// Full ref names pinned to the leftmost lanes, in order.
    public var pinned: [String]

    public init(scope: HistoryScope = .all, path: String? = nil, follow: Bool = false, pinned: [String] = []) {
        self.scope = scope
        self.path = path
        self.follow = follow
        self.pinned = pinned
    }

    /// Revision arguments (after `--end-of-options`).
    func revisions(refs: RefSnapshot) -> [String] {
        let head = refs.head.commit == nil ? [] : ["HEAD"]
        switch scope {
        case .all:
            return refs.refs.contains { $0.commit != nil } || !head.isEmpty
                ? ["--branches", "--remotes", "--tags"] + head : []
        case .current:
            return head
        case .local:
            return refs.locals.isEmpty && head.isEmpty ? [] : ["--branches"] + head
        case .refs(let names):
            return names + head
        case .solo(let name):
            return [name]
        }
    }

    /// The full `git` argument list (ADR-0023: display-only reads neutralise program-executing config).
    func arguments(refs: RefSnapshot, skip: Int) -> [String]? {
        let revisions = revisions(refs: refs)
        let options = revisions.filter { $0.hasPrefix("--") }
        let names = revisions.filter { !$0.hasPrefix("--") }
        guard !revisions.isEmpty else { return nil }
        var arguments =
            ReadOnlyPolicy.configOverrides + [
                "log", "--topo-order", "-z", "--format=\(LogParser.format)", "--no-color", "--no-decorate",
                "--no-show-signature", "--no-ext-diff", "--no-textconv",
            ]
        if skip > 0 { arguments.append("--skip=\(skip)") }
        if follow, path != nil { arguments.append("--follow") }
        arguments += options
        arguments.append("--end-of-options")
        arguments += names
        arguments.append("--")
        if let path { arguments.append(path) }
        return arguments
    }
}

/// Configuration overrides for read-only display invocations (ADR-0023): never run signature
/// verification, external diff drivers or textconv filters just to show history.
enum ReadOnlyPolicy {
    static let configOverrides = ["-c", "log.showSignature=false"]
}

/// Loads one history view on demand (design §4.2–§4.3, ADR-0010).
///
/// One long-lived `git log --topo-order` child is read only while `ensureLoaded` asks for rows; between
/// requests its stdout is not read, so Git blocks on the full pipe (zero CPU, no thread). Rows are laid
/// out as they arrive and appended to chunked columns; snapshots are immutable and cheap to publish.
public actor HistoryLoader {
    public nonisolated let query: HistoryQuery
    public nonisolated let refs: RefSnapshot

    private let engine: GitEngine
    private let directory: String
    private let gitDirectory: String
    private var builder = CommitStoreBuilder()
    private var layouter: LaneLayouter
    private var parser = LogParser()
    private var stream: ProcessStream?
    /// After a reader restart with `--skip`, the first record must be this commit (drift check).
    private var expectedFirst: ObjectID?
    private var target = 0
    private var readTask: Task<Void, Never>?
    private var failure: GitCoreError?
    private var complete = false
    private var closed = false
    private var headRow: Int?
    private let headCommit: ObjectID?
    private let isShallow: Bool
    public private(set) var snapshot: HistorySnapshot
    /// Reader processes started (tests, diagnostics).
    public private(set) var readerStarts = 0
    /// Bytes per pipe read (tests vary it to move record boundaries across reads).
    var readSizes: [Int] = [256 * 1024]
    private var readIndex = 0

    private static let signposter = OSSignposter(subsystem: "jit.performance", category: "history")

    public init(repository: RepositoryHandle, query: HistoryQuery, refs: RefSnapshot) {
        self.query = query
        self.refs = refs
        engine = repository.gitEngine
        directory = repository.workingDirectory
        gitDirectory = repository.info.commonDirectory
        isShallow = FileManager.default.fileExists(atPath: repository.info.commonDirectory + "/shallow")
        headCommit = refs.head.commit
        var pinnedTips: [ObjectID] = []
        for name in query.pinned {
            if let commit = refs.ref(named: name)?.commit { pinnedTips.append(commit) }
        }
        layouter = LaneLayouter(refs: refs, pinned: pinnedTips)
        snapshot = .empty(refs: refs)
    }

    /// Process id of the running reader (tests).
    public var readerProcess: pid_t? { stream?.processIdentifier }

    /// Ensures rows `0..<minRows` are loaded (or history ended) and returns the latest snapshot. Suspends
    /// without blocking a thread. Cancelling the calling task stops the read and kills the reader.
    public func ensureLoaded(_ minRows: Int) async throws(GitCoreError) -> HistorySnapshot {
        target = max(target, minRows)
        while builder.count < minRows && !complete {
            if closed { throw .cancelled }
            if let failure { throw failure }
            if Task.isCancelled { throw .cancelled }
            let task: Task<Void, Never>
            if let readTask {
                task = readTask
            } else {
                task = Task { await self.readUntilTarget() }
                readTask = task
            }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if Task.isCancelled { throw .cancelled }
        }
        if let failure, builder.count < minRows, !complete { throw failure }
        return snapshot
    }

    /// Stops reading and kills the reader process group. Loaded rows stay readable in `snapshot`.
    public func close() {
        closed = true
        readTask?.cancel()
        stream?.terminate()
        stream = nil
    }

    /// Kills the reader process (tab hidden, ADR-0010) but keeps loaded rows; the next `ensureLoaded`
    /// beyond them restarts it with `--skip`.
    public func suspendReader() {
        readTask?.cancel()
        stream?.terminate()
        stream = nil
        parser = LogParser()
    }

    /// Test hook: cycle through these read sizes.
    func setReadSizes(_ sizes: [Int]) {
        readSizes = sizes.isEmpty ? [256 * 1024] : sizes
    }

    /// Clears a read failure so the next `ensureLoaded` restarts the reader (Retry).
    public func resetFailure() {
        failure = nil
    }

    // MARK: - Reading

    private func readUntilTarget() async {
        defer { readTask = nil }
        let interval = Self.signposter.beginInterval("HistoryPage", "\(self.target) rows")
        defer { Self.signposter.endInterval("HistoryPage", interval) }
        do throws(GitCoreError) {
            while builder.count < target && !complete && !closed {
                let stream = try await currentStream()
                let size = readSizes[readIndex % readSizes.count]
                readIndex += 1
                guard let chunk = try await stream.read(maxBytes: size) else {
                    if parser.hasPartialRecord {
                        throw .internalError(summary: "Git's history output ended in the middle of a commit.")
                    }
                    complete = true
                    self.stream = nil
                    break
                }
                try ingest(chunk)
            }
        } catch {
            if !closed {
                // A cancelled read killed the reader; the next request restarts it with --skip.
                if error != .cancelled { failure = error }
            }
            stream?.terminate()
            stream = nil
            parser = LogParser()
        }
        publish()
    }

    private func currentStream() async throws(GitCoreError) -> ProcessStream {
        if let stream { return stream }
        let skip = max(0, builder.count - 1)
        guard let arguments = query.arguments(refs: refs, skip: skip) else {
            complete = true
            throw .cancelled  // nothing to read; caught as a non-failure
        }
        expectedFirst = builder.count > 0 ? lastOID() : nil
        let stream = try await engine.stream(GitCommand(arguments, in: directory, kind: .read, timeout: nil))
        readerStarts += 1
        self.stream = stream
        parser = LogParser()
        return stream
    }

    private func lastOID() -> ObjectID? {
        let chunks = builder.chunksForSnapshot()
        guard let last = chunks.last, last.count > 0 else { return nil }
        return last.oids[last.count - 1]
    }

    private func ingest(_ bytes: [UInt8]) throws(GitCoreError) {
        try parser.consume(bytes) { (record: borrowing LogParser.Record) throws(GitCoreError) in
            if let expected = expectedFirst {
                expectedFirst = nil
                guard record.oid == expected else {
                    throw .internalError(summary: "The history changed while it was loading. Reload to see it.")
                }
                return
            }
            let author = builder.internAuthor(name: record.name, email: record.email)
            layouter.layout(oid: record.oid, parents: record.parents, subject: record.subject)
            if record.oid == headCommit, headRow == nil { headRow = builder.count }
            builder.append(
                oid: record.oid, parents: record.parents, author: author, time: record.time, subject: record.subject,
                lane: layouter.output)
        }
    }

    private func publish() {
        snapshot = HistorySnapshot(
            chunks: builder.chunksForSnapshot(), count: builder.count, complete: complete, authors: builder.authors,
            format: refs.format, refs: refs, isShallow: isShallow, headRow: headRow)
    }
}
