import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI
import os

/// The commit graph (design §3.2, §4.5, ADR-0009): a view-based `NSTableView` whose cells draw with Core
/// Graphics. Only visible rows (+ overscan) exist as views and only they are materialized as strings.
/// Pages append with `insertRows` and no animation, so nothing on screen moves.
@MainActor
final class GraphViewController: NSViewController {
    enum DisplayRow: Equatable {
        case wip
        case commit(Int)
        case footer
    }

    struct Actions {
        var selectionChanged: (GraphViewModel) -> Void = { _ in }
        var showInNavigator: (String) -> Void = { _ in }
        var refsChanged: (RefSnapshot) -> Void = { _ in }
    }

    let session: RepositorySession
    let tab: TabModel
    let model: AppModel
    let viewModel = GraphViewModel()
    var actions = Actions()

    private(set) var history: HistoryController?
    private let style: GraphStyle
    private let cache = GraphRowCache()
    private let scrollView = NSScrollView()
    let tableView = GraphTableView()
    private var barHost: NSHostingView<GraphBar>?
    private var overlayHost: NSHostingView<GraphStateOverlay>?
    private var snapshot: HistorySnapshot = .empty()
    private var rowCount = 0
    private var showsWIP = false
    private var showsFooter = false
    private var maxLanes = 1
    private var scannedRows = 0
    private var matchSet = Set<Int32>()
    private var hoveredRow: Int?
    private var isLiveScrolling = false
    private var deepSearchTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var observationArmed = false
    private var lastQuery: HistoryQuery?

    private static let signposter = OSSignposter(subsystem: "jit.performance", category: "graph")

    static let columnGraph = NSUserInterfaceItemIdentifier("graph")
    static let columnSubject = NSUserInterfaceItemIdentifier("subject")
    static let columnAuthor = NSUserInterfaceItemIdentifier("author")
    static let columnDate = NSUserInterfaceItemIdentifier("date")
    static let columnSHA = NSUserInterfaceItemIdentifier("sha")
    static let columnsKey = "graph.columns"

    init(session: RepositorySession, tab: TabModel, model: AppModel) {
        self.session = session
        self.tab = tab
        self.model = model
        style = GraphStyle(density: model.preferences.graphDensity == .compact ? .compact : .comfortable)
        super.init(nibName: nil, bundle: nil)
        viewModel.restore(from: tab.ui)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - View

    override func loadView() {
        let root = GraphRootView()
        root.wantsLayer = true
        view = root

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ColorToken.surfaceCanvas.nsColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = true
        root.addSubview(scrollView)

        let overlay = NSHostingView(rootView: GraphStateOverlay(controller: self))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = []
        root.addSubview(overlay)
        overlayHost = overlay

        let bar = NSHostingView(rootView: GraphBar(controller: self))
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.sizingOptions = [.intrinsicContentSize]
        root.addSubview(bar)
        barHost = bar

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            // The inspector floats over the pane's trailing edge on macOS 26; keep rows clear of it.
            scrollView.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(
            center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) {
                [weak self] _ in MainActor.assumeIsolated { self?.visibleRangeChanged() }
            })
        observers.append(
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main)
            {
                [weak self] _ in MainActor.assumeIsolated { self?.liveScroll(started: true) }
            })
        observers.append(
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.liveScroll(started: false) }
            })
        observers.append(
            center.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.appearanceChanged() } })
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Rows start below the floating bar and scroll under it.
        let barHeight = barHost?.fittingSize.height ?? 0
        let top = view.safeAreaInsets.top + barHeight
        if abs(scrollView.contentInsets.top - top) > 0.5 {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
        updateGraphColumnWidth()
        fitSubjectColumn()
    }

    /// The subject column takes whatever the fixed columns leave (no horizontal scrolling). In narrow
    /// layouts the SHA column hides first, then the author column narrows (design §3.1).
    private func fitSubjectColumn() {
        guard let subject = tableView.tableColumn(withIdentifier: Self.columnSubject),
            let sha = tableView.tableColumn(withIdentifier: Self.columnSHA),
            let author = tableView.tableColumn(withIdentifier: Self.columnAuthor)
        else { return }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        func others() -> CGFloat {
            tableView.tableColumns.filter { $0 !== subject && !$0.isHidden }.reduce(0) { $0 + $1.width }
        }
        let comfortableSubject: CGFloat = 260
        sha.isHidden = false
        if available - others() < comfortableSubject { sha.isHidden = true }
        let preferredAuthor = savedColumnWidths()[Self.columnAuthor.rawValue] ?? 150
        if author.width < preferredAuthor, available - others() - (preferredAuthor - author.width) >= comfortableSubject
        {
            author.width = preferredAuthor
        }
        if available - others() < comfortableSubject {
            author.width = max(author.minWidth, author.width - (comfortableSubject - (available - others())))
        }
        let width = max(subject.minWidth, available - others())
        if abs(subject.width - width) > 0.5 { subject.width = width }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attachHistoryIfNeeded()
        appearanceChanged()
    }

    private func configureTable() {
        tableView.style = .plain
        tableView.rowHeight = style.metrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = ColorToken.surfaceCanvas.nsColor
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        tableView.setAccessibilityLabel("Commit history")
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self

        let saved = savedColumnWidths()
        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat) -> NSTableColumn
        {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = saved[id.rawValue] ?? width
            column.minWidth = min
            column.resizingMask = .userResizingMask
            return column
        }
        let graph = column(Self.columnGraph, "Graph", width: 80, min: 24)
        graph.resizingMask = []
        tableView.addTableColumn(graph)
        let subject = column(Self.columnSubject, "Subject", width: 420, min: 160)
        subject.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(subject)
        // Only the subject column absorbs width changes; the others keep their (persisted) widths.
        for (id, title, width, min) in [
            (Self.columnAuthor, "Author", CGFloat(150), CGFloat(80)), (Self.columnDate, "Date", 104, 64),
            (Self.columnSHA, "SHA", 72, 56),
        ] {
            let fixed = column(id, title, width: width, min: min)
            fixed.resizingMask = .userResizingMask
            tableView.addTableColumn(fixed)
        }
    }

    // MARK: - History

    private func attachHistoryIfNeeded() {
        guard history == nil, let history = session.history else {
            if session.history == nil { observeSessionForHistory() }
            return
        }
        self.history = history
        history.onUpdate = { [weak self] update in self?.historyUpdated(update) }
        lastQuery = viewModel.query
        if history.query != viewModel.query {
            history.setQuery(viewModel.query)
        }
        history.start()
        if history.snapshot.count > 0 { historyUpdated(.replaced) }
        observeHistoryState()
        observeDensity()
        observeStatus()
    }

    /// The session creates its history controller when the repository opens; attach then.
    private func observeSessionForHistory() {
        withObservationTracking {
            _ = session.history
        } onChange: { [weak self] in
            Task { @MainActor in self?.attachHistoryIfNeeded() }
        }
    }

    private func observeHistoryState() {
        guard let history else { return }
        withObservationTracking {
            _ = history.error
            _ = history.isLoading
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updatePaneState()
                self?.observeHistoryState()
            }
        }
        updatePaneState()
    }

    /// The WIP row follows the Phase 1 status model.
    private func observeStatus() {
        withObservationTracking {
            _ = session.status
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateWIP()
                self?.observeStatus()
            }
        }
        updateWIP()
    }

    func applyQuery() {
        let query = viewModel.query
        guard query != lastQuery else { return }
        lastQuery = query
        viewModel.save(into: &tab.ui)
        model.scheduleSave()
        history?.setQuery(query)
    }

    private func historyUpdated(_ update: HistoryController.Update) {
        guard let history else { return }
        let interval = Self.signposter.beginInterval("GraphUpdate")
        defer { Self.signposter.endInterval("GraphUpdate", interval) }
        let previous = snapshot
        snapshot = history.snapshot
        cache.update(snapshot: snapshot, refs: history.refs, dropRows: update == .replaced)
        if let refs = history.refs { actions.refsChanged(refs) }
        switch update {
        case .appended(let from):
            scanLanes(from: from)
            if viewModel.isSearching { recomputeMatches(scroll: false) }
            appendRows()
        case .replaced:
            maxLanes = 1
            scannedRows = 0
            scanLanes(from: 0)
            reloadPreservingSelection(previous: previous)
            if viewModel.isSearching { recomputeMatches(scroll: false) }
        case .labels:
            updateWIP()
            redrawVisibleRows()
        }
        updatePaneState()
        visibleRangeChanged()
    }

    /// The graph column fits the lanes of the rows on screen (+ overscan): it grows at once when a visible
    /// row needs more, and shrinks only when a scroll ends — so it never jumps while the user scrolls.
    private func scanLanes(from start: Int) {
        scannedRows = snapshot.count
        fitLanesToVisibleRows(allowShrink: false)
    }

    private func fitLanesToVisibleRows(allowShrink: Bool) {
        let visible = tableView.rows(in: tableView.visibleRect)
        var widest = 1
        let low = max(0, visible.location - 2)
        let high = min(tableView.numberOfRows, visible.location + max(visible.length, 30) + 2)
        if low < high {
            for row in low..<high {
                if case .commit(let index) = displayRow(row), index < snapshot.count {
                    widest = max(widest, Int(snapshot.row(index).width))
                }
            }
        }
        let next = allowShrink ? widest : max(maxLanes, widest)
        if next != maxLanes {
            maxLanes = next
            updateGraphColumnWidth()
        }
    }

    private func updateGraphColumnWidth() {
        guard let column = tableView.tableColumn(withIdentifier: Self.columnGraph) else { return }
        let flat = viewModel.filterMode == .onlyMatches && viewModel.isSearching
        let needed = style.metrics.columnWidth(lanes: flat ? 1 : maxLanes)
        let limit = max(40, tableView.bounds.width * style.metrics.maxGraphShare)
        let width = min(needed, limit).rounded()
        if abs(column.width - width) > 0.5 {
            column.width = width
            fitSubjectColumn()
        }
    }

    // MARK: - Row mapping

    var isFlat: Bool { viewModel.filterMode == .onlyMatches && viewModel.isSearching }

    func displayRow(_ row: Int) -> DisplayRow? {
        if isFlat {
            return row < viewModel.matches.count ? .commit(Int(viewModel.matches[row])) : nil
        }
        var index = row
        if showsWIP {
            if index == 0 { return .wip }
            index -= 1
        }
        if index < snapshot.count { return .commit(index) }
        if showsFooter, index == snapshot.count { return .footer }
        return nil
    }

    func tableRow(forCommit index: Int) -> Int? {
        if isFlat { return viewModel.matches.firstIndex(of: Int32(index)) }
        return index + (showsWIP ? 1 : 0)
    }

    private func computeRowCount() -> Int {
        if isFlat { return viewModel.matches.count }
        return (showsWIP ? 1 : 0) + snapshot.count + (showsFooter ? 1 : 0)
    }

    private var wantsWIP: Bool {
        guard let summary = session.status?.summary, !summary.isClean else { return false }
        guard snapshot.headRow != nil || snapshot.count == 0 else {
            // HEAD not in this scope (solo of another branch, file history): no WIP row.
            return false
        }
        guard viewModel.fileHistory == nil, viewModel.solo == nil, !isFlat else { return false }
        return snapshot.count > 0
    }

    private func updateWIP() {
        let wanted = wantsWIP
        guard wanted != showsWIP else {
            if showsWIP {
                tableView.reloadData(forRowIndexes: [0], columnIndexes: IndexSet(0..<tableView.numberOfColumns))
            }
            return
        }
        showsWIP = wanted
        rowCount = computeRowCount()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            if wanted {
                tableView.insertRows(at: [0], withAnimation: [])
            } else {
                tableView.removeRows(at: [0], withAnimation: [])
            }
        }
        // The HEAD row draws the dashed top half when WIP sits above it.
        if let head = snapshot.headRow, let row = tableRow(forCommit: head) {
            tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
    }

    private func appendRows() {
        let interval = Self.signposter.beginInterval("PageAppend")
        defer { Self.signposter.endInterval("PageAppend", interval) }
        showsFooter = snapshot.complete && snapshot.count > 0
        let newCount = computeRowCount()
        let oldCount = tableView.numberOfRows
        rowCount = newCount
        if isFlat {
            tableView.reloadData()
            return
        }
        if newCount > oldCount {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.insertRows(at: IndexSet(oldCount..<newCount), withAnimation: [])
            }
        } else if newCount != oldCount {
            tableView.reloadData()
        }
        if !showsWIP { updateWIP() }
    }

    private func reloadPreservingSelection(previous: HistorySnapshot) {
        // Keep the scroll anchor (first visible commit) and the selection by id, not by row.
        let visible = tableView.rows(in: tableView.visibleRect)
        var anchor: (oid: ObjectID, offset: CGFloat)?
        for row in visible.location..<(visible.location + visible.length) {
            if case .commit(let index) = displayRow(row), index < previous.count {
                let rect = tableView.rect(ofRow: row)
                anchor = (previous.row(index).oid, rect.minY - tableView.visibleRect.minY)
                break
            }
        }
        showsWIP = wantsWIP
        showsFooter = snapshot.complete && snapshot.count > 0
        rowCount = computeRowCount()
        tableView.reloadData()
        restoreSelection()
        if let anchor, let index = snapshot.row(for: anchor.oid), let row = tableRow(forCommit: index) {
            let y = tableView.rect(ofRow: row).minY - anchor.offset
            tableView.scroll(NSPoint(x: 0, y: y))
        }
    }

    private func restoreSelection() {
        var rows = IndexSet()
        if viewModel.wipSelected, showsWIP { rows.insert(0) }
        var kept: [ObjectID] = []
        for oid in viewModel.selection {
            if let index = snapshot.row(for: oid), let row = tableRow(forCommit: index) {
                rows.insert(row)
                kept.append(oid)
            }
        }
        if kept != viewModel.selection {
            viewModel.selection = kept
            actions.selectionChanged(viewModel)
        }
        isSyncingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncingSelection = false
    }

    private var isSyncingSelection = false

    private func redrawVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let range = max(0, visible.location - 8)..<min(tableView.numberOfRows, visible.location + visible.length + 8)
        tableView.reloadData(forRowIndexes: IndexSet(range), columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        for row in range {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? GraphRowView)?.isSearchMatch = isMatch(row)
        }
    }

    private func visibleRangeChanged() {
        fitLanesToVisibleRows(allowShrink: false)
        let visible = tableView.rows(in: tableView.visibleRect)
        guard let history, visible.length > 0 else { return }
        var last = visible.location + visible.length
        if showsWIP { last -= 1 }
        if !isFlat { history.visibleRowsChanged(lastVisibleRow: max(0, last)) }
    }

    private func liveScroll(started: Bool) {
        isLiveScrolling = started
        if !started { fitLanesToVisibleRows(allowShrink: true) }
        if started, let hoveredRow {
            (tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? GraphRowView)?.resetHover()
            self.hoveredRow = nil
        }
    }

    // MARK: - Appearance & density

    private func appearanceChanged() {
        style.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if style.update(appearance: view.effectiveAppearance) {
            scrollView.backgroundColor = ColorToken.surfaceCanvas.nsColor
            tableView.backgroundColor = ColorToken.surfaceCanvas.nsColor
            redrawVisibleRows()
        }
    }

    func densityChanged() {
        let density: Density = model.preferences.graphDensity == .compact ? .compact : .comfortable
        guard GraphMetrics.forDensity(density) != style.metrics else { return }
        style.metrics = .forDensity(density)
        tableView.rowHeight = style.metrics.rowHeight
        updateGraphColumnWidth()
        tableView.reloadData()
        restoreSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        appearanceChanged()
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Menu commands (responder chain)

    @objc func jitFind(_ sender: Any?) { viewModel.focusSearchToken += 1 }
    @objc func jitFindNext(_ sender: Any?) { nextMatch(forward: true) }
    @objc func jitFindPrevious(_ sender: Any?) { nextMatch(forward: false) }

    @objc func setGraphDensity(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
            let density = PreferencesStore.GraphDensity(rawValue: raw)
        else { return }
        model.preferences.graphDensity = density
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(jitFindNext(_:)), #selector(jitFindPrevious(_:)):
            return !viewModel.matches.isEmpty
        case #selector(setGraphDensity(_:)):
            item.state = (item.representedObject as? String) == model.preferences.graphDensity.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }

    /// Every open graph follows the global density preference.
    private func observeDensity() {
        withObservationTracking {
            _ = model.preferences.graphDensity
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.densityChanged()
                self?.observeDensity()
            }
        }
    }

    // MARK: - Hover

    func mouseMoved(toRow row: Int?) {
        guard !isLiveScrolling, row != hoveredRow else { return }
        if let hoveredRow {
            (tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? GraphRowView)?.isHovered = false
        }
        hoveredRow = row
        if let row { (tableView.rowView(atRow: row, makeIfNecessary: false) as? GraphRowView)?.isHovered = true }
    }

    // MARK: - Search

    func searchTextChanged() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        viewModel.deepSearch = .idle
        viewModel.deepMatches = []
        recomputeMatches(scroll: true)
    }

    private func recomputeMatches(scroll: Bool) {
        let query = HistorySearchQuery(viewModel.searchText)
        let started = ContinuousClock.now
        viewModel.matches = query.isEmpty ? [] : snapshot.search(query)
        Self.log.debug("search \(self.viewModel.matches.count) matches in \(ContinuousClock.now - started)")
        matchSet = Set(viewModel.matches)
        if viewModel.matches.isEmpty {
            viewModel.currentMatch = nil
        } else if scroll || viewModel.currentMatch == nil {
            viewModel.currentMatch = 0
        }
        if isFlat || (viewModel.filterMode == .onlyMatches && !viewModel.isSearching) {
            rowCount = computeRowCount()
            tableView.reloadData()
            updateGraphColumnWidth()
            restoreSelection()
        } else {
            redrawVisibleRows()
        }
        if scroll, let current = viewModel.currentMatch { reveal(match: current) }
    }

    private static let log = Logger(subsystem: "jit.app", category: "graph")

    func setFilterMode(_ mode: GraphViewModel.FilterMode) {
        guard mode != viewModel.filterMode else { return }
        viewModel.filterMode = mode
        updateGraphColumnWidth()
        rowCount = computeRowCount()
        showsWIP = wantsWIP
        showsFooter = snapshot.complete && snapshot.count > 0 && !isFlat
        rowCount = computeRowCount()
        tableView.reloadData()
        restoreSelection()
    }

    func isMatch(_ row: Int) -> Bool {
        guard viewModel.isSearching, !isFlat, case .commit(let index) = displayRow(row) else { return false }
        return matchSet.contains(Int32(index))
    }

    func nextMatch(forward: Bool) {
        guard !viewModel.matches.isEmpty else { return }
        let count = viewModel.matches.count
        let current = viewModel.currentMatch ?? (forward ? -1 : 0)
        let next = ((current + (forward ? 1 : -1)) % count + count) % count
        viewModel.currentMatch = next
        reveal(match: next)
    }

    private func reveal(match: Int) {
        guard match < viewModel.matches.count else { return }
        let index = Int(viewModel.matches[match])
        guard let row = tableRow(forCommit: index) else { return }
        viewModel.select(snapshot.row(index).oid, extending: false)
        isSyncingSelection = true
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        isSyncingSelection = false
        scrollToRow(row)
        actions.selectionChanged(viewModel)
    }

    private func scrollToRow(_ row: Int) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            tableView.scrollRowToVisible(row)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionToken.panel.duration
                context.allowsImplicitAnimation = true
                tableView.scrollRowToVisible(row)
            }
        }
    }

    /// Continues the search in history not loaded yet (`git log --grep/--author`), streaming ids.
    func searchAllHistory() {
        guard let history, let refs = history.refs else { return }
        let query = HistorySearchQuery(viewModel.searchText)
        guard !query.text.isEmpty || !query.authors.isEmpty else { return }
        deepSearchTask?.cancel()
        viewModel.deepSearch = .running(found: 0)
        viewModel.deepMatches = []
        let stream = history.repository.searchDeep(query, in: history.query, refs: refs)
        deepSearchTask = Task { [weak self] in
            var found = 0
            do {
                for try await oid in stream {
                    guard let self, !Task.isCancelled else { return }
                    found += 1
                    if self.snapshot.row(for: oid) == nil { self.viewModel.deepMatches.append(oid) }
                    if found % 50 == 0 { self.viewModel.deepSearch = .running(found: found) }
                }
                guard let self, !Task.isCancelled else { return }
                self.viewModel.deepSearch = .finished(found: found, limited: found >= 5000)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let message = (error as? GitCoreError)?.summary ?? error.localizedDescription
                self.viewModel.deepSearch = .failed(message)
            }
        }
    }

    func cancelDeepSearch() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        if case .running(let found) = viewModel.deepSearch {
            viewModel.deepSearch = .finished(found: found, limited: false)
        }
    }

    /// Loads history until the first deep match beyond the loaded rows is present, then selects it.
    func revealFirstDeepMatch() {
        guard let oid = viewModel.deepMatches.first else { return }
        select(oid: oid)
    }

    // MARK: - Selection & navigation

    /// Selects a commit by id, loading pages until it appears (asks first beyond 50k rows).
    func select(oid: ObjectID) {
        if let index = snapshot.row(for: oid), let row = tableRow(forCommit: index) {
            viewModel.select(oid, extending: false)
            isSyncingSelection = true
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            isSyncingSelection = false
            scrollToRow(row)
            actions.selectionChanged(viewModel)
            return
        }
        guard let history, !snapshot.complete else { return }
        Task { [weak self] in
            var asked = false
            while let self, self.snapshot.row(for: oid) == nil, !self.snapshot.complete, history.error == nil {
                if self.snapshot.count >= 50_000, !asked {
                    asked = true
                    guard self.confirmDeepLoad() else { return }
                }
                await history.loadRows(atLeast: self.snapshot.count + 10_000)
                if Task.isCancelled { return }
            }
            guard let self, self.snapshot.row(for: oid) != nil else { return }
            self.recomputeMatches(scroll: false)
            self.select(oid: oid)
        }
    }

    private func confirmDeepLoad() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Load more history?"
        alert.informativeText =
            "This commit is more than 50,000 commits from the top. Loading that much history takes a moment and more memory."
        alert.addButton(withTitle: "Load History")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func clearModes() {
        // Esc: search, then solo, then compare (design §3.7).
        if viewModel.isSearching {
            viewModel.searchText = ""
            searchTextChanged()
        } else if viewModel.solo != nil {
            viewModel.solo = nil
            applyQuery()
        } else if viewModel.fileHistory != nil {
            viewModel.fileHistory = nil
            applyQuery()
        } else if viewModel.selection.count > 1, let last = viewModel.selection.last {
            select(oid: last)
        }
    }

    func solo(_ fullName: String) {
        viewModel.solo = fullName
        applyQuery()
    }

    func togglePin(_ fullName: String) {
        if viewModel.pinned.contains(fullName) {
            viewModel.pinned.removeAll { $0 == fullName }
        } else {
            viewModel.pinned.append(fullName)
        }
        applyQuery()
    }

    func showFileHistory(path: String, isDirectory: Bool) {
        viewModel.fileHistory = (path, !isDirectory)
        applyQuery()
    }

    var currentRefs: RefSnapshot? { history?.refs }

    // MARK: - Copy

    func copySelection(_ what: CopyKind) {
        let oids = selectedCommitRows().map { snapshot.row($0) }
        guard !oids.isEmpty else { return }
        let text: String
        switch what {
        case .sha: text = oids.map { $0.oid.hex(snapshot.format) }.joined(separator: "\n")
        case .shortSHA: text = oids.map { $0.oid.hex(snapshot.format, length: 7) }.joined(separator: "\n")
        case .subject: text = oids.map(\.subject).joined(separator: "\n")
        }
        Pasteboard.copy(text)
    }

    enum CopyKind { case sha, shortSHA, subject }

    func selectedCommitRows() -> [Int] {
        tableView.selectedRowIndexes.compactMap { row in
            if case .commit(let index) = displayRow(row) { return index }
            return nil
        }
    }

    // MARK: - Column persistence

    private func savedColumnWidths() -> [String: CGFloat] {
        guard case .object(let values) = tab.ui[Self.columnsKey] else { return [:] }
        return values.compactMapValues { if case .number(let width) = $0 { CGFloat(width) } else { nil } }
    }

    func columnResized() {
        var values: [String: JSONValue] = [:]
        for column in tableView.tableColumns where column.identifier != Self.columnGraph {
            values[column.identifier.rawValue] = .number(Double(column.width))
        }
        tab.ui[Self.columnsKey] = .object(values)
        model.scheduleSave()
    }

    // MARK: - State for the bar and overlays

    /// Observed by the overlay: loading skeleton, empty state, error banner.
    func updatePaneState() {
        guard let history else { return }
        let state: GraphViewModel.PaneState =
            history.snapshot.count > 0
            ? .ready : history.snapshot.complete ? .empty : history.error == nil ? .loading : .ready
        if viewModel.paneState != state { viewModel.paneState = state }
        if viewModel.historyError != history.error { viewModel.historyError = history.error }
    }

    var isLoadingFirstPage: Bool {
        (history?.snapshot.count ?? 0) == 0 && (history?.isLoading ?? true) && history?.error == nil
    }
    var isSlow: Bool { history?.isSlow ?? false }
    var historyError: GitCoreError? { history?.error }
    var isEmptyHistory: Bool { (history?.snapshot.complete ?? false) && (history?.snapshot.count ?? 0) == 0 }
    var loadedCount: Int { snapshot.count }

    func retry() { history?.retry() }
}

// MARK: - Data source & delegate

extension GraphViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount = computeRowCount()
        return rowCount
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view =
            tableView.makeView(withIdentifier: GraphTableView.rowIdentifier, owner: nil) as? GraphRowView
            ?? GraphRowView()
        view.identifier = GraphTableView.rowIdentifier
        view.resetHover()
        view.isSearchMatch = isMatch(row)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let kind = displayRow(row) else { return nil }
        let id = tableColumn.identifier
        switch id {
        case Self.columnGraph:
            let cell = reuse(GraphCellView.self, id: id)
            switch kind {
            case .wip:
                let lane = Int(snapshot.headLane() ?? 0)
                cell.content = .wip(lane: lane, color: snapshot.headRow.map { snapshot.row($0).nodeColor } ?? 0)
            case .commit(let index):
                let commit = snapshot.row(index)
                if isFlat {
                    cell.content = .flat(isMerge: commit.isMerge)
                } else {
                    let headCommit = currentRefs?.head.commit
                    cell.content = .commit(
                        commit, isHead: commit.oid == headCommit, wipAbove: showsWIP && index == snapshot.headRow,
                        dimmed: false)
                }
            case .footer:
                cell.content = .empty
            }
            return cell
        case Self.columnSubject:
            let cell = reuse(SubjectCellView.self, id: id)
            var content = SubjectCellView.Content()
            switch kind {
            case .wip:
                content.subject = "Uncommitted changes"
                content.style = .placeholder
                if let summary = session.status?.summary {
                    var parts: [String] = []
                    if summary.staged > 0 { parts.append("\(summary.staged) staged") }
                    if summary.unstaged > 0 { parts.append("\(summary.unstaged) unstaged") }
                    if summary.untracked > 0 { parts.append("\(summary.untracked) untracked") }
                    if summary.conflicted > 0 { parts.append("\(summary.conflicted) conflicted") }
                    content.trailing = parts.joined(separator: " · ")
                }
            case .commit(let index):
                if let display = cache.display(index) {
                    content.subject = display.subject
                    content.labels = display.labels
                    content.labelColor = snapshot.row(index).nodeColor
                }
            case .footer:
                content.style = .footer
                let count = snapshot.count.formatted()
                content.subject =
                    snapshot.isShallow
                    ? "Shallow history — earlier commits not fetched · \(count) commits"
                    : "Beginning of history · \(count) commits"
            }
            cell.content = content
            return cell
        case Self.columnAuthor:
            let cell = reuse(AuthorCellView.self, id: id)
            if case .commit(let index) = kind, let display = cache.display(index) {
                cell.initials = display.initials
                cell.slot = display.avatarSlot
                cell.name = display.authorName
                cell.toolTip = "\(display.authorName) <\(display.authorEmail)>"
            } else {
                cell.name = ""
                cell.toolTip = nil
            }
            cell.needsDisplay = true
            return cell
        case Self.columnDate, Self.columnSHA:
            let cell = reuse(TextCellView.self, id: id)
            cell.monospaced = id == Self.columnSHA
            if case .commit(let index) = kind, let display = cache.display(index) {
                cell.text = id == Self.columnSHA ? display.shortSHA : display.date
                cell.toolTip = id == Self.columnDate ? display.dateTooltip : nil
            } else {
                cell.text = ""
                cell.toolTip = nil
            }
            return cell
        default:
            return nil
        }
    }

    private func reuse<V: NSView>(_ type: V.Type, id: NSUserInterfaceItemIdentifier) -> V {
        if let view = tableView.makeView(withIdentifier: id, owner: nil) as? V {
            assignStyle(view)
            return view
        }
        let view = V(frame: .zero)
        view.identifier = id
        assignStyle(view)
        return view
    }

    private func assignStyle(_ view: NSView) {
        switch view {
        case let cell as GraphCellView: cell.style = style
        case let cell as SubjectCellView: cell.style = style
        case let cell as AuthorCellView: cell.style = style
        case let cell as TextCellView: cell.style = style
        default: break
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        displayRow(row) != .footer
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        var rows = tableView.selectedRowIndexes
        // Compare takes exactly two commits; a third replaces the oldest selection.
        var commits: [ObjectID] = []
        var wip = false
        for row in rows {
            switch displayRow(row) {
            case .wip: wip = true
            case .commit(let index): commits.append(snapshot.row(index).oid)
            default: break
            }
        }
        let previous = viewModel.selection
        var ordered = previous.filter { commits.contains($0) }
        for oid in commits where !ordered.contains(oid) { ordered.append(oid) }
        if ordered.count + (wip ? 1 : 0) > 2 {
            ordered = Array(ordered.suffix(wip ? 1 : 2))
            rows = IndexSet(ordered.compactMap { oid in snapshot.row(for: oid).flatMap { tableRow(forCommit: $0) } })
            if wip { rows.insert(0) }
            isSyncingSelection = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isSyncingSelection = false
        }
        viewModel.selection = ordered
        viewModel.wipSelected = wip
        actions.selectionChanged(viewModel)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            column.identifier != Self.columnGraph
        else { return }
        columnResized()
    }
}

// MARK: - Context menus (design §3.6)

extension GraphViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, let kind = displayRow(row) else { return }
        guard case .commit(let index) = kind else { return }  // WIP row: no copy actions
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        let commit = snapshot.row(index)
        func item(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        // A ref label under the cursor adds label actions first.
        if let label = labelUnderClick(row: row), let fullName = label.fullName {
            item("Copy Name") { Pasteboard.copy(label.text) }
            let pinned = viewModel.pinned.contains(fullName)
            item(pinned ? "Unpin" : "Pin to Left") { [weak self] in self?.togglePin(fullName) }
            item("Solo \(label.text)") { [weak self] in self?.solo(fullName) }
            item("Show in Navigator") { [weak self] in self?.actions.showInNavigator(fullName) }
            menu.addItem(.separator())
        }
        item("Copy SHA") { [weak self] in self?.copySelection(.sha) }
        item("Copy Short SHA") { [weak self] in self?.copySelection(.shortSHA) }
        item("Copy Subject") { [weak self] in self?.copySelection(.subject) }
        menu.addItem(.separator())
        if session.info?.topLevel != nil {
            item("Compare with Working Directory") { [weak self] in
                guard let self else { return }
                self.viewModel.selection = [commit.oid]
                self.viewModel.wipSelected = true
                if self.showsWIP {
                    self.isSyncingSelection = true
                    self.tableView.selectRowIndexes([0, row], byExtendingSelection: false)
                    self.isSyncingSelection = false
                }
                self.actions.selectionChanged(self.viewModel)
            }
        }
        if let other = viewModel.selection.first(where: { $0 != commit.oid }) {
            item("Compare with Selected") { [weak self] in
                guard let self else { return }
                self.viewModel.selection = [other, commit.oid]
                self.restoreSelection()
                self.actions.selectionChanged(self.viewModel)
            }
        }
        if let branch = cache.labels(for: commit.oid).first(where: { $0.fullName != nil && $0.kind != .tag }),
            let fullName = branch.fullName, labelUnderClick(row: row) == nil
        {
            item("Solo \(branch.text)") { [weak self] in self?.solo(fullName) }
        }
    }

    private func labelUnderClick(row: Int) -> RefLabel? {
        guard let event = NSApp.currentEvent,
            let column = tableView.tableColumns.firstIndex(where: { $0.identifier == Self.columnSubject }),
            let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? SubjectCellView
        else { return nil }
        let point = cell.convert(event.locationInWindow, from: nil)
        return cell.label(at: point)?.label
    }
}

/// A menu item that runs a closure (context menus built per click).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

enum Pasteboard {
    @MainActor static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// The graph pane's root view: opaque canvas.
final class GraphRootView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ColorToken.surfaceCanvas.nsColor.setFill()
        dirtyRect.fill()
    }
}

/// Keyboard, copy and hover for the graph table.
final class GraphTableView: NSTableView {
    static let rowIdentifier = NSUserInterfaceItemIdentifier("graphRow")
    weak var controller: GraphViewController?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        controller?.mouseMoved(toRow: row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.mouseMoved(toRow: nil)
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection(.sha)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !(controller?.selectedCommitRows().isEmpty ?? true) }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:  // Esc
            controller?.clearModes()
        case 126 where modifiers.contains(.command):  // ⌘↑
            guard numberOfRows > 0 else { return }
            selectRowIndexes([0], byExtendingSelection: false)
            scrollRowToVisible(0)
        case 125 where modifiers.contains(.command):  // ⌘↓
            guard numberOfRows > 0 else { return }
            selectRowIndexes([numberOfRows - 1], byExtendingSelection: false)
            scrollRowToVisible(numberOfRows - 1)
        default:
            super.keyDown(with: event)
        }
    }
}

extension GraphViewController: NSMenuItemValidation {}
