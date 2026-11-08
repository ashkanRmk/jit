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

    /// Called on the main actor after `info`, `status` or `error` change (tab title/dot, recents).
    @ObservationIgnored public var onChange: (@MainActor (RepositorySession) -> Void)?

    @ObservationIgnored private let engine: GitEngine
    @ObservationIgnored private let watchesFileSystem: Bool
    @ObservationIgnored private var handle: RepositoryHandle?
    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInvalidation: Set<InvalidationKind> = []
    @ObservationIgnored private var refreshQueued = false

    private static let log = Logger(subsystem: "jit.app", category: "session")

    /// - Parameter handle: an already opened handle (the open flow discovers once, not twice).
    public init(path: String, engine: GitEngine, handle: RepositoryHandle? = nil, watchesFileSystem: Bool = true) {
        self.path = path
        self.engine = engine
        self.watchesFileSystem = watchesFileSystem
        self.handle = handle
        self.info = handle?.info
    }

    public var isWatching: Bool { watcher?.isRunning ?? false }
    public var hasHandle: Bool { handle != nil }

    public var statusDot: StatusDot {
        if error != nil { return .danger }
        guard let status else { return info == nil ? .notLoaded : .clean }
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
        handle = nil
        lifecycle = .closed
    }

    /// Repository ▸ Refresh, and Retry after an error.
    public func reload() {
        guard lifecycle != .closed else { return }
        if handle == nil || error != nil {
            stopWatching()
            cancelRefresh()
            handle = nil
            load()
        } else {
            scheduleRefresh(InvalidationKind.allCases, reason: .user)
        }
    }

    /// Waits for the current load/refresh work (tests, benchmarks).
    public func settle() async {
        while let task = loadTask ?? refreshTask {
            await task.value
            if loadTask == nil, refreshTask == nil { break }
        }
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
                self.onChange?(self)
                let status = try await handle.status()
                guard !Task.isCancelled else { return }
                self.apply(status)
                self.lifecycle = .active
                self.loadTask = nil
                self.startWatching()
            } catch .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(error)
                self.lifecycle = .active
                self.loadTask = nil
            }
        }
    }

    /// One refresh in flight plus at most one queued; invalidations accumulate while one runs.
    private func scheduleRefresh(_ kinds: some Sequence<InvalidationKind>, reason: RefreshReason) {
        pendingInvalidation.formUnion(kinds)
        guard refreshTask == nil else {
            refreshQueued = true
            return
        }
        guard let handle else { return }
        let invalidation = pendingInvalidation
        pendingInvalidation = []
        refreshTask = Task {
            await handle.invalidate(invalidation)
            do throws(GitCoreError) {
                let status = try await handle.status()
                if !Task.isCancelled { self.apply(status) }
            } catch .cancelled {
            } catch {
                if !Task.isCancelled { self.fail(error) }
            }
            guard !Task.isCancelled else { return }
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
        guard watchesFileSystem, lifecycle == .active, watcher == nil, let info else { return }
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
        guard lifecycle == .active, watcher != nil else { return }
        if batch.rootChanged, !FileManager.default.fileExists(atPath: path) {
            stopWatching()
            cancelRefresh()
            fail(.pathNotFound(path: path))
            return
        }
        scheduleRefresh(batch.kinds, reason: .fileSystem)
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
