import AppKit
import Foundation
import GitCore
import Observation
import Services

/// State of the working-directory panel (design §3.1). Follows `RepositorySession.status` through
/// Observation (no polling) while active; rows are rebuilt off the main actor from the handle's cached
/// snapshot. Mutations go through `RepositorySession` (write gate, then a status refresh).
@MainActor @Observable
final class WorkingDirectoryModel {
    let session: RepositorySession

    private(set) var list = WorkingDirectoryList.empty
    /// `true` until the first snapshot has been listed.
    private(set) var isLoading = true
    /// The 2pt hairline: shown only when a rebuild takes longer than 150 ms (design §3.1 Loading).
    private(set) var showsProgress = false
    private(set) var stats: [String: LineStats] = [:]
    private(set) var lastCommitSubject: String?
    /// The inline error banner (design §3.1 Error) and the action that Retry repeats.
    private(set) var banner: String?
    @ObservationIgnored private var retryAction: (() -> Void)?

    var filter = "" { didSet { if filter != oldValue { rebuildDisplay() } } }
    var sort: WDSort = .path { didSet { if sort != oldValue { rebuildDisplay() } } }
    var showsTree = false { didSet { if showsTree != oldValue { rebuildDisplay() } } }
    private(set) var collapsed: Set<String> = []
    var selection: Set<String> = []
    /// The section under a drag (drop highlight).
    var dropTarget: WDSection?

    /// Filtered, sorted (and in tree mode grouped) items per section.
    private(set) var display: [WDSection: [WDItem]] = [:]

    @ObservationIgnored var handle: RepositoryHandle? {
        didSet { if handle !== oldValue, isActive { refresh() } }
    }
    @ObservationIgnored var openFileHistory: (String) -> Void = { _ in }
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var subjectTask: Task<Void, Never>?
    @ObservationIgnored private var subjectFor: String?
    /// Rows on screen (row `onAppear`/`onDisappear`): line counts are computed for these only.
    @ObservationIgnored private var visible: Set<String> = []
    @ObservationIgnored private var pendingStats: Set<String> = []
    @ObservationIgnored private var observing = false
    /// Paths of the files being dragged (set when a drag starts).
    @ObservationIgnored private var dragged: (section: WDSection, files: [WDFile])?

    init(session: RepositorySession) {
        self.session = session
    }

    // MARK: Lifecycle

    /// The WIP row is selected: start following status.
    func activate() {
        guard !isActive else { return }
        isActive = true
        observeStatus()
        refresh()
    }

    /// Something else is selected: stop work; keep the last list for an instant re-display.
    func deactivate() {
        isActive = false
        buildTask?.cancel()
        statsTask?.cancel()
        progressTask?.cancel()
        showsProgress = false
    }

    private func observeStatus() {
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = session.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observing = false
                guard self.isActive else { return }
                self.observeStatus()
                self.refresh()
            }
        }
    }

    /// Re-reads the handle's snapshot and rebuilds the rows when it changed.
    func refresh() {
        guard isActive, let handle else { return }
        buildTask?.cancel()
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.showsProgress = true
        }
        let known = isLoading ? nil : list.revision
        buildTask = Task { [weak self] in
            guard let snapshot = await handle.lastSnapshot() else {
                self?.finishBuild()
                return
            }
            if let known, snapshot.revision == known {
                self?.finishBuild()
                return
            }
            let list = await Task.detached(priority: .userInitiated) { WorkingDirectoryList(snapshot: snapshot) }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(list, branch: snapshot.branch)
            self.finishBuild()
        }
    }

    private func finishBuild() {
        progressTask?.cancel()
        showsProgress = false
    }

    func apply(_ newList: WorkingDirectoryList, branch: BranchHeader) {
        let changed = newList != list
        list = newList
        isLoading = false
        guard changed else { return }
        rebuildDisplay()
        // Selected rows that no longer exist (a staged file moved to Unstaged) drop out of the selection.
        let ids = Set(allFiles.map(\.id))
        let shown = Set(display.values.joined().map(\.id))
        selection = selection.filter { shown.contains($0) }
        // Counts may have changed for any file; keep the old numbers on screen until the new ones arrive.
        requestStats(for: visible.intersection(ids), replacing: true)
        if newList.isClean { loadLastCommitSubject(branch) }
    }

    var allFiles: [WDFile] { list.conflicts + list.staged + list.unstaged }

    func file(id: String) -> WDFile? { allFiles.first { $0.id == id } }

    func folder(id: String) -> WDFolder? {
        for items in display.values {
            for case .folder(let folder) in items where folder.id == id { return folder }
        }
        return nil
    }

    func items(_ section: WDSection) -> [WDItem] { display[section] ?? [] }

    func toggleFolder(_ folder: WDFolder) {
        if collapsed.contains(folder.id) { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
        rebuildDisplay()
    }

    private func rebuildDisplay() {
        var next: [WDSection: [WDItem]] = [:]
        for section in WDSection.allCases {
            next[section] = WDDisplay.items(
                list.files(section), section: section, filter: filter, sort: sort, tree: showsTree,
                collapsed: collapsed, stats: stats)
        }
        display = next
    }

    private func loadLastCommitSubject(_ branch: BranchHeader) {
        guard let hex = branch.oid, subjectFor != hex, let handle else { return }
        subjectFor = hex
        subjectTask?.cancel()
        subjectTask = Task { [weak self] in
            guard let oid = ObjectID(hex: hex), let details = try? await handle.commitDetails(oid) else { return }
            guard let self, !Task.isCancelled else { return }
            self.lastCommitSubject = details.subject
        }
    }

    // MARK: Lazy line counts

    func rowAppeared(_ file: WDFile) {
        visible.insert(file.id)
        if stats[file.id] == nil, file.change != .untracked, file.section != .conflicts {
            requestStats(for: [file.id], replacing: false)
        }
    }

    func rowDisappeared(_ file: WDFile) { visible.remove(file.id) }

    /// Coalesces requests from rows appearing in the same layout pass into one Git call per side.
    private func requestStats(for ids: Set<String>, replacing: Bool) {
        pendingStats.formUnion(ids)
        guard statsTask == nil || replacing, !pendingStats.isEmpty, let handle else { return }
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let wanted = self.pendingStats
            self.pendingStats = []
            let files = self.allFiles.filter {
                wanted.contains($0.id) && $0.change != .untracked && $0.section != .conflicts
            }
            let staged = files.filter { $0.section == .staged }
            let unstaged = files.filter { $0.section == .unstaged }
            var found: [String: LineStats] = [:]
            if !staged.isEmpty,
                let result = try? await handle.lineStats(staged: true, paths: staged.flatMap(\.operationPaths))
            {
                for file in staged { if let value = result[file.path] { found[file.id] = value } }
            }
            if !unstaged.isEmpty, let result = try? await handle.lineStats(staged: false, paths: unstaged.map(\.path)) {
                for file in unstaged { if let value = result[file.path] { found[file.id] = value } }
            }
            guard !Task.isCancelled else { return }
            self.stats.merge(found) { _, new in new }
            if self.sort == .size { self.rebuildDisplay() }
            self.statsTask = nil
            if !self.pendingStats.isEmpty { self.requestStats(for: [], replacing: false) }
        }
    }

    // MARK: Actions

    /// Files a context-menu or keyboard action applies to: the clicked/selected rows, folders expanded
    /// to their files.
    func files(for ids: Set<String>) -> [WDFile] {
        var seen = Set<String>()
        var result: [WDFile] = []
        for id in ids {
            let files = folder(id: id)?.files ?? file(id: id).map { [$0] } ?? []
            for file in files where seen.insert(file.id).inserted { result.append(file) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func stage(_ files: [WDFile]) {
        let paths = files.filter { $0.section == .unstaged }.flatMap(\.operationPaths)
        guard !paths.isEmpty else { return }
        run("stage") { session throws(GitCoreError) in try await session.stage(paths) }
    }

    func unstage(_ files: [WDFile]) {
        let paths = files.filter { $0.section == .staged }.flatMap(\.operationPaths)
        guard !paths.isEmpty else { return }
        run("unstage") { session throws(GitCoreError) in try await session.unstage(paths) }
    }

    func stageAll() { stage(list.unstaged) }
    func unstageAll() { unstage(list.staged) }

    /// Space: stages the selected unstaged files and unstages the selected staged ones.
    func toggleSelection() {
        let files = files(for: selection)
        let toStage = files.filter { $0.section == .unstaged }
        let toUnstage = files.filter { $0.section == .staged }
        if !toStage.isEmpty { stage(toStage) }
        if !toUnstage.isEmpty { unstage(toUnstage) }
    }

    private func run(
        _ verb: String, _ body: @escaping @MainActor (RepositorySession) async throws(GitCoreError) -> Void
    ) {
        banner = nil
        retryAction = nil
        let session = self.session
        Task { [weak self] in
            do throws(GitCoreError) {
                try await body(session)
            } catch .cancelled {
                return
            } catch {
                guard let self else { return }
                self.banner = Self.message(for: error, verb: verb)
                self.retryAction = { [weak self] in self?.run(verb, body) }
            }
        }
    }

    static func message(for error: GitCoreError, verb: String) -> String {
        switch error {
        case .indexLocked:
            "Index is locked by another Git process (.git/index.lock). Jit never removes lock files; retry when it finishes."
        default:
            "Couldn’t \(verb): \(error.summary)"
        }
    }

    func retry() {
        let action = retryAction
        banner = nil
        retryAction = nil
        action?()
    }

    func dismissBanner() {
        banner = nil
        retryAction = nil
    }

    var canRetry: Bool { retryAction != nil }

    // MARK: Drag and drop between Staged and Unstaged

    static let dragPrefix = "jit-working-directory:"

    /// Called lazily when a drag starts on `file`: drags the selection if the row is part of it.
    func beginDrag(_ file: WDFile) -> String {
        let ids = selection.contains(file.id) ? selection : [file.id]
        let files = files(for: ids).filter { $0.section == file.section }
        dragged = (file.section, files.isEmpty ? [file] : files)
        return Self.dragPrefix + file.id
    }

    /// A drop of our own drag payload onto `section`. Returns `false` (no-op) for anything else.
    @discardableResult
    func drop(_ payloads: [String], into section: WDSection) -> Bool {
        dropTarget = nil
        guard payloads.contains(where: { $0.hasPrefix(Self.dragPrefix) }), let dragged, dragged.section != section
        else { return false }
        self.dragged = nil
        switch (dragged.section, section) {
        case (.unstaged, .staged): stage(dragged.files)
        case (.staged, .unstaged): unstage(dragged.files)
        default: return false
        }
        return true
    }

    // MARK: Files on disk

    var topLevel: String { session.info?.topLevel ?? session.path }

    func url(_ file: WDFile) -> URL { URL(fileURLWithPath: topLevel).appendingPathComponent(file.path) }

    func openInEditor(_ files: [WDFile]) {
        let urls = files.map(url).filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ files: [WDFile]) {
        let urls = files.map(url).filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            RepositoryActions.revealInFinder(topLevel)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copyPaths(_ files: [WDFile], relative: Bool) {
        let text = files.map { relative ? $0.path : url($0).path }.joined(separator: "\n")
        RepositoryActions.copyPath(text)
    }
}
