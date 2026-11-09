import Dispatch
import Foundation
import GitCore
import Observation
import os

/// What a tab's status dot shows (design §3.1). Color is never the only signal: `description` feeds
/// tooltips and VoiceOver.
public enum StatusDot: Sendable, Equatable {
    case clean
    case notLoaded
    case changes
    case operation
    case danger

    public var description: String {
        switch self {
        case .clean: "No local changes"
        case .notLoaded: "Not loaded yet"
        case .changes: "Local changes"
        case .operation: "Operation in progress"
        case .danger: "Needs attention"
        }
    }
}

/// Why a refresh happens (diagnostics and tests).
public enum RefreshReason: Sendable, Equatable {
    case initialLoad, activation, fileSystem, user
}

/// One repository tab's live state (design §4.1). Owns the `RepositoryHandle` and, while active, the
/// FSEvents watcher. Frequently changing values (`status`) and stable ones (`info`) are separate
/// properties so Observation invalidates narrowly.
@MainActor @Observable
public final class RepositorySession {
    public enum Lifecycle: Sendable, Equatable {
        /// Restored but never shown: no handle, no watcher.
        case unloaded
        case loading
        /// Visible: watcher running, refreshes on events.
        case active
        /// Hidden: watcher stopped, work cancelled, last state kept for instant re-display.
        case inactive
        /// Inactive and caches dropped under memory pressure.
        case suspended
        case closed
    }

    public let path: String
    public private(set) var lifecycle: Lifecycle = .unloaded
    public private(set) var info: RepositoryInfo?
    public private(set) var status: RepositoryStatus?
    public private(set) var error: GitCoreError?
    /// Number of completed status refreshes (diagnostics: churn measurements, tests).
    public private(set) var refreshCount = 0
    /// The tab's history view state; created with the handle, started by the graph view (so it can apply
    /// the tab's persisted scope first).
    public private(set) var history: HistoryController?

    /// Mutations this session started that have not finished (running or queued behind the write gate).
    /// The UI disables conflicting actions while non-empty (design §4.7). Phase 4 lifts this into
    /// OperationCenter.
    public private(set) var pendingWrites: [String] = []
    public var isBusy: Bool { !pendingWrites.isEmpty || operations.isBusy }

    /// Activity of this repository (Phase 4): running and recent operations.
    public let operations = OperationCenter()
    /// The in-progress merge/rebase/… with banner details; refreshed by FSEvents and after operations.
    public internal(set) var operationState: RepoOperationState = .clean
    /// `stash@{n}` entries, newest first; `nil` until first requested (lazy, design §3.11).
    public internal(set) var stashes: [StashEntry]?
    @ObservationIgnored var operationStateTask: Task<Void, Never>?
    @ObservationIgnored var stashTask: Task<Void, Never>?

    /// Called on the main actor after `info`, `status` or `error` change (tab title/dot, recents).
    @ObservationIgnored public var onChange: (@MainActor (RepositorySession) -> Void)?

    @ObservationIgnored private let engine: GitEngine
    @ObservationIgnored private let watchesFileSystem: Bool
    @ObservationIgnored private(set) var handle: RepositoryHandle?
    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInvalidation: Set<InvalidationKind> = []
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var writeSequence: UInt64 = 0

    private static let log = Logger(subsystem: "jit.app", category: "session")

    /// - Parameter handle: an already opened handle (the open flow discovers once, not twice).
    public init(path: String, engine: GitEngine, handle: RepositoryHandle? = nil, watchesFileSystem: Bool = true) {
        self.path = path
        self.engine = engine
        self.watchesFileSystem = watchesFileSystem
        self.handle = handle
        self.info = handle?.info
        if let handle { history = HistoryController(handle: handle) }
    }

    public var isWatching: Bool { watcher?.isRunning ?? false }
    public var hasHandle: Bool { handle != nil }

    public var statusDot: StatusDot {
        if error != nil { return .danger }
        guard let status else { return .notLoaded }
        if let summary = status.summary, summary.conflicted > 0 { return .danger }
        if status.operation != .none { return .operation }
        if let summary = status.summary, !summary.isClean { return .changes }
        return .clean
    }

    /// Shows the tab: loads on first use, otherwise restarts watching and revalidates once.
    public func activate() {
        switch lifecycle {
        case .closed, .active, .loading:
            return
        case .unloaded, .inactive, .suspended:
            guard handle != nil, error == nil else {
                load()
                return
            }
            lifecycle = .active
            startWatching()
            scheduleRefresh(InvalidationKind.allCases, reason: .activation)
            history?.activate()
        }
    }

    /// Hides the tab: stops watching and cancels in-flight work (which kills its Git processes).
    public func deactivate() {
        switch lifecycle {
        case .loading, .active:
            stopWatching()
            loadTask?.cancel()
            loadTask = nil
            cancelRefresh()
            history?.deactivate()
            lifecycle = .inactive
        default:
            return
        }
    }

    /// Memory pressure: an inactive session drops its caches but keeps what the tab shows.
    public func suspend() {
        guard lifecycle == .inactive else { return }
        lifecycle = .suspended
        if let handle { Task { await handle.releaseCaches() } }
    }

    public func close() {
        stopWatching()
        loadTask?.cancel()
        loadTask = nil
        cancelRefresh()
        history?.close()
        history = nil
        handle = nil
        lifecycle = .closed
    }

    /// Repository ▸ Refresh, and Retry after an error.
    public func reload() {
        guard lifecycle != .closed else { return }
        if handle == nil || error != nil {
            stopWatching()
            cancelRefresh()
            history?.close()
            history = nil
            handle = nil
            load()
        } else {
            scheduleRefresh(InvalidationKind.allCases, reason: .user)
            history?.refsMayHaveChanged()
        }
    }

    /// Waits for the current load/refresh work (tests, benchmarks).
    public func settle() async {
        while let task = loadTask ?? refreshTask {
            await task.value
            if loadTask == nil, refreshTask == nil { break }
        }
    }

    // MARK: - Mutations (P3.1)

    /// Stages whole paths through the handle's write gate, then refreshes status.
    public func stage(_ paths: [String]) async throws(GitCoreError) {
        try await write("Stage") { handle throws(GitCoreError) in try await handle.stage(paths) }
    }

    /// Unstages whole paths through the handle's write gate, then refreshes status.
    public func unstage(_ paths: [String]) async throws(GitCoreError) {
        try await write("Unstage") { handle throws(GitCoreError) in try await handle.unstage(paths) }
    }

    /// Discards working-tree changes of whole files (P3.2). Tokens come from `discardToken(for:)` taken
    /// when the user was shown what would be lost; `hooks` default to the recovery store and the Trash.
    public func discard(_ items: [DiscardItem], hooks: DiscardHooks? = nil) async throws(GitCoreError)
        -> DiscardOutcome
    {
        let repository = info?.topLevel ?? path
        let hooks = hooks ?? RecoveryStore().discardHooks(repository: repository, branch: status?.branch.head)
        return try await write("Discard") { handle throws(GitCoreError) in try await handle.discard(items, hooks: hooks)
        }
    }

    /// Applies a line selection (P3.4). Discards keep a recovery copy in the recovery store first.
    public func apply(_ request: SelectionRequest, recovery: RecoveryStore = RecoveryStore()) async throws(GitCoreError)
        -> ApplyOutcome
    {
        let repository = info?.topLevel ?? path
        let hooks = recovery.discardHooks(repository: repository, branch: status?.branch.head)
        return try await write("Apply") { handle throws(GitCoreError) in try await handle.apply(request, hooks: hooks) }
    }

    /// Commits (P3.10). Refreshes status and history afterwards (refs moved).
    public func commit(_ request: CommitRequest) async throws(GitCoreError) -> CommitOutcome {
        defer { history?.refsMayHaveChanged() }
        return try await write("Commit", refresh: Set(InvalidationKind.allCases)) { handle throws(GitCoreError) in
            try await handle.commit(request)
        }
    }

    /// Facts the composer shows (read-only).
    public func commitContext() async -> CommitContext {
        guard let handle else { return CommitContext() }
        return CommitContext(
            headMessage: try? await handle.headMessage(), headAuthor: try? await handle.headAuthor(),
            headIsInUpstream: (try? await handle.headIsInUpstream()) ?? false,
            configuredEmail: try? await handle.configuredEmail())
    }

    /// Reads a diff through the session's handle (read-only; never takes the write gate).
    public func openDiff(_ target: DiffTarget, options: DiffOptions = DiffOptions()) async throws(GitCoreError)
        -> DiffDocument
    {
        guard let handle else { throw .cancelled }
        return try await handle.openDiff(target, options: options)
    }

    /// The current state of `path`, for a later `discard` (read-only).
    public func discardToken(for path: String) async throws(GitCoreError) -> DiscardToken {
        guard let handle else { throw .cancelled }
        return try await handle.discardToken(for: path)
    }

    @discardableResult
    func write<T: Sendable>(
        _ description: String, refresh: Set<InvalidationKind> = [.index, .worktree],
        _ body: @Sendable (RepositoryHandle) async throws(GitCoreError) -> T
    ) async throws(GitCoreError) -> T {
        guard let handle, lifecycle != .closed else { throw .cancelled }
        writeSequence &+= 1
        let token = "\(description) #\(writeSequence)"
        pendingWrites.append(token)
        defer {
            if let index = pendingWrites.firstIndex(of: token) { pendingWrites.remove(at: index) }
            // Refresh whether or not Git succeeded: a failed command may still have changed something.
            scheduleRefresh(refresh, reason: .user)
        }
        return try await body(handle)
    }

    // MARK: - Loading and refreshing

    private func load() {
        lifecycle = .loading
        error = nil
        loadTask?.cancel()
        let url = URL(fileURLWithPath: path)
        loadTask = Task { [engine] in
            do throws(GitCoreError) {
                let handle = try await engine.openRepository(at: url)
                guard !Task.isCancelled else { return }
                self.handle = handle
                self.info = handle.info
                if self.history == nil { self.history = HistoryController(handle: handle) }
                self.onChange?(self)
                // Watch before the first status so nothing changed during it is missed (events arriving
                // meanwhile queue a refresh that coalesces with this one).
                self.startWatching()
                let status = try await handle.status()
                guard !Task.isCancelled else { return }
                self.apply(status)
                self.lifecycle = .active
                // Requests made before the handle existed (stash list for the command bar) run now.
                if self.stashes == nil { self.loadStashes() }
                self.loadTask = nil
            } catch .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.stopWatching()
                self.fail(error)
                self.lifecycle = .active
                self.loadTask = nil
            }
        }
    }

    /// One refresh in flight plus at most one queued; invalidations accumulate while one runs.
    func scheduleRefresh(_ kinds: some Sequence<InvalidationKind>, reason: RefreshReason) {
        pendingInvalidation.formUnion(kinds)
        guard refreshTask == nil else {
            refreshQueued = true
            return
        }
        guard let handle else { return }
        let invalidation = pendingInvalidation
        pendingInvalidation = []
        refreshTask = Task {
            let started = ContinuousClock.now
            await handle.invalidate(invalidation)
            do throws(GitCoreError) {
                let status = try await handle.status()
                if !Task.isCancelled { self.apply(status) }
            } catch .cancelled {
            } catch {
                if !Task.isCancelled { self.fail(error) }
            }
            guard !Task.isCancelled else { return }
            if self.refreshQueued {
                // Churn (e.g. a build writing thousands of files): before the queued refresh, rest as long as
                // the last one took (≤ 1 s), so Git runs at most about half the time. One-shot and cancellable.
                let rest = min(ContinuousClock.now - started, .seconds(1))
                try? await Task.sleep(for: rest)
                guard !Task.isCancelled else { return }
            }
            self.refreshTask = nil
            if self.refreshQueued {
                self.refreshQueued = false
                self.scheduleRefresh([], reason: reason)
            }
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshQueued = false
    }

    private func apply(_ newStatus: RepositoryStatus) {
        refreshCount += 1
        if newStatus.operation != status?.operation
            || (newStatus.summary?.conflicted ?? 0) != (status?.summary?.conflicted ?? 0)
        {
            refreshOperationState()
        }
        Self.log.debug(
            "status refresh #\(self.refreshCount, privacy: .public) revision \(newStatus.revision, privacy: .public)")
        if error != nil { error = nil }
        if newStatus != status { status = newStatus }
        onChange?(self)
    }

    private func fail(_ newError: GitCoreError) {
        Self.log.error("Repository error: \(newError.summary, privacy: .public)")
        error = newError
        onChange?(self)
    }

    // MARK: - Watching

    private func startWatching() {
        guard watchesFileSystem, lifecycle == .active || lifecycle == .loading, watcher == nil, let info else { return }
        let watcher = RepositoryWatcher(layout: RepositoryLayout(info)) { [weak self] batch in
            Task { @MainActor in self?.handle(batch) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func handle(_ batch: RepositoryWatcher.Batch) {
        guard lifecycle == .active || lifecycle == .loading, watcher != nil else { return }
        if batch.rootChanged, !FileManager.default.fileExists(atPath: path) {
            stopWatching()
            cancelRefresh()
            fail(.pathNotFound(path: path))
            return
        }
        scheduleRefresh(batch.kinds, reason: .fileSystem)
        if !batch.kinds.isDisjoint(with: [.refs, .head]) { history?.refsMayHaveChanged() }
        if !batch.kinds.isDisjoint(with: [.operationState, .index, .head]) { refreshOperationState() }
        if batch.kinds.contains(.refs) { refreshStashesIfLoaded() }
    }
}

/// Event-driven memory-pressure notifications (no timer). The app suspends inactive sessions.
@MainActor
public final class MemoryPressureMonitor {
    private let source: any DispatchSourceMemoryPressure

    public init(handler: @escaping @MainActor () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.activate()
    }

    isolated deinit { source.cancel() }
}

/// What the commit composer needs to know about HEAD and configuration.
public struct CommitContext: Sendable, Equatable {
    public var headMessage: String?
    public var headAuthor: GitIdentity?
    public var headIsInUpstream = false
    public var configuredEmail: String?

    public init(
        headMessage: String? = nil, headAuthor: GitIdentity? = nil, headIsInUpstream: Bool = false,
        configuredEmail: String? = nil
    ) {
        self.headMessage = headMessage
        self.headAuthor = headAuthor
        self.headIsInUpstream = headIsInUpstream
        self.configuredEmail = configuredEmail
    }
}
