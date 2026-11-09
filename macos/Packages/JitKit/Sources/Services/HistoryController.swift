import Foundation
import GitCore
import Observation
import os

/// Owns one tab's history view state (design §4.6): the `HistoryLoader`, the latest immutable
/// `HistorySnapshot` and the current refs. The graph table reads snapshots; it never sees the loader.
///
/// - Page requests coalesce: at most one in flight, the largest requested count wins.
/// - Refs changes (FSEvents → `refsMayHaveChanged`) update labels in place or reload in the background
///   and swap atomically (ADR-0024). While inactive, changes only mark the controller dirty.
/// - Hiding the tab kills the reader process (ADR-0010); loaded rows stay.
@MainActor @Observable
public final class HistoryController {
    public enum Update: Sendable, Equatable {
        /// Rows `from..<snapshot.count` were appended to the same history.
        case appended(from: Int)
        /// A different history (new query or reload): reload everything, map selection by id.
        case replaced
        /// Same rows, refs (labels, HEAD) changed: redraw visible rows.
        case labels
    }

    public private(set) var snapshot: HistorySnapshot
    public private(set) var refs: RefSnapshot?
    public private(set) var query: HistoryQuery
    /// A page request is running.
    public private(set) var isLoading = false
    /// The first page has taken longer than 150 ms (the UI shows a spinner).
    public private(set) var isSlow = false
    public private(set) var error: GitCoreError?
    /// Bumped on every replacement (tests, diagnostics).
    public private(set) var replacements = 0

    /// Called after `snapshot`/`refs` change, with what changed.
    @ObservationIgnored public var onUpdate: (@MainActor (Update) -> Void)?

    @ObservationIgnored private let handle: RepositoryHandle
    @ObservationIgnored private var loader: HistoryLoader?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var slowTask: Task<Void, Never>?
    @ObservationIgnored private var wanted = 0
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var refsDirty = false
    @ObservationIgnored private var refreshQueued = false

    public static let firstPage = 300
    public static let pageSize = 2000
    /// Load more when the visible range comes this close to the end.
    public static let prefetchDistance = 500

    private static let log = Logger(subsystem: "jit.app", category: "history")

    public init(handle: RepositoryHandle, query: HistoryQuery = HistoryQuery()) {
        self.handle = handle
        self.query = query
        snapshot = .empty()
    }

    public var repository: RepositoryHandle { handle }

    /// Reads refs and the first page.
    public func start() {
        guard loader == nil, refreshTask == nil else { return }
        reload(minimumRows: Self.firstPage)
    }

    /// Ensures at least `count` rows are (being) loaded. Coalesced.
    public func requestRows(_ count: Int) {
        guard let loader, error == nil, !snapshot.complete else { return }
        wanted = max(wanted, count)
        guard pageTask == nil, wanted > snapshot.count else { return }
        startPage(loader)
    }

    /// Loads until at least `count` rows exist (or history ends / fails). Awaits page reads; no polling.
    public func loadRows(atLeast count: Int) async {
        wanted = max(wanted, count)
        while snapshot.count < count, !snapshot.complete, error == nil, let loader {
            if pageTask == nil { startPage(loader) }
            guard let task = pageTask else { break }
            await task.value
            if Task.isCancelled { return }
        }
    }

    /// Called by the table when rows near `lastVisibleRow` are on screen.
    public func visibleRowsChanged(lastVisibleRow: Int) {
        if lastVisibleRow + Self.prefetchDistance >= snapshot.count {
            requestRows(snapshot.count + Self.pageSize)
        }
    }

    private func startPage(_ loader: HistoryLoader) {
        isLoading = true
        let target = wanted
        pageTask = Task { [weak self] in
            do throws(GitCoreError) {
                let next = try await loader.ensureLoaded(target)
                guard let self, self.loader === loader else { return }
                self.finishPage(next, loader: loader)
            } catch .cancelled {
                guard let self, self.loader === loader else { return }
                self.pageTask = nil
                self.isLoading = false
            } catch {
                guard let self, self.loader === loader else { return }
                Self.log.error("History page failed: \(error.summary, privacy: .public)")
                self.pageTask = nil
                self.isLoading = false
                self.error = error
            }
        }
    }

    private func finishPage(_ next: HistorySnapshot, loader: HistoryLoader) {
        pageTask = nil
        isLoading = false
        let previous = snapshot.count
        snapshot = next
        if next.count > previous || next.complete { onUpdate?(.appended(from: previous)) }
        if wanted > next.count, !next.complete { startPage(loader) }
    }

    // MARK: - Query

    public func setQuery(_ newQuery: HistoryQuery) {
        guard newQuery != query else { return }
        query = newQuery
        reload(minimumRows: Self.firstPage)
    }

    /// Retry after an error.
    public func retry() {
        error = nil
        reload(minimumRows: max(Self.firstPage, snapshot.count))
    }

    // MARK: - Refs changes (ADR-0024)

    /// HEAD or refs may have changed on disk.
    public func refsMayHaveChanged() {
        guard isActive else {
            refsDirty = true
            return
        }
        guard refreshTask == nil else {
            refreshQueued = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRefs()
            self.refreshTask = nil
            if self.refreshQueued {
                self.refreshQueued = false
                self.refsMayHaveChanged()
            }
        }
    }

    private func refreshRefs() async {
        let newRefs: RefSnapshot
        do throws(GitCoreError) {
            newRefs = try await handle.refs()
        } catch {
            return  // the status refresh reports repository errors
        }
        guard let oldRefs = refs else { return }
        switch HistoryInvalidation.decide(old: oldRefs, new: newRefs, history: snapshot, query: query) {
        case .unchanged:
            return
        case .labelsOnly:
            refs = newRefs
            onUpdate?(.labels)
        case .reload:
            await replace(refs: newRefs, minimumRows: max(Self.firstPage, min(snapshot.count, 5000)))
        }
    }

    // MARK: - Lifecycle

    /// Tab shown again. Refs are re-read once: the watcher was off while hidden, so changes made
    /// meanwhile produced no events.
    public func activate() {
        let wasInactive = !isActive
        isActive = true
        if refsDirty || (wasInactive && loader != nil) {
            refsDirty = false
            refsMayHaveChanged()
        }
    }

    /// Tab hidden: stop the reader (no CPU, no memory in Git); keep loaded rows.
    public func deactivate() {
        isActive = false
        pageTask?.cancel()
        pageTask = nil
        isLoading = false
        wanted = snapshot.count
        if let loader { Task { await loader.suspendReader() } }
    }

    public func close() {
        pageTask?.cancel()
        refreshTask?.cancel()
        slowTask?.cancel()
        if let loader { Task { await loader.close() } }
        loader = nil
    }

    // MARK: - Loading

    private func reload(minimumRows: Int) {
        pageTask?.cancel()
        pageTask = nil
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let refs: RefSnapshot
            do throws(GitCoreError) {
                refs = try await self.handle.refs()
            } catch .cancelled {
                return
            } catch {
                self.error = error
                self.refreshTask = nil
                return
            }
            await self.replace(refs: refs, minimumRows: minimumRows)
            self.refreshTask = nil
        }
    }

    /// Loads a new history in the background and swaps it in when its first rows are ready.
    private func replace(refs newRefs: RefSnapshot, minimumRows: Int) async {
        let replacement = HistoryLoader(repository: handle, query: query, refs: newRefs)
        let firstLoad = snapshot.count == 0 && loader == nil
        isLoading = true
        slowTask?.cancel()
        if firstLoad {
            slowTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, self.isLoading else { return }
                self.isSlow = true
            }
        }
        do throws(GitCoreError) {
            let first = try await replacement.ensureLoaded(minimumRows)
            if Task.isCancelled {
                await replacement.close()
                return
            }
            let old = loader
            loader = replacement
            refs = newRefs
            snapshot = first
            error = nil
            wanted = first.count
            replacements += 1
            isLoading = false
            isSlow = false
            slowTask?.cancel()
            if let old { Task { await old.close() } }
            if !isActive { await replacement.suspendReader() }
            onUpdate?(.replaced)
        } catch .cancelled {
            await replacement.close()
        } catch {
            await replacement.close()
            isLoading = false
            isSlow = false
            self.error = error
            if refs == nil { refs = newRefs }
            onUpdate?(.labels)
        }
    }
}
