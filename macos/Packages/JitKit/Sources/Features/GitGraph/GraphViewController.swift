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
        /// Esc with nothing left to clear in the graph (the workbench closes a manually opened inspector).
        var escapeUnhandled: () -> Void = {}
        /// Esc is offered here first (an open diff closes without touching the selection); `true` = handled.
        var interceptEscape: () -> Bool = { false }
    }

    let session: RepositorySession
    let tab: TabModel
    let model: AppModel
    let viewModel = GraphViewModel()
    var actions = Actions()
    /// Phase 4 write actions (context menus, command bar, banner).
    var operations: OperationsController?

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
    /// Rows whose branch cell shows the ghost label of their line (hovered and selected rows).
    private var ghostRows = Set<Int>()
    /// The widest graph the automatic column width shows, in lanes.
    static let automaticLaneLimit = 10
    private let refsHover = RefsHoverView()
    private var columns = GraphColumnLayout()
    private let columnsMenu = NSMenu()
    private var isLiveScrolling = false
    private var deepSearchTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var observationArmed = false
    private var lastQuery: HistoryQuery?

    /// `graph.firstPage`: history start → first rows on screen.
    private var firstPageSignpost: Signposts.Token?

    static let columnRefs = NSUserInterfaceItemIdentifier("refs")
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
        if let saved = tab.ui[Self.columnsKey] {
            columns = GraphColumnLayout(json: saved)
        } else if let data = model.preferences.graphColumns,
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            columns = GraphColumnLayout(json: value)
        }
        let avatars = model.avatars
        style.photo = { [weak avatars] email in avatars?.image(for: email) }
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
        observers.append(
            center.addObserver(forName: AvatarStore.didLoad, object: model.avatars, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.redrawNodes() }
            })
    }

    /// A picture arrived: the nodes on screen redraw (no reload, no strings rebuilt).
    private func redrawNodes() {
        let visible = tableView.rows(in: tableView.visibleRect)
        let column = tableView.column(withIdentifier: Self.columnGraph)
        guard column >= 0, visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            tableView.view(atColumn: column, row: row, makeIfNecessary: false)?.needsDisplay = true
        }
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

    /// The message column takes whatever the others leave (no horizontal scrolling). In narrow layouts the
    /// SHA column hides first, then author, branch and date narrow (design §3.1). Widths set here are layout,
    /// not the user's choice: never persisted.
    private func fitSubjectColumn() {
        guard !isFittingColumns else { return }
        isFittingColumns = true
        defer { isFittingColumns = false }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        var fixed: [GraphColumnLayout.Column: CGFloat] = [:]
        if let graph = tableView.tableColumn(withIdentifier: Self.columnGraph) { fixed[.graph] = graph.width }
        let fitted = columns.fitted(available: available, fixed: fixed)
        for column in tableView.tableColumns {
            guard let kind = GraphColumnLayout.Column(rawValue: column.identifier.rawValue) else { continue }
            let hidden = columns.hidden.contains(kind) || fitted.autoHidden.contains(kind)
            if column.isHidden != hidden { column.isHidden = hidden }
            if kind != .graph, let width = fitted.widths[kind], abs(column.width - width) > 0.5 {
                column.width = width
            }
        }
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

        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        let header = NSTableHeaderView()
        columnsMenu.delegate = self
        header.menu = columnsMenu
        tableView.headerView = header
        for kind in columns.order {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(kind.rawValue))
            column.title = kind.title
            column.width = columns.width(kind)
            column.minWidth = kind.minWidth
            column.resizingMask = .userResizingMask
            column.isHidden = columns.hidden.contains(kind)
            column.headerToolTip =
                kind == .graph
                ? "Drag the edge to set the graph's width · Reset Columns sizes it to the branches again"
                : "Drag to reorder · right-click to show or hide columns"
            tableView.addTableColumn(column)
        }
    }

    /// The header's context menu: one checkmark item per column.
    private func buildColumnsMenu() {
        columnsMenu.removeAllItems()
        for kind in GraphColumnLayout.Column.allCases {
            let item = ClosureMenuItem(title: kind.title) { [weak self] in
                guard let self else { return }
                self.columns.setHidden(kind, !self.columns.hidden.contains(kind))
                self.columnsChanged()
            }
            item.state = columns.hidden.contains(kind) ? .off : .on
            if !kind.canHide {
                item.action = nil
                item.target = nil
            }
            columnsMenu.addItem(item)
        }
        columnsMenu.addItem(.separator())
        columnsMenu.addItem(
            ClosureMenuItem(title: "Reset Columns") { [weak self] in
                guard let self else { return }
                self.columns = GraphColumnLayout()
                for (index, kind) in self.columns.order.enumerated() {
                    let current = self.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(kind.rawValue))
                    if current >= 0, current != index { self.tableView.moveColumn(current, toColumn: index) }
                }
                self.columnsChanged()
            })
    }

    /// Order, visibility or a preferred width changed: persist, re-fit and redraw.
    private func columnsChanged() {
        refsHover.hide(animated: false)
        tab.ui[Self.columnsKey] = columns.json
        model.preferences.graphColumns = try? JSONEncoder().encode(columns.json)
        model.scheduleSave()
        updateGraphColumnWidth()
        fitSubjectColumn()
        redrawVisibleRows()
    }

    /// The branch column's connector reaches the node only when the graph column comes right after it.
    private var refsConnectToGraph: Bool {
        let visible = tableView.tableColumns.filter { !$0.isHidden }.map(\.identifier)
        guard let refs = visible.firstIndex(of: Self.columnRefs) else { return false }
        return refs + 1 < visible.count && visible[refs + 1] == Self.columnGraph
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
        GraphBenchmark.noteHistoryStart()
        firstPageSignpost = Signposts.begin(Signposts.graphFirstPage)
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
            // Match indices belong to the old history: recompute before the table reloads.
            if viewModel.isSearching {
                viewModel.matches = snapshot.search(HistorySearchQuery(viewModel.searchText), refs: history.refs)
                matchSet = Set(viewModel.matches)
            }
            maxLanes = 1
            scannedRows = 0
            scanLanes(from: 0)
            reloadPreservingSelection(previous: previous)
            if snapshot.count > 0 {
                view.window?.displayIfNeeded()
                GraphBenchmark.noteFirstRows()
                firstRowsShown()
            }
            if viewModel.isSearching { recomputeMatches(scroll: false) }
        case .labels:
            updateWIP()
            redrawVisibleRows()
        }
        updatePaneState()
        visibleRangeChanged()
        #if DEBUG
            applyDebugLaunchState()
        #endif
    }

    /// The graph column's automatic width follows the widest row of every loaded commit (up to
    /// `automaticLaneLimit` lanes): it can grow when more history loads, and never changes with the scroll
    /// position. A width the user dragged replaces it.
    private func scanLanes(from start: Int) {
        var widest = maxLanes
        let first = max(0, min(start, scannedRows))
        if first < snapshot.count {
            for index in first..<snapshot.count { widest = max(widest, Int(snapshot.row(index).width)) }
        }
        scannedRows = snapshot.count
        if widest != maxLanes {
            maxLanes = widest
            updateGraphColumnWidth()
        }
    }

    private func updateGraphColumnWidth() {
        guard let column = tableView.tableColumn(withIdentifier: Self.columnGraph) else { return }
        let flat = viewModel.filterMode == .onlyMatches && viewModel.isSearching
        let width: CGFloat
        if let chosen = columns.widths[.graph], !flat {
            width = chosen.rounded()
        } else {
            let needed = style.metrics.columnWidth(lanes: flat ? 1 : min(maxLanes, Self.automaticLaneLimit))
            let limit = max(
                GraphColumnLayout.Column.graph.minWidth, tableView.bounds.width * style.metrics.maxGraphShare)
            width = max(GraphColumnLayout.Column.graph.minWidth, min(needed, limit)).rounded()
        }
        if abs(column.width - width) > 0.5 {
            let wasFitting = isFittingColumns
            isFittingColumns = true
            column.width = width
            isFittingColumns = wasFitting
            fitSubjectColumn()
        }
    }

    // MARK: - Row mapping

    var isFlat: Bool { viewModel.filterMode == .onlyMatches && viewModel.isSearching }

    func displayRow(_ row: Int) -> DisplayRow? {
        if isFlat {
            guard row < viewModel.matches.count else { return nil }
            let index = Int(viewModel.matches[row])
            return index < snapshot.count ? .commit(index) : nil
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
            tableView.reloadData(
                forRowIndexes: [row], columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        }
    }

    private func appendRows() {
        let interval = Signposts.begin(Signposts.graphPage)
        let started = ContinuousClock.now
        defer {
            Signposts.end(interval)
            if snapshot.count > 0 { firstRowsShown() }
            GraphBenchmark.appendSamples?.append(GraphBenchmark.ms(ContinuousClock.now - started))
        }
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

    // MARK: Accessibility rotors (design §3.6)

    enum GraphRotor: String, CaseIterable {
        case refs = "Branches and Tags"
        case merges = "Merge Commits"
        case head = "HEAD"
    }

    /// The next loaded commit (from table row `row`, in `forward` direction) the rotor stops at, as a table row.
    /// Only loaded rows are searched — no history scan from accessibility.
    func rotorRow(_ rotor: GraphRotor, from row: Int?, forward: Bool) -> Int? {
        let count = snapshot.count
        guard count > 0 else { return nil }
        var start = forward ? 0 : count - 1
        if let row, case .commit(let index) = displayRow(row) { start = forward ? index + 1 : index - 1 }
        var index = start
        while index >= 0, index < count {
            let matches: Bool =
                switch rotor {
                case .refs: !cache.labels(for: snapshot.row(index).oid).isEmpty
                case .merges: snapshot.row(index).isMerge
                case .head: snapshot.headRow == index
                }
            if matches { return tableRow(forCommit: index) }
            index += forward ? 1 : -1
        }
        return nil
    }

    /// Breaks the controller → view → hosting view → SwiftUI view → controller cycles of the command bar and the
    /// state overlay, and stops history work. Called once when the tab's workbench is removed for good.
    func tearDown() {
        barHost?.removeFromSuperview()
        overlayHost?.removeFromSuperview()
        barHost = nil
        overlayHost = nil
        history?.onUpdate = nil
        history = nil
    }

    /// Ends `graph.firstPage` and the tab's `repo.open` once rows are on screen.
    private func firstRowsShown() {
        if let token = firstPageSignpost {
            firstPageSignpost = nil
            Signposts.end(token)
        }
        if let token = tab.openSignpost {
            tab.openSignpost = nil
            Signposts.end(token)
        }
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
        refsHover.hide(animated: false)
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
    private var isFittingColumns = false

    private func redrawVisibleRows() {
        refsHover.hide(animated: false)
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let range = max(0, visible.location - 8)..<min(tableView.numberOfRows, visible.location + visible.length + 8)
        tableView.reloadData(forRowIndexes: IndexSet(range), columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        for row in range {
            let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? GraphRowView
            rowView?.isSearchMatch = isMatch(row)
            rowView?.timeTag = timeTag(forRow: row)
        }
    }

    /// The age tag of a row: set on the first row of each age group ("7 hours ago", "yesterday", …).
    private func timeTag(forRow row: Int) -> String? {
        guard case .commit(let index) = displayRow(row), let display = cache.display(index) else { return nil }
        if row > 0, case .commit(let above) = displayRow(row - 1), let previous = cache.display(above),
            previous.timeBucket == display.timeBucket
        {
            return nil
        }
        return display.timeBucket
    }

    // MARK: - Branch of the line (hovered and selected rows)

    /// The dimmed label a row without labels of its own shows while hovered or selected: the branch whose
    /// line the commit sits on.
    private func ghostLabel(forRow row: Int) -> (label: RefLabel, strength: CGFloat)? {
        let selected = tableView.selectedRowIndexes.contains(row)
        guard selected || row == hoveredRow, !isFlat, case .commit(let index) = displayRow(row),
            let display = cache.display(index), display.labels.isEmpty, let label = cache.lineLabel(above: index)
        else { return nil }
        return (label, selected ? RefsCellView.ghostSelected : RefsCellView.ghostHovered)
    }

    private func refreshGhosts() {
        var wanted = Set(tableView.selectedRowIndexes)
        if let hoveredRow { wanted.insert(hoveredRow) }
        let column = tableView.column(withIdentifier: Self.columnRefs)
        guard column >= 0 else { return }
        for row in wanted.union(ghostRows) where row < tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? RefsCellView
            else { continue }
            let ghost = ghostLabel(forRow: row)
            if cell.content.ghost != ghost?.label || cell.content.ghostStrength != (ghost?.strength ?? 0) {
                cell.content.ghost = ghost?.label
                cell.content.ghostStrength = ghost?.strength ?? 0
            }
        }
        ghostRows = wanted
    }

    private func visibleRangeChanged() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard let history, visible.length > 0 else { return }
        var last = visible.location + visible.length
        if showsWIP { last -= 1 }
        if !isFlat { history.visibleRowsChanged(lastVisibleRow: max(0, last)) }
    }

    private func liveScroll(started: Bool) {
        isLiveScrolling = started
        if started { refsHover.hide(animated: false) }
        if started, let hoveredRow {
            (tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? GraphRowView)?.resetHover()
            self.hoveredRow = nil
            refreshGhosts()
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
        refsHover.hide(animated: false)
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

    #if DEBUG
        private var appliedDebugState = false

        /// Debug-only launch arguments for repeatable screenshots and real-workflow checks without pointer
        /// automation: `-JitGraphSearch <text>`, `-JitGraphOnlyMatches YES`, `-JitGraphSelectRow <n>`
        /// (`-JitGraphCompareRow <m>` adds a second commit), `-JitGraphSelectWIP YES`.
        private func applyDebugLaunchState() {
            guard !appliedDebugState, snapshot.count > 0 else { return }
            appliedDebugState = true
            let defaults = UserDefaults.standard
            if let search = defaults.string(forKey: "JitGraphSearch") {
                viewModel.searchText = search
                searchTextChanged()
                if defaults.bool(forKey: "JitGraphOnlyMatches") { setFilterMode(.onlyMatches) }
            }
            if defaults.bool(forKey: "JitGraphSelectWIP"), showsWIP {
                viewModel.selection = []
                viewModel.wipSelected = true
                tableView.selectRowIndexes([0], byExtendingSelection: false)
                actions.selectionChanged(viewModel)
            }
            if defaults.object(forKey: "JitGraphSelectRow") != nil {
                let first = defaults.integer(forKey: "JitGraphSelectRow")
                var rows = IndexSet(integer: first)
                if defaults.object(forKey: "JitGraphCompareRow") != nil {
                    rows.insert(defaults.integer(forKey: "JitGraphCompareRow"))
                }
                tableView.selectRowIndexes(rows, byExtendingSelection: false)
                tableView.scrollRowToVisible(first)
            }
            // `-JitGraphHoverRow <n>`: the row's ref labels expanded, as if the pointer were over them.
            if defaults.object(forKey: "JitGraphHoverRow") != nil {
                let row = defaults.integer(forKey: "JitGraphHoverRow")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self else { return }
                    let column = self.tableView.column(withIdentifier: Self.columnRefs)
                    guard column >= 0, row < self.tableView.numberOfRows else { return }
                    let frame = self.tableView.frameOfCell(atColumn: column, row: row)
                    self.mouseMoved(toRow: row, at: NSPoint(x: frame.midX, y: frame.midY))
                }
            }
        }
    #endif

    // MARK: - Menu commands (responder chain)

    @objc func jitFind(_ sender: Any?) { viewModel.focusSearchToken += 1 }
    @objc func jitFindNext(_ sender: Any?) { nextMatch(forward: true) }
    @objc func jitFindPrevious(_ sender: Any?) { nextMatch(forward: false) }

    @objc func toggleCommandBarLabels(_ sender: Any?) {
        model.preferences.commandBarShowsLabels.toggle()
    }

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
        case #selector(toggleCommandBarLabels(_:)):
            item.state = model.preferences.commandBarShowsLabels ? .on : .off
            return true
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

    func mouseMoved(toRow row: Int?, at point: NSPoint? = nil) {
        updateRefsHover(row: row, point: point)
        guard !isLiveScrolling, row != hoveredRow else { return }
        if let hoveredRow {
            (tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? GraphRowView)?.isHovered = false
        }
        hoveredRow = row
        if let row { (tableView.rowView(atRow: row, makeIfNecessary: false) as? GraphRowView)?.isHovered = true }
        refreshGhosts()
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
        viewModel.matches = query.isEmpty ? [] : snapshot.search(query, refs: history?.refs)
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

    /// Command bar ▸ changes: selects the working-directory row (scrolled to the top). Returns `false` when
    /// the graph shows no WIP row (clean tree, or HEAD outside the current scope).
    @discardableResult
    func selectWorkingDirectory() -> Bool {
        guard showsWIP, !isFlat else { return false }
        viewModel.selection = []
        viewModel.wipSelected = true
        isSyncingSelection = true
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        isSyncingSelection = false
        scrollToRow(0)
        view.window?.makeFirstResponder(tableView)
        actions.selectionChanged(viewModel)
        return true
    }

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
                let before = self.snapshot.count
                await history.loadRows(atLeast: self.snapshot.count + 10_000)
                // No progress (tab hidden or closed, reader failed): stop instead of spinning.
                if Task.isCancelled || self.snapshot.count == before { return }
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
        } else if !clearSelection() {
            // Nothing selected: the workbench closes a manually opened inspector. Clearing a selection
            // closes it through `selectionChanged`.
            actions.escapeUnhandled()
        }
    }

    /// Deselects every row (graph and WIP). Returns false when nothing was selected.
    @discardableResult
    func clearSelection() -> Bool {
        guard !tableView.selectedRowIndexes.isEmpty else { return false }
        tableView.deselectAll(nil)
        return true
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

    /// A comparison reads older → newer: the commit further down the graph first.
    func compareOrder(_ selection: [ObjectID]) -> [ObjectID] {
        guard selection.count == 2, let a = snapshot.row(for: selection[0]), let b = snapshot.row(for: selection[1]),
            a < b
        else { return selection }
        return [selection[1], selection[0]]
    }

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

    // MARK: - Columns (resize, reorder)

    /// The user dragged a column edge. The message column has no width of its own, so dragging its edge
    /// resizes the column after it (or before it, when it is last) the other way.
    fileprivate func userResized(_ column: NSTableColumn, oldWidth: CGFloat?) {
        guard let kind = GraphColumnLayout.Column(rawValue: column.identifier.rawValue) else { return }
        if kind == .subject {
            guard let oldWidth else { return }
            let delta = column.width - oldWidth
            let visible = tableView.tableColumns.filter { !$0.isHidden }
            guard let index = visible.firstIndex(of: column) else { return }
            let candidates = Array(visible[(index + 1)...]) + Array(visible[..<index].reversed())
            guard
                let neighbor = candidates.first(where: { $0.identifier != Self.columnGraph }),
                let neighborKind = GraphColumnLayout.Column(rawValue: neighbor.identifier.rawValue)
            else { return }
            columns.widths[neighborKind] = max(neighborKind.minWidth, neighbor.width - delta)
        } else {
            columns.widths[kind] = column.width
        }
        refsHover.hide(animated: false)
        tab.ui[Self.columnsKey] = columns.json
        model.preferences.graphColumns = try? JSONEncoder().encode(columns.json)
        model.scheduleSave()
        updateGraphColumnWidth()
        fitSubjectColumn()
    }

    fileprivate func userMovedColumn() {
        let order = tableView.tableColumns.compactMap { GraphColumnLayout.Column(rawValue: $0.identifier.rawValue) }
        guard order != columns.order, order.count == columns.order.count else { return }
        columns.order = order
        columnsChanged()
    }

    // MARK: - Ref label hover

    /// Shows every label of the row under the pointer, in full, while it is over the branch column (or over
    /// the expanded labels themselves).
    private func updateRefsHover(row: Int?, point: NSPoint?) {
        let column = tableView.column(withIdentifier: Self.columnRefs)
        guard let row, let point, !isLiveScrolling, column >= 0, !tableView.tableColumns[column].isHidden,
            case .commit(let index) = displayRow(row), let display = cache.display(index), !display.labels.isEmpty
        else {
            refsHover.hide()
            return
        }
        let cellFrame = tableView.frameOfCell(atColumn: column, row: row)
        let showing = refsHover.row == row && !refsHover.isHidden
        guard cellFrame.contains(point) || (showing && refsHover.frame.contains(point)) else {
            refsHover.hide()
            return
        }
        guard !showing else { return }
        refsHover.show(
            row: row, labels: display.labels, slot: isFlat ? 0 : snapshot.row(index).nodeColor,
            isSelected: tableView.selectedRowIndexes.contains(row), style: style, cellFrame: cellFrame,
            maxWidth: tableView.visibleRect.maxX - cellFrame.minX, in: tableView)
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
        view.timeTag = timeTag(forRow: row)
        // VoiceOver reads the row as one element (design §3.8); the lane drawing is decorative.
        switch displayRow(row) {
        case .commit(let index): view.setAccessibilityLabel(cache.display(index)?.accessibilityLabel)
        case .wip: view.setAccessibilityLabel("Uncommitted changes")
        case .footer: view.setAccessibilityLabel("Beginning of history, \(snapshot.count) commits")
        case nil: view.setAccessibilityLabel(nil)
        }
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
                var decor = NodeDecor()
                if let display = cache.display(index) {
                    decor.initials = display.initials
                    decor.email = display.authorEmail
                    decor.toolTip = "\(display.authorName)\n\(display.authorEmail)\n\(display.date)"
                    decor.avatarSlot = display.avatarSlot
                    decor.hasRefs = !display.labels.isEmpty && refsConnectToGraph
                }
                if isFlat {
                    cell.content = .flat(isMerge: commit.isMerge, color: 0, decor)
                } else {
                    decor.wipAbove = showsWIP && index == snapshot.headRow
                    cell.content = .commit(commit, decor)
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
                if let display = cache.display(index) { content.subject = display.subject }
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
        case Self.columnRefs:
            let cell = reuse(RefsCellView.self, id: id)
            var content = RefsCellView.Content()
            if case .commit(let index) = kind, let display = cache.display(index) {
                content.labels = display.labels
                content.labelColor = isFlat ? 0 : snapshot.row(index).nodeColor
            }
            content.connects = refsConnectToGraph
            if let ghost = ghostLabel(forRow: row) {
                content.ghost = ghost.label
                content.ghostStrength = ghost.strength
            }
            cell.content = content
            return cell
        case Self.columnAuthor:
            let cell = reuse(AuthorCellView.self, id: id)
            if case .commit(let index) = kind, let display = cache.display(index) {
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
        case let cell as RefsCellView: cell.style = style
        case let cell as AuthorCellView: cell.style = style
        case let cell as TextCellView: cell.style = style
        default: break
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        displayRow(row) != .footer
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refsHover.hide(animated: false)
        refreshGhosts()
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
            !isFittingColumns
        else { return }
        userResized(
            column, oldWidth: (notification.userInfo?["NSOldWidth"] as? NSNumber).map { CGFloat($0.doubleValue) })
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        userMovedColumn()
    }
}

// MARK: - Context menus (design §3.6)

extension GraphViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === columnsMenu {
            buildColumnsMenu()
            return
        }
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, let kind = displayRow(row) else { return }
        guard case .commit(let index) = kind else { return }  // WIP row: no copy actions
        let previousSelection = viewModel.selection
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        let commit = snapshot.row(index)
        func item(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        // A ref label under the cursor adds label actions first.
        let pill = pillUnderClick(row: row)
        if let label = pill?.label, let fullName = label.fullName {
            labelItems(label, fullName: fullName).forEach(menu.addItem)
            menu.addItem(.separator())
        } else if pill?.isOverflow == true {
            // `+N`: every ref on this commit, each with its own actions.
            for label in cache.labels(for: commit.oid) {
                guard let fullName = label.fullName else { continue }
                let parent = NSMenuItem(title: label.text, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: label.text)
                labelItems(label, fullName: fullName).forEach(submenu.addItem)
                parent.submenu = submenu
                menu.addItem(parent)
            }
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
        if let other = previousSelection.last(where: { $0 != commit.oid }) {
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
        if let operations, session.info?.topLevel != nil {
            commitWriteItems(commit.oid.hex(snapshot.format), operations: operations).forEach(menu.addItem)
        }
    }

    /// Phase 4 write actions on a commit (design §3.6–§3.7, §3.10).
    private func commitWriteItems(_ hex: String, operations: OperationsController) -> [NSMenuItem] {
        let short = String(hex.prefix(7))
        let current = operations.currentBranch ?? "HEAD"
        let isHead = session.status?.branch.oid == hex
        let selected = selectedCommitRows().map { snapshot.row($0).oid.hex(snapshot.format) }
        var items: [NSMenuItem] = [.separator()]
        items.append(ClosureMenuItem(title: "Check Out \(short)…") { operations.switchTo(.detach(hex)) })
        items.append(ClosureMenuItem(title: "New Branch Here…") { operations.newBranch(at: hex, label: short) })
        items.append(.separator())
        if !isHead {
            items.append(
                ClosureMenuItem(title: "Merge \(short) into \(current)…") {
                    operations.merge(source: hex, label: short)
                })
            items.append(
                ClosureMenuItem(title: "Rebase \(current) onto \(short)…") {
                    operations.rebase(onto: hex, label: short)
                })
            let picks = selected.contains(hex) ? selected : [hex]
            items.append(
                ClosureMenuItem(title: picks.count == 1 ? "Cherry-pick \(short)" : "Cherry-pick \(picks.count) Commits")
                {
                    operations.cherryPick(picks)
                })
        }
        items.append(ClosureMenuItem(title: "Revert \(short)") { operations.revert(hex) })
        if let remote = operations.webRemoteURL, let url = WebLink.map(remoteURL: remote, target: .commit(hex)) {
            items.append(.separator())
            items.append(
                ClosureMenuItem(title: "Copy Link to Commit on \(url.host == "gitlab.com" ? "GitLab" : "GitHub")") {
                    Pasteboard.copy(url.absoluteString)
                })
        }
        return items
    }

    private func labelUnderClick(row: Int) -> RefLabel? { pillUnderClick(row: row)?.label }

    /// The pill under the click in the ref column; `isOverflow` for the `+N` pill.
    private func pillUnderClick(row: Int) -> (label: RefLabel?, isOverflow: Bool)? {
        guard let event = NSApp.currentEvent else { return nil }
        if refsHover.row == row, !refsHover.isHidden {
            // The expanded labels cover the cell: the click is on what is shown.
            let point = refsHover.convert(event.locationInWindow, from: nil)
            return refsHover.label(at: point).map { ($0, false) }
        }
        guard
            let column = tableView.tableColumns.firstIndex(where: { $0.identifier == Self.columnRefs }),
            let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? RefsCellView
        else { return nil }
        let point = cell.convert(event.locationInWindow, from: nil)
        return cell.label(at: point)
    }

    /// Copy / pin / solo / navigator actions for one ref label.
    private func labelItems(_ label: RefLabel, fullName: String) -> [NSMenuItem] {
        let pinned = viewModel.pinned.contains(fullName)
        var write: [NSMenuItem] = []
        if let operations, let ref = operations.refs?.ref(named: fullName) {
            write = NavigatorViewController.branchWriteItems(ref, operations: operations) + [.separator()]
        }
        return write + [
            ClosureMenuItem(title: "Copy Name") { Pasteboard.copy(label.text) },
            ClosureMenuItem(title: pinned ? "Unpin" : "Pin to Left") { [weak self] in self?.togglePin(fullName) },
            ClosureMenuItem(title: "Solo \(label.text)") { [weak self] in self?.solo(fullName) },
            ClosureMenuItem(title: "Show in Navigator") { [weak self] in self?.actions.showInNavigator(fullName) },
        ]
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
final class GraphTableView: NSTableView, @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    static let rowIdentifier = NSUserInterfaceItemIdentifier("graphRow")
    weak var controller: GraphViewController?

    /// VoiceOver rotors: Branches and Tags, Merge Commits, HEAD (the lane drawing is decorative; topology is
    /// in each row's label).
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        GraphViewController.GraphRotor.allCases.map {
            NSAccessibilityCustomRotor(label: $0.rawValue, itemSearchDelegate: self)
        }
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let kind = GraphViewController.GraphRotor(rawValue: rotor.label) else { return nil }
        let currentView = searchParameters.currentItem?.targetElement as? NSView
        let current = currentView.map { self.row(for: $0) }.flatMap { $0 >= 0 ? $0 : nil }
        let forward = searchParameters.searchDirection == .next
        guard let row = controller?.rotorRow(kind, from: current, forward: forward) else { return nil }
        scrollRowToVisible(row)
        guard let view = rowView(atRow: row, makeIfNecessary: true) else { return nil }
        return NSAccessibilityCustomRotor.ItemResult(targetElement: view)
    }
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
        controller?.mouseMoved(toRow: row >= 0 ? row : nil, at: point)
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
            if controller?.actions.interceptEscape() == true { return }
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
