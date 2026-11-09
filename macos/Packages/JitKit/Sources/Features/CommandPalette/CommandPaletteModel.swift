import AppKit
import GitCore
import Observation
import Services

/// One palette row: what it shows and what it does (actions run on the main actor after the palette closes).
@MainActor
struct PaletteEntry: Identifiable {
    let id: String
    let source: PaletteSource
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let disabledReason: String?
    let primary: @MainActor () -> Void
    let secondaryTitle: String?
    let secondary: (@MainActor () -> Void)?
    let keywords: String

    var isEnabled: Bool { disabledReason == nil }

    /// "Push, command, ⌘P" / "main, branch, disabled: …" — VoiceOver label (design §3.1).
    var accessibilityLabel: String {
        var parts = [title, source.kindName]
        if !shortcut.isEmpty { parts.append(shortcut) }
        if !subtitle.isEmpty, isEnabled { parts.append(subtitle) }
        if let disabledReason { parts.append("unavailable: \(disabledReason)") }
        return parts.joined(separator: ", ")
    }
}

extension PaletteSource {
    var kindName: String {
        switch self {
        case .command: "command"
        case .ref: "branch or tag"
        case .file: "file"
        case .repository: "repository"
        case .commit: "commit"
        }
    }
}

/// A shown result: the entry plus matched title characters (emphasized by weight, not color alone).
struct PaletteRow: Identifiable {
    let entry: PaletteEntry
    let matched: Set<Int>
    var id: String { entry.id }
}

/// The command palette's state (ADR-0044). Sources are snapshotted when it opens; ranking runs off the main actor.
@MainActor @Observable
final class CommandPaletteModel {
    var query = "" { didSet { if query != oldValue { requery() } } }
    private(set) var rows: [PaletteRow] = []
    private(set) var selected = 0
    private(set) var isIndexingFiles = false
    private(set) var fileIndexError: String?
    private(set) var fileIndexTruncated = false

    @ObservationIgnored private var entries: [String: PaletteEntry] = [:]
    @ObservationIgnored private var candidates: [PaletteCandidate] = []
    @ObservationIgnored private var fileCandidatesLoaded = false
    @ObservationIgnored private var rankTask: Task<Void, Never>?
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored weak var window: MainWindowController?
    @ObservationIgnored var close: () -> Void = {}

    static let recentsKey = "CommandPaletteRecents"
    static let recentLimit = 5
    /// Tracked-path index per repository (`git ls-files`), kept for the two most recent repositories.
    private static var fileIndexCache: [(path: String, revision: UInt64, files: TrackedPaths)] = []

    init(window: MainWindowController) {
        self.window = window
    }

    /// Memory pressure (ADR-0043): the tracked-path index is rebuilt on next use.
    static func trimCaches() { fileIndexCache.removeAll() }
    static var fileIndexCacheCount: Int { fileIndexCache.count }

    var recents: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(Self.recentLimit)), forKey: Self.recentsKey) }
    }

    // MARK: Opening

    /// Rebuilds every source from current state (no Git work except the lazy file index).
    func reload() {
        query = ""
        entries = [:]
        candidates = []
        fileCandidatesLoaded = false
        fileIndexError = nil
        fileIndexTruncated = false
        addCommands()
        addRefs()
        addChangedFiles()
        addRepositories()
        requery()
    }

    private func add(_ entry: PaletteEntry, order: Int) {
        guard entries[entry.id] == nil else { return }
        entries[entry.id] = entry
        candidates.append(
            PaletteCandidate(
                id: entry.id, source: entry.source, title: entry.title, keywords: entry.keywords, order: order))
    }

    private func addCommands() {
        guard let mainWindow = window?.window else { return }
        for (order, command) in CommandRegistry.all.enumerated() where command.inPalette {
            let item = MainMenu.item(for: command)
            let target = Self.target(for: command.action, in: mainWindow, sender: item)
            let enabled = target.map { Self.validate(item, target: $0) } ?? false
            var reason: String?
            if !enabled {
                reason =
                    (target as? any CommandAvailability)?.disabledReason(for: command.action)
                    ?? (window?.disabledReason(for: command.action))
                    ?? "Not available in the current view"
            }
            let menuPath = ([command.menu.rawValue] + command.submenu).joined(separator: " ▸ ")
            add(
                PaletteEntry(
                    id: "cmd:\(command.id)", source: .command, title: command.paletteTitle, subtitle: menuPath,
                    symbol: command.symbol, shortcut: command.shortcutGlyphs, disabledReason: reason,
                    primary: { NSApp.sendAction(command.action, to: nil, from: MainMenu.item(for: command)) },
                    secondaryTitle: nil, secondary: nil, keywords: "\(menuPath) \(command.keywords)"),
                order: order)
        }
    }

    private func addRefs() {
        guard let workbench = window?.activeWorkbench, let refs = workbench.graph?.history?.refs else { return }
        let operations = workbench.operations
        for (order, ref) in refs.refs.enumerated() where ref.kind != .other {
            guard let commit = ref.commit else { continue }
            let name = Self.shortName(ref)
            let isCurrent = refs.head.branchName == name && ref.kind == .local
            let symbol =
                switch ref.kind {
                case .local: "arrow.triangle.branch"
                case .remote: "cloud"
                case .tag: "tag"
                case .other: "circle"
                }
            let kind =
                switch ref.kind {
                case .local: isCurrent ? "Current branch" : "Branch"
                case .remote: "Remote branch"
                case .tag: "Tag"
                case .other: "Ref"
                }
            let upstream = ref.upstream.map { " · tracks \($0)" } ?? ""
            let primary: @MainActor () -> Void = { [weak workbench] in workbench?.graph?.select(oid: commit) }
            var secondary: (@MainActor () -> Void)?
            if !isCurrent, ref.kind != .tag {
                secondary = { [weak operations] in operations?.checkout(ref: ref) }
            }
            let entry = PaletteEntry(
                id: "ref:\(ref.fullName)", source: .ref, title: name, subtitle: kind + upstream, symbol: symbol,
                shortcut: "", disabledReason: nil, primary: primary,
                secondaryTitle: secondary == nil ? nil : "Check Out", secondary: secondary, keywords: ref.fullName)
            add(entry, order: order)
        }
    }

    private func addChangedFiles() {
        guard let workbench = window?.activeWorkbench,
            let workingDirectory = workbench.inspectorModel.workingDirectory
        else { return }
        for (order, file) in workingDirectory.allFiles.enumerated() where !file.isDirectory {
            let name = (file.path as NSString).lastPathComponent
            let section: String =
                switch file.section {
                case .staged: "Staged"
                case .unstaged: "Changed"
                case .conflicts: "Conflict"
                }
            add(
                PaletteEntry(
                    id: "file:\(file.path)", source: .file, title: name, subtitle: "\(section) · \(file.path)",
                    symbol: file.section == .conflicts ? "exclamationmark.triangle" : "doc.badge.ellipsis",
                    shortcut: "", disabledReason: nil,
                    primary: { [weak workbench] in
                        guard let workbench, workbench.graph?.selectWorkingDirectory() == true else { return }
                        workbench.inspectorModel.workingDirectory?.selection = [file.id]
                    },
                    secondaryTitle: "File History",
                    secondary: { [weak workbench] in
                        workbench?.graph?.showFileHistory(path: file.path, isDirectory: false)
                    },
                    keywords: file.path),
                order: order)
        }
    }

    private func addRepositories() {
        guard let app = window?.model else { return }
        for (order, tab) in app.tabs.enumerated() {
            let id = tab.id
            let primary: @MainActor () -> Void = { [weak app] in app?.select(id) }
            var secondary: (@MainActor () -> Void)?
            var subtitle = "Open tab"
            if let path = tab.path {
                secondary = { RepositoryActions.revealInFinder(path) }
                subtitle += " · " + (path as NSString).abbreviatingWithTildeInPath
            }
            let entry = PaletteEntry(
                id: "tab:\(id.uuidString)", source: .repository, title: tab.title, subtitle: subtitle,
                symbol: "macwindow", shortcut: "", disabledReason: nil, primary: primary,
                secondaryTitle: secondary == nil ? nil : "Reveal in Finder", secondary: secondary,
                keywords: tab.path ?? "")
            add(entry, order: order)
        }
        let openPaths = Set(app.tabs.compactMap(\.path))
        for (order, recent) in app.recents.entries.enumerated() where !openPaths.contains(recent.path) {
            let missing = app.recents.missingPaths.contains(recent.path)
            add(
                PaletteEntry(
                    id: "recent:\(recent.path)", source: .repository, title: recent.name,
                    subtitle: "Recent · \((recent.path as NSString).abbreviatingWithTildeInPath)",
                    symbol: "clock.arrow.circlepath", shortcut: "",
                    disabledReason: missing ? "The folder is missing" : nil,
                    primary: { [weak app] in app?.open(URL(fileURLWithPath: recent.path)) },
                    secondaryTitle: "Reveal in Finder", secondary: { RepositoryActions.revealInFinder(recent.path) },
                    keywords: recent.path),
                order: app.tabs.count + order)
        }
    }

    // MARK: Lazy sources

    /// First `/` query: loads tracked paths once per repository revision (bounded; off the main actor).
    private func loadFileIndexIfNeeded() {
        guard !fileCandidatesLoaded, fileTask == nil, let workbench = window?.activeWorkbench,
            let handle = workbench.graph?.history?.repository
        else { return }
        let path = handle.path
        let revision = workbench.session.status?.revision ?? 0
        if let cached = Self.fileIndexCache.first(where: { $0.path == path && $0.revision == revision }) {
            addTracked(cached.files, workbench: workbench)
            return
        }
        isIndexingFiles = true
        fileTask = Task { [weak self, weak workbench] in
            let result: Result<TrackedPaths, GitCoreError>
            do throws(GitCoreError) {
                result = .success(try await handle.trackedPaths(limit: CacheLimits.paletteTrackedPaths))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isIndexingFiles = false
            self.fileTask = nil
            switch result {
            case .success(let files):
                Self.fileIndexCache.removeAll { $0.path == path }
                Self.fileIndexCache.insert((path, revision, files), at: 0)
                if Self.fileIndexCache.count > CacheLimits.paletteFileIndexRepositories {
                    Self.fileIndexCache.removeLast()
                }
                if let workbench { self.addTracked(files, workbench: workbench) }
            case .failure(let error):
                self.fileIndexError = error.summary
            }
            self.requery()
        }
    }

    private func addTracked(_ files: TrackedPaths, workbench: WorkbenchController) {
        fileCandidatesLoaded = true
        fileIndexTruncated = files.isTruncated
        let base = candidates.count
        for (order, path) in files.paths.enumerated() {
            let name = (path as NSString).lastPathComponent
            add(
                PaletteEntry(
                    id: "file:\(path)", source: .file, title: name, subtitle: path, symbol: "doc", shortcut: "",
                    disabledReason: nil,
                    primary: { [weak workbench] in workbench?.graph?.showFileHistory(path: path, isDirectory: false) },
                    secondaryTitle: "Reveal in Finder",
                    secondary: { [weak workbench] in
                        if let root = workbench?.session.info?.topLevel {
                            RepositoryActions.revealInFinder((root as NSString).appendingPathComponent(path))
                        }
                    }, keywords: path),
                order: base + order)
        }
    }

    // MARK: Ranking

    private func requery() {
        let (scope, text) = PaletteRanker.scope(of: query)
        if scope == .file || (scope == nil && text.count >= 2) { loadFileIndexIfNeeded() }
        let pool = candidates
        let recent = recents
        let query = self.query
        rankTask?.cancel()
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty query: recent commands, then the enabled commands for the current tab — repository and
            // branch work first, app-level items last.
            let recentRows = recent.compactMap { entries[$0] }.filter { $0.source == .command }
            let contextual = pool.filter { $0.source == .command }
                .sorted {
                    Self.menuRank($0.id) < Self.menuRank($1.id)
                        || (Self.menuRank($0.id) == Self.menuRank($1.id) && $0.order < $1.order)
                }
                .compactMap { entries[$0.id] }
                .filter { $0.isEnabled && !recent.contains($0.id) }
            rows = (recentRows + contextual).prefix(PaletteRanker.resultLimit).map {
                PaletteRow(entry: $0, matched: [])
            }
            selected = 0
            return
        }
        searchCommits(scope: scope, text: text)
        rankTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                PaletteRanker.rank(query, pool, recent: recent)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.rows = ranked.compactMap { result in
                self.entries[result.candidate.id].map { PaletteRow(entry: $0, matched: Set(result.titleIndices)) }
            }
            self.selected = self.rows.firstIndex { $0.entry.isEnabled } ?? 0
        }
    }

    /// `:` + hex, or a bare hex query of ≥ 7 characters: exact/prefix SHA among loaded commits only.
    private func searchCommits(scope: PaletteSource?, text: String) {
        commitTask?.cancel()
        let hex = text.lowercased()
        guard scope == .commit || (scope == nil && hex.count >= 7), hex.count >= 4,
            hex.allSatisfy({ $0.isHexDigit }), let workbench = window?.activeWorkbench,
            let snapshot = workbench.graph?.history?.snapshot
        else { return }
        commitTask = Task { [weak self, weak workbench] in
            let found = await Task.detached(priority: .userInitiated) { () -> [(ObjectID, String)] in
                var matches: [(ObjectID, String)] = []
                let prefix = Array(hex.utf8)
                prefix.withUnsafeBytes { bytes in
                    for index in 0..<snapshot.count where matches.count < 5 {
                        let row = snapshot.row(index)
                        if row.oid.hasHexPrefix(bytes) { matches.append((row.oid, row.subject)) }
                    }
                }
                return matches
            }.value
            guard let self, let workbench, !Task.isCancelled else { return }
            for (oid, subject) in found {
                let short = oid.hex(snapshot.format, length: 9)
                self.add(
                    PaletteEntry(
                        id: "commit:\(short)", source: .commit, title: short, subtitle: subject,
                        symbol: "smallcircle.filled.circle", shortcut: "", disabledReason: nil,
                        primary: { [weak workbench] in workbench?.graph?.select(oid: oid) }, secondaryTitle: nil,
                        secondary: nil, keywords: subject),
                    order: 0)
            }
            if !found.isEmpty {
                let pool = self.candidates
                let ranked = PaletteRanker.rank(self.query, pool, recent: self.recents)
                self.rows = ranked.compactMap { result in
                    self.entries[result.candidate.id].map { PaletteRow(entry: $0, matched: Set(result.titleIndices)) }
                }
            }
        }
    }

    /// Empty-query order of command menus.
    static func menuRank(_ id: String) -> Int {
        let order = [
            "cmd:repo.", "cmd:branch.", "cmd:view.", "cmd:edit.", "cmd:file.", "cmd:window.", "cmd:help.", "cmd:app.",
        ]
        return order.firstIndex { id.hasPrefix($0) } ?? order.count
    }

    // MARK: Keyboard

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
        announceSelection()
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selected = index
    }

    /// ↩ (primary) or ⌘↩ (secondary). Disabled rows never run.
    func execute(secondary: Bool = false) {
        guard rows.indices.contains(selected) else { return }
        let entry = rows[selected].entry
        guard entry.isEnabled else {
            NSSound.beep()
            return
        }
        let action = secondary ? entry.secondary : entry.primary
        guard let action else { return NSSound.beep() }
        if entry.source == .command {
            recents = [entry.id] + recents.filter { $0 != entry.id }
        }
        close()
        // After the palette is gone, so the main window's responder chain handles the action.
        DispatchQueue.main.async { action() }
    }

    var selectedEntry: PaletteEntry? { rows.indices.contains(selected) ? rows[selected].entry : nil }

    private func announceSelection() {
        guard let entry = selectedEntry else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: entry.accessibilityLabel, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Responder chain (the palette panel is key; commands target the main window)

    static func target(for action: Selector, in window: NSWindow, sender: NSMenuItem) -> AnyObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if window.responds(to: action) { return window }
        if let delegate = window.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    static func validate(_ item: NSMenuItem, target: AnyObject) -> Bool {
        if let validator = target as? any NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? any NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(item)
        }
        return true
    }

    static func shortName(_ ref: GitRef) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.fullName.hasPrefix(prefix) {
            return String(ref.fullName.dropFirst(prefix.count))
        }
        return ref.fullName
    }
}
