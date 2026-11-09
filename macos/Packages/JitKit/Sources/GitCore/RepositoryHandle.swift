import Foundation

/// What the UI shows about an open repository at one revision.
public struct RepositoryStatus: Sendable, Equatable {
    /// The handle's generation this result was computed at.
    public let revision: UInt64
    public let branch: BranchHeader
    /// `nil` for bare repositories (no working tree).
    public let summary: StatusSummary?
    public let operation: OperationState
}

/// The single serialization point for one open repository (ADR-0005, ADR-0007).
///
/// Caches the last status result under a generation counter. `invalidate(_:)` bumps the generation;
/// `status()` recomputes only when the cache is older than the current generation. Concurrent callers
/// share one in-flight computation; a request arriving while a stale computation runs waits for it and
/// then shares the next one (one in flight + one queued). Results older than the current generation are
/// never returned.
public actor RepositoryHandle {
    public nonisolated let info: RepositoryInfo
    private nonisolated let engine: GitEngine

    private var generation: UInt64 = 1
    private var cachedObjectFormat: ObjectFormat?
    /// LRU of commit details (design §4.6).
    nonisolated let detailsCache = DetailsCache()
    private var cachedStatus: RepositoryStatus?
    private var cachedSnapshot: StatusSnapshot?
    private var inFlight: (generation: UInt64, task: Task<Result<Computed, GitCoreError>, Never>)?
    /// Number of status computations started (tests, diagnostics).
    public private(set) var computations = 0
    /// Serializes every mutation of this repository (ADR-0027).
    var gate = WriteGate()
    /// Bumped after every mutation Jit runs (successful or not: a failed Git command may still have
    /// changed something).
    public private(set) var repoRevision = RepoRevision(0)

    struct Computed: Sendable {
        let status: RepositoryStatus
        let snapshot: StatusSnapshot?
    }

    init(info: RepositoryInfo, engine: GitEngine) {
        self.info = info
        self.engine = engine
    }

    /// Stable identity: the working tree root, or the git directory of a bare repository.
    public nonisolated var path: String { info.topLevel ?? info.gitDirectory }

    /// Where read commands run: the working tree, or the git directory of a bare repository.
    nonisolated var workingDirectory: String { info.topLevel ?? info.gitDirectory }
    nonisolated var gitEngine: GitEngine { engine }

    /// `sha1` or `sha256` (`rev-parse --show-object-format`), read once per handle.
    public func objectFormat() async throws(GitCoreError) -> ObjectFormat {
        if let cachedObjectFormat { return cachedObjectFormat }
        let output: ProcessOutput
        do {
            output = try await engine.run(
                GitCommand(["rev-parse", "--show-object-format"], in: workingDirectory, kind: .read, stdoutLimit: 256))
        } catch {
            throw RepositoryDiscovery.classify(error, path: workingDirectory)
        }
        let format: ObjectFormat = output.stdoutText.hasPrefix("sha256") ? .sha256 : .sha1
        cachedObjectFormat = format
        return format
    }

    /// Records a finished mutation: new revision, and status recomputes on next read.
    func mutationFinished(_ kinds: Set<InvalidationKind>) {
        repoRevision = RepoRevision(repoRevision.value &+ 1)
        invalidate(kinds)
    }

    public func invalidate(_ kinds: Set<InvalidationKind>) {
        guard !kinds.isEmpty else { return }
        generation &+= 1
    }

    /// Drops cached results (memory pressure). The next `status()` recomputes.
    public func releaseCaches() {
        cachedStatus = nil
        cachedSnapshot = nil
        detailsCache.removeAll()
    }

    /// The full parsed status from the last computation, if still cached (Phase 3 reads entries from it).
    public func lastSnapshot() -> StatusSnapshot? { cachedSnapshot }

    public func status() async throws(GitCoreError) -> RepositoryStatus {
        while true {
            if Task.isCancelled { throw .cancelled }
            if let cachedStatus, cachedStatus.revision == generation { return cachedStatus }
            let task: Task<Result<Computed, GitCoreError>, Never>
            let taskGeneration: UInt64
            if let inFlight {
                task = inFlight.task
                taskGeneration = inFlight.generation
            } else {
                taskGeneration = generation
                computations += 1
                let (engine, info) = (self.engine, self.info)
                task = Task { [weak self] in
                    let result = await Self.compute(engine: engine, info: info, revision: taskGeneration)
                    await self?.finish(generation: taskGeneration, result: result)
                    return result
                }
                inFlight = (taskGeneration, task)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            switch result {
            case .success(let computed) where computed.status.revision == generation:
                return computed.status
            case .success:
                continue  // stale: the generation moved on while Git ran; share the next computation
            case .failure(.cancelled) where !Task.isCancelled:
                continue  // another waiter cancelled the shared computation; this caller still wants a result
            case .failure(let error):
                if taskGeneration != generation { continue }
                throw error
            }
        }
    }

    private func finish(generation finished: UInt64, result: Result<Computed, GitCoreError>) {
        if inFlight?.generation == finished { inFlight = nil }
        if case .success(let computed) = result, finished == generation {
            cachedStatus = computed.status
            cachedSnapshot = computed.snapshot
        }
    }

    /// Exact status command. `--no-optional-locks` (plus `GIT_OPTIONAL_LOCKS=0` for reads) keeps
    /// status from refreshing `.git/index`, which would fire FSEvents and trigger another status.
    static let statusArguments = [
        "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal",
    ]

    @concurrent
    private static func compute(
        engine: GitEngine, info: RepositoryInfo, revision: UInt64
    ) async -> Result<Computed, GitCoreError> {
        do throws(GitCoreError) {
            guard let topLevel = info.topLevel else {
                // Bare: no working tree, so only HEAD and operation state.
                let head = try await RepositoryDiscovery(engine: engine, timeout: .seconds(30))
                    .resolveHead(in: info.gitDirectory)
                let status = RepositoryStatus(
                    revision: revision, branch: BranchHeader(head: head), summary: nil,
                    operation: OperationStateDetector.detect(gitDirectory: info.gitDirectory))
                return .success(Computed(status: status, snapshot: nil))
            }
            guard FileManager.default.fileExists(atPath: topLevel) else { throw .pathNotFound(path: topLevel) }
            let command = GitCommand(
                statusArguments, in: topLevel, kind: .read, timeout: .seconds(120), stdoutLimit: 128 * 1024 * 1024)
            let output: ProcessOutput
            do {
                output = try await engine.run(command)
            } catch {
                throw RepositoryDiscovery.classify(error, path: topLevel)
            }
            if Task.isCancelled { throw .cancelled }
            let snapshot = try Signposts.measure(Signposts.coreStatus) { () throws(GitCoreError) in
                try StatusParser.parse(output.stdout, revision: revision)
            }
            let status = RepositoryStatus(
                revision: revision, branch: snapshot.branch, summary: snapshot.summary,
                operation: OperationStateDetector.detect(gitDirectory: info.gitDirectory))
            return .success(Computed(status: status, snapshot: snapshot))
        } catch {
            return .failure(error)
        }
    }
}

extension BranchHeader {
    init(head: RepositoryInfo.Head) {
        switch head {
        case let .branch(name, commit): self.init(oid: commit, head: name)
        case let .detached(commit): self.init(oid: commit)
        case let .unborn(branch): self.init(head: branch)
        }
    }
}

/// A Git author or committer identity. Applied per invocation through `GIT_AUTHOR_*` /
/// `GIT_COMMITTER_*` (Phase 3); never written to any Git config file.
public struct GitIdentity: Sendable, Codable, Hashable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

extension GitEngine {
    /// Discovers the repository at `url` and returns its handle.
    public func openRepository(at url: URL) async throws(GitCoreError) -> RepositoryHandle {
        let info = try await discoverRepository(at: url)
        return RepositoryHandle(info: info, engine: self)
    }

    /// Reads `user.name` / `user.email` from the global Git configuration. Read-only (`git config
    /// --global --get`); Jit never writes global configuration.
    public func readGlobalIdentity() async throws(GitCoreError) -> (name: String?, email: String?) {
        func get(_ key: String) async throws(GitCoreError) -> String? {
            let output = try await run(
                GitCommand(
                    ["config", "--global", "--get", key], in: NSHomeDirectory(), kind: .read,
                    timeout: .seconds(10), stdoutLimit: 4096, acceptedExitCodes: [0, 1]))
            let value = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.exitCode == 0 && !value.isEmpty ? value : nil
        }
        return (try await get("user.name"), try await get("user.email"))
    }
}
