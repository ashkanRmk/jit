import Foundation
import GitCore
import Observation
import Services
import os

/// The main window's state (ADR-0007): ordered tabs, the active tab, the reopen stack, and the stores.
/// Only the active tab's session runs, and only while the window is in the foreground.
@MainActor @Observable
public final class AppModel {
    /// Changes the AppKit window controller reacts to.
    public enum Change {
        case tabs
        case activeTab
        /// Title/branch/status of the active tab changed (window title, menus).
        case activeTabDetails
        /// Sessions whose caches were dropped; their cached views can go too.
        case suspended(Set<UUID>)
    }

    public struct ClosedTab {
        let record: SessionState.Tab
        let index: Int
    }

    public private(set) var tabs: [TabModel] = []
    public private(set) var activeTabID: UUID?

    public let engine: GitEngine
    public let preferences: PreferencesStore
    public let recents: RecentsStore
    public let profiles: ProfileStore
    /// Author pictures (Gravatar). Fetches nothing until the app installs a fetcher.
    public let avatars = AvatarStore(cacheDirectory: AvatarStore.defaultCacheDirectory())
    /// Releases, the change log and self-update (ADR-0051). Requests nothing until the app installs a fetcher.
    public let updates: UpdateService
    /// Profile authentication: exec contexts, Keychain, connectivity (Phase 5). Created on first use — never at
    /// launch (P6.4): `configureAccounts` runs once when it is created.
    @ObservationIgnored public lazy var accounts: AccountsService = {
        let service = AccountsService(profiles: profiles)
        isAccountsLoaded = true
        configureAccounts?(service)
        return service
    }()
    /// Window-level hooks for the accounts service (passphrase / host-key prompts), applied when it is created.
    @ObservationIgnored public var configureAccounts: ((AccountsService) -> Void)?
    /// Whether `accounts` exists yet (tests: launch must not create it).
    @ObservationIgnored public private(set) var isAccountsLoaded = false
    /// Unfinished commit messages per repository (P3.10).
    @ObservationIgnored public lazy var commitDrafts = CommitDrafts()
    public let layout: LayoutState

    @ObservationIgnored public private(set) var recentlyClosed: [ClosedTab] = []
    @ObservationIgnored public private(set) var isForeground = false
    @ObservationIgnored public var windowFrame: SessionState.WindowFrame?
    @ObservationIgnored public var onChange: ((Change) -> Void)?
    /// Presents an open failure (alert sheet); set by the window controller.
    @ObservationIgnored public var onOpenFailure: ((URL, GitCoreError) -> Void)?
    /// Opens the folder picker; set by the window controller.
    @ObservationIgnored public var presentOpenPanel: (() -> Void)?
    @ObservationIgnored private let sessionStore: SessionStore?
    @ObservationIgnored private let watchesFileSystem: Bool
    /// Opens in progress, keyed by the tab they replace (or the folder): concurrent opens of different folders
    /// all complete; a newer open for the same target supersedes the older one.
    @ObservationIgnored private var openTasks: [String: Task<Void, Never>] = [:]

    static let reopenCapacity = CacheLimits.reopenClosedTabs

    public init(
        engine: GitEngine, preferences: PreferencesStore, recents: RecentsStore, profiles: ProfileStore,
        sessionStore: SessionStore?, layout: LayoutState = LayoutState(), watchesFileSystem: Bool = true,
        updates: UpdateService = UpdateService(currentVersion: nil)
    ) {
        self.updates = updates
        self.engine = engine
        self.preferences = preferences
        self.recents = recents
        self.profiles = profiles
        self.sessionStore = sessionStore
        self.layout = layout
        self.watchesFileSystem = watchesFileSystem
        avatars.isEnabled = { [weak preferences] in preferences?.showsGravatarAvatars ?? false }
        updates.isAutomatic = { [weak preferences] in preferences?.updatesAutomatically ?? false }
    }

    public var activeTab: TabModel? { tabs.first { $0.id == activeTabID } }
    public var activeIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }
    public func tab(_ id: UUID) -> TabModel? { tabs.first { $0.id == id } }

    // MARK: - Restore and persistence

    /// Builds tabs from the session file without any Git work. Only the active tab loads later, when
    /// the window reaches the foreground (`setForeground(true)`).
    public func restore(_ state: SessionState?) {
        windowFrame = state?.windowFrame
        if let saved = state?.layout {
            layout.sidebarWidth = CGFloat(saved.sidebarWidth)
            layout.inspectorWidth = CGFloat(saved.inspectorWidth)
        }
        if let state, preferences.restoreTabsOnLaunch {
            tabs = state.tabs.compactMap(makeTab)
            activeTabID = state.activeTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
        }
        if tabs.isEmpty {
            let tab = TabModel(kind: .newTab, title: TabModel.newTabTitle)
            tabs = [tab]
            activeTabID = tab.id
        }
        onChange?(.tabs)
        onChange?(.activeTab)
    }

    private func makeTab(_ record: SessionState.Tab) -> TabModel? {
        switch record.kind {
        case .newTab:
            return TabModel(id: record.id, kind: .newTab, title: TabModel.newTabTitle, ui: record.ui)
        case .repository:
            guard let path = record.path else { return nil }
            let tab = TabModel(
                id: record.id, kind: .repository(path: path), title: record.titleCache, branch: record.branchCache,
                session: makeSession(path: path, handle: nil), sidebarCollapsed: record.sidebarCollapsed,
                inspectorCollapsed: record.inspectorCollapsed, ui: record.ui)
            bind(tab)
            return tab
        }
    }

    public var sessionState: SessionState {
        SessionState(
            windowFrame: windowFrame, layout: layout.record, tabs: tabs.map(\.record), activeTabID: activeTabID)
    }

    public func scheduleSave() {
        sessionStore?.save { [weak self] in self?.sessionState ?? SessionState() }
    }

    /// Writes everything now (app termination).
    /// Some tab is running a mutation (stage, discard, line apply, commit).
    public var hasPendingWrites: Bool { tabs.contains { $0.session?.isBusy == true } }

    /// Calls `done` once no tab is writing (Observation on `pendingWrites`; no polling).
    public func whenWritesFinish(_ done: @escaping @MainActor () -> Void) {
        guard hasPendingWrites else { return done() }
        withObservationTracking {
            _ = tabs.map { $0.session?.pendingWrites }
            _ = tabs.map { $0.session?.operations.records }
        } onChange: { [weak self] in
            Task { @MainActor in self?.whenWritesFinish(done) }
        }
    }

    /// Running operations across tabs (quit confirmation, design §5).
    public var runningOperations: [String] {
        tabs.flatMap { tab in (tab.session?.operations.running ?? []).map { "\($0.title) — \(tab.title)" } }
    }

    /// Quit: cancels every cancel-safe operation (fetch, clone, push); the rest finish first (bounded wait).
    public func cancelCancellableOperations() {
        for tab in tabs { _ = tab.session?.operations.cancelAllCancellable() }
    }

    public func flush() {
        scheduleSave()
        sessionStore?.flush()
        recents.flush()
        profiles.flush()
    }

    // MARK: - Foreground and lifecycle

    /// The window is visible in the active app. Leaving the foreground stops all watching (no work in the
    /// background); returning revalidates the visible tab once.
    public func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        if foreground { activeTab?.session?.activate() } else { activeTab?.session?.deactivate() }
    }

    public func handleMemoryPressure() {
        // Rebuildable caches go first (code-line layouts, palette file index); in-flight operations keep their
        // own snapshots, so nothing an operation relies on is dropped (ADR-0043).
        NotificationCenter.default.post(name: CacheLimits.trimNotification, object: nil)
        var suspended: Set<UUID> = []
        for tab in tabs where tab.id != activeTabID {
            guard let session = tab.session, session.lifecycle == .inactive else { continue }
            session.suspend()
            suspended.insert(tab.id)
        }
        if !suspended.isEmpty { onChange?(.suspended(suspended)) }
    }

    // MARK: - Tabs

    public func select(_ id: UUID) {
        guard id != activeTabID, tabs.contains(where: { $0.id == id }) else { return }
        let interval = Signposts.begin(Signposts.tabSwitch)
        activeTab?.session?.deactivate()
        activeTabID = id
        if isForeground { activeTab?.session?.activate() }
        onChange?(.activeTab)
        // Ends after the run-loop turn that lays out and displays the cached content.
        DispatchQueue.main.async { Signposts.end(interval) }
        scheduleSave()
    }

    @discardableResult
    public func newTab() -> TabModel {
        let tab = TabModel(kind: .newTab, title: TabModel.newTabTitle)
        insert(tab, after: activeIndex)
        return tab
    }

    private func insert(_ tab: TabModel, after index: Int?) {
        let position = index.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: min(position, tabs.count))
        onChange?(.tabs)
        select(tab.id)
        scheduleSave()
    }

    /// Closes a tab. Closing the active tab activates its right neighbor, else its left one; closing the
    /// last tab leaves a new-tab page (the window stays open).
    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.isRepository {
            recentlyClosed.append(ClosedTab(record: tab.record, index: index))
            if recentlyClosed.count > Self.reopenCapacity { recentlyClosed.removeFirst() }
        }
        tab.session?.close()
        let wasActive = id == activeTabID
        let next = TabOrdering.indexToActivate(afterClosing: index, count: tabs.count)
        tabs.remove(at: index)
        if tabs.isEmpty {
            let replacement = TabModel(kind: .newTab, title: TabModel.newTabTitle)
            tabs = [replacement]
            activeTabID = nil
            onChange?(.tabs)
            select(replacement.id)
        } else {
            onChange?(.tabs)
            if wasActive, let next {
                activeTabID = nil
                select(tabs[next].id)
            }
        }
        scheduleSave()
    }

    public var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

    /// ⌘⇧T: restores the last closed repository tab at its old position (in-memory stack of 10).
    public func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast(), let path = closed.record.path else { return }
        if let existing = tabs.first(where: { $0.path == path }) {
            select(existing.id)
            return
        }
        var record = closed.record
        record.id = UUID()
        guard let tab = makeTab(record) else { return }
        tabs.insert(tab, at: min(closed.index, tabs.count))
        onChange?(.tabs)
        select(tab.id)
        scheduleSave()
    }

    public func selectNextTab() { cycle(by: 1) }
    public func selectPreviousTab() { cycle(by: -1) }

    private func cycle(by offset: Int) {
        guard let index = activeIndex, tabs.count > 1 else { return }
        select(tabs[TabOrdering.cycle(index, by: offset, count: tabs.count)].id)
    }

    public func moveTab(_ id: UUID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }), source != destination else { return }
        tabs = TabOrdering.move(tabs, from: source, to: destination)
        onChange?(.tabs)
        scheduleSave()
    }

    /// Window ▸ Move Tab Left/Right and the accessibility reorder actions.
    public func moveTab(_ id: UUID, by offset: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard tabs.indices.contains(destination) else { return }
        moveTab(id, to: destination)
    }

    // MARK: - Opening repositories

    /// Opens the repository at (or enclosing) `url`: focuses an existing tab for the same repository,
    /// replaces the active new-tab page, or adds a tab after the active one. `forgettingRecent` is removed from
    /// recents only once the new folder opened successfully (Locate…).
    public func open(_ url: URL, replacing tabID: UUID? = nil, forgettingRecent: String? = nil) {
        let key = tabID?.uuidString ?? Self.standardized(url.path)
        openTasks[key]?.cancel()
        let interval = Signposts.begin(Signposts.repoOpen)
        openTasks[key] = Task { [engine] in
            defer { if !Task.isCancelled { self.openTasks[key] = nil } }
            do throws(GitCoreError) {
                let handle = try await engine.openRepository(at: url)
                guard !Task.isCancelled else { return Signposts.end(interval) }
                if let forgettingRecent, Self.standardized(forgettingRecent) != Self.standardized(handle.path) {
                    self.recents.remove(path: forgettingRecent)
                }
                self.adopt(handle, replacing: tabID, signpost: interval)
            } catch .cancelled {
                Signposts.end(interval)
                return
            } catch {
                Signposts.end(interval)
                guard !Task.isCancelled else { return }
                self.onOpenFailure?(url, error)
            }
        }
    }

    /// Waits for pending opens (tests, launch hooks).
    public func settleOpen() async {
        // A finished open removes itself; a superseded one is replaced by its successor.
        while let task = openTasks.values.first { await task.value }
    }

    private func adopt(_ handle: RepositoryHandle, replacing tabID: UUID?, signpost: Signposts.Token? = nil) {
        let path = Self.standardized(handle.path)
        let name = handle.info.displayName
        recents.noteOpened(path: path, name: name, branch: BranchLabel.text(for: BranchHeader(handle.info.head)))
        if let existing = tabs.first(where: { $0.path.map(Self.standardized) == path }) {
            if let tabID, tabID != existing.id, let stale = tab(tabID), stale.isRepository {
                closeTab(tabID)
            }
            select(existing.id)
            signpost.map(Signposts.end)
            return
        }
        let tab = TabModel(
            kind: .repository(path: path), title: name, branch: BranchLabel.text(for: BranchHeader(handle.info.head)),
            session: makeSession(path: path, handle: handle))
        tab.openSignpost = signpost
        bind(tab)
        let target =
            tabID.flatMap { id in tabs.firstIndex { $0.id == id } }
            ?? activeIndex.flatMap { tabs[$0].isRepository ? nil : $0 }
        if let target {
            let replaced = tabs[target]
            replaced.session?.close()
            if replaced.id == activeTabID { activeTabID = nil }
            tabs[target] = tab
            onChange?(.tabs)
            select(tab.id)
            scheduleSave()
        } else {
            insert(tab, after: activeIndex)
        }
    }

    /// Locate…: points a missing repository tab at a new folder.
    public func relocate(_ tabID: UUID, to url: URL) {
        open(url, replacing: tabID, forgettingRecent: tab(tabID)?.path)
    }

    private func makeSession(path: String, handle: RepositoryHandle?) -> RepositorySession {
        RepositorySession(path: path, engine: engine, handle: handle, watchesFileSystem: watchesFileSystem)
    }

    /// Keeps the tab's title, branch and dot in sync with its session.
    private func bind(_ tab: TabModel) {
        tab.session?.onChange = { [weak self, weak tab] session in
            guard let self, let tab else { return }
            self.sessionChanged(session, tab: tab)
        }
    }

    private func sessionChanged(_ session: RepositorySession, tab: TabModel) {
        var changed = false
        if let info = session.info, tab.title != info.displayName {
            tab.title = info.displayName
            changed = true
        }
        if let status = session.status {
            let branch = BranchLabel.text(for: status.branch)
            if tab.branch != branch {
                tab.branch = branch
                recents.updateBranch(path: session.path, branch: branch)
                changed = true
            }
        }
        if tab.statusDot != session.statusDot { tab.statusDot = session.statusDot }
        if changed { scheduleSave() }
        if tab.id == activeTabID { onChange?(.activeTabDetails) }
    }

    public static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}

extension BranchHeader {
    init(_ head: RepositoryInfo.Head) {
        switch head {
        case let .branch(name, commit): self.init(oid: commit, head: name)
        case let .detached(commit): self.init(oid: commit)
        case let .unborn(branch): self.init(head: branch)
        }
    }
}
