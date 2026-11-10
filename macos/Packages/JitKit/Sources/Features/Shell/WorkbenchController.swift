import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Actions the workbench views trigger; provided by the window controller.
struct WorkbenchActions {
    var locate: () -> Void
    var removeTab: () -> Void
    var retry: () -> Void
    var revealInFinder: () -> Void
    var openInTerminal: () -> Void
}

/// The three-region workbench (design §3.3): branch navigator on the system glass sidebar, the commit
/// graph (opaque content), and the commit inspector. Widths are global (`LayoutState`); collapse flags belong to the tab.
@MainActor
final class WorkbenchController: NSSplitViewController {
    let tab: TabModel
    let session: RepositorySession
    let model: AppModel
    private let actions: WorkbenchActions
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private(set) var graph: GraphViewController?
    private(set) var navigator: NavigatorViewController?
    let inspectorModel = InspectorModel()
    lazy var diffModel = DiffViewModel(session: session)
    lazy var diffController = DiffViewController(model: diffModel)
    lazy var blameModel = BlameModel(session: session)
    lazy var blameController = BlameViewController(model: blameModel)
    lazy var operations = OperationsController(session: session, model: model)
    private var needsWidthRestore = true
    private var isApplyingWidths = false

    init(tab: TabModel, session: RepositorySession, model: AppModel, actions: WorkbenchActions) {
        self.tab = tab
        self.session = session
        self.model = model
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isSidebarCollapsed: Bool { sidebarItem?.isCollapsed ?? true }
    var sidebarWidth: CGFloat { sidebarItem?.viewController.view.frame.width ?? 0 }
    /// Sidebar collapsed/expanded or resized (the toolbar's tab strip re-measures).
    var onSidebarGeometryChange: (() -> Void)?
    var isInspectorCollapsed: Bool { inspectorItem?.isCollapsed ?? true }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        let navigator = NavigatorViewController(tab: tab, model: model)
        let graph = GraphViewController(session: session, tab: tab, model: model)
        connect(graph: graph, navigator: navigator)
        self.graph = graph
        self.navigator = navigator

        let sidebar = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebar.minimumThickness = PanelMetrics.sidebarMin
        sidebar.maximumThickness = PanelMetrics.sidebarMax
        sidebar.canCollapse = true
        sidebar.isCollapsed = tab.sidebarCollapsed

        let main = NSSplitViewItem(
            viewController: MainPaneController(
                graph: graph, session: session, tab: tab, actions: actions, diffModel: diffModel,
                diffController: diffController, blameModel: blameModel, blameController: blameController,
                operations: operations))
        main.minimumThickness = PanelMetrics.contentColumnMax - 160

        let inspector = NSSplitViewItem(
            inspectorWithViewController: Self.host(CommitInspectorView(model: inspectorModel)))
        inspector.minimumThickness = PanelMetrics.inspectorMin
        inspector.maximumThickness = PanelMetrics.inspectorMax
        inspector.canCollapse = true
        // The inspector opens with a selection and closes without one (design-system.md, Inspector); a
        // fresh tab has nothing selected, so it starts closed whatever the last session left.
        inspector.isCollapsed = true

        addSplitViewItem(sidebar)
        addSplitViewItem(main)
        addSplitViewItem(inspector)
        sidebarItem = sidebar
        inspectorItem = inspector
    }

    /// Graph ↔ navigator ↔ inspector (design §3.4–§3.5).
    private func connect(graph: GraphViewController, navigator: NavigatorViewController) {
        let inspector = inspectorModel
        let workingDirectory = WorkingDirectoryModel(session: session)
        inspector.workingDirectory = workingDirectory
        let composer = CommitComposerModel(session: session, profiles: model.profiles, drafts: model.commitDrafts)
        composer.onCommitted = { [weak graph] hex in
            if let oid = ObjectID(hex: hex) { graph?.select(oid: oid) }
        }
        workingDirectory.composer = composer
        inspector.diff = diffModel
        inspector.diffController = diffController
        inspector.avatars = model.avatars
        let diff = diffModel
        diff.onCloseRequest = { [weak inspector] in inspector?.closeDiff() }
        let blame = blameModel
        blame.revealCommit = { [weak graph, weak blame] oid in
            blame?.close()
            graph?.select(oid: oid)
        }
        // Every cross-model closure captures weakly: the models reference each other through these closures,
        // and a strong capture closes a cycle that outlives the tab (P6.6, ClosedTabDeallocatesTests).
        workingDirectory.openBlame = { [weak blame] path in blame?.open(path: path, revision: nil) }
        inspector.openBlame = { [weak blame] path, oid in blame?.open(path: path, revision: oid) }
        diff.onBlame = { [weak blame] path, oid in blame?.open(path: path, revision: oid) }
        let operations = self.operations
        graph.operations = operations
        navigator.operations = operations
        operations.selectCommit = { [weak graph] oid in graph?.select(oid: oid) }
        operations.inspectCommit = { [weak self, weak inspector] oid in
            inspector?.show(selection: [oid], wip: false)
            self?.setInspectorCollapsed(false)
        }
        observeStashes(navigator: navigator)
        session.loadStashes()
        operations.showWorkingDirectory = { [weak graph] in _ = graph?.selectWorkingDirectory() }
        workingDirectory.openDiff = { [weak diff, weak operations] file in
            guard let file else {
                diff?.close()
                return
            }
            switch file.section {
            case .unstaged: diff?.open(.unstaged(path: file.path))
            case .staged:
                diff?.open(.staged(path: file.path, renamedFrom: file.change == .renamed ? file.originalPath : nil))
            case .conflicts:
                diff?.close()
                operations?.openConflict(path: file.path)
            }
        }
        workingDirectory.openFileHistory = { [weak graph] path in
            graph?.showFileHistory(path: path, isDirectory: false)
        }
        graph.actions.selectionChanged = { [weak self, weak graph, weak inspector] model in
            inspector?.show(selection: graph?.compareOrder(model.selection) ?? model.selection, wip: model.wipSelected)
            self?.setInspectorCollapsed(model.selection.isEmpty && !model.wipSelected)
        }
        let blameForRefs = blameModel
        graph.actions.refsChanged = {
            [weak graph, weak navigator, weak inspector, weak blameForRefs, weak operations] refs in
            navigator?.update(refs: refs)
            navigator?.repository = graph?.history?.repository
            inspector?.handle = graph?.history?.repository
            blameForRefs?.handle = graph?.history?.repository
            inspector?.refs = refs
            inspector?.format = refs.format
            operations?.refs = refs
        }
        graph.actions.escapeUnhandled = { [weak self] in self?.setInspectorCollapsed(true) }
        graph.actions.showInNavigator = { [weak self, weak navigator] fullName in
            if let sidebar = self?.sidebarItem, sidebar.isCollapsed { sidebar.isCollapsed = false }
            navigator?.reveal(fullName: fullName)
        }
        inspector.selectCommit = { [weak graph] oid in graph?.select(oid: oid) }
        inspector.showFileHistory = { [weak graph] path, isDirectory in
            graph?.showFileHistory(path: path, isDirectory: isDirectory)
        }
        navigator.actions = NavigatorViewController.Actions(
            showInGraph: { [weak graph] oid in graph?.select(oid: oid) },
            solo: { [weak graph] name in graph?.solo(name) },
            togglePin: { [weak graph] name in graph?.togglePin(name) },
            isPinned: { [weak graph] name in graph?.viewModel.pinned.contains(name) ?? false })
    }

    /// Stash list changes (FSEvents on refs/stash → session) rebuild the navigator's Stashes section.
    private func observeStashes(navigator: NavigatorViewController) {
        withObservationTracking {
            _ = session.stashes
        } onChange: { [weak self, weak navigator] in
            Task { @MainActor in
                guard let self, let navigator else { return }
                navigator.update(stashes: self.session.stashes)
                self.observeStashes(navigator: navigator)
            }
        }
    }

    private static func host<V: View>(_ view: V) -> NSViewController {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return host
    }

    /// Called when the tab is shown again (its view stays in the hierarchy while hidden); widths are shared
    /// with other tabs and may have changed.
    func willBecomeVisible() {
        let sidebarStale =
            sidebarItem.map {
                !$0.isCollapsed && abs($0.viewController.view.frame.width - model.layout.sidebarWidth) > 0.5
            }
            ?? false
        let inspectorStale =
            inspectorItem.map {
                !$0.isCollapsed && abs($0.viewController.view.frame.width - model.layout.inspectorWidth) > 0.5
            } ?? false
        if sidebarStale || inspectorStale { applyWidths() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsWidthRestore, view.bounds.width > 0 {
            needsWidthRestore = false
            applyWidths()
        }
    }

    /// Applies the shared widths (another tab may have changed them).
    /// Only dividers that are off move. Restoring on every show (it used to re-arm in `viewWillAppear`) called
    /// `setPosition` on every tab switch: ≈ 190 main-thread samples over 40 switches in the multi-tab trace,
    /// now 0 (switch latency itself is bound by toolbar/SwiftUI layout).
    private func applyWidths() {
        isApplyingWidths = true
        defer { isApplyingWidths = false }
        let divider = splitView.dividerThickness
        if let sidebarItem, !sidebarItem.isCollapsed,
            abs(sidebarItem.viewController.view.frame.width - model.layout.sidebarWidth) > 0.5
        {
            splitView.setPosition(model.layout.sidebarWidth, ofDividerAt: 0)
        }
        if let inspectorItem, !inspectorItem.isCollapsed,
            abs(inspectorItem.viewController.view.frame.width - model.layout.inspectorWidth) > 0.5
        {
            splitView.setPosition(splitView.bounds.width - model.layout.inspectorWidth - divider, ofDividerAt: 1)
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onSidebarGeometryChange?()
        // Collapse/expand also resizes the subviews; record per-tab flags here (no KVO needed).
        if let sidebarItem, sidebarItem.isCollapsed != tab.sidebarCollapsed {
            collapseChanged(sidebar: sidebarItem.isCollapsed)
        }
        if let inspectorItem, inspectorItem.isCollapsed != tab.inspectorCollapsed {
            collapseChanged(inspector: inspectorItem.isCollapsed)
        }
        // Only user drags of a divider change the stored widths (not window resizes or restores).
        guard !isApplyingWidths, !needsWidthRestore, notification.userInfo?["NSSplitViewDividerIndex"] != nil
        else { return }
        if let sidebarItem, !sidebarItem.isCollapsed {
            model.layout.sidebarWidth = sidebarItem.viewController.view.frame.width
        }
        if let inspectorItem, !inspectorItem.isCollapsed {
            model.layout.inspectorWidth = inspectorItem.viewController.view.frame.width
        }
        model.scheduleSave()
    }

    private func collapseChanged(sidebar: Bool? = nil, inspector: Bool? = nil) {
        if let sidebar { tab.sidebarCollapsed = sidebar }
        if let inspector { tab.inspectorCollapsed = inspector }
        model.scheduleSave()
    }

    /// The tab closed (or was suspended): detach hosted views that capture their controllers (P6.6).
    func tearDown() {
        graph?.tearDown()
        diffController.tearDown()
    }

    // MARK: Pane focus (⌥⌘← / ⌥⌘→, design §3.2)

    /// Visible panes in focus order: sidebar → main (graph, working directory, diff) → inspector.
    private var focusPanes: [NSView] {
        splitViewItems.filter { !$0.isCollapsed }.map(\.viewController.view)
    }

    /// Moves keyboard focus to the first focusable view of the next (or previous) visible pane.
    func cycleFocus(forward: Bool) {
        guard let window = view.window else { return }
        let panes = focusPanes
        guard !panes.isEmpty else { return }
        let responder = window.firstResponder as? NSView
        let current = panes.firstIndex { pane in responder.map { $0 === pane || $0.isDescendant(of: pane) } ?? false }
        var index = current.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : panes.count - 1)
        for _ in 0..<panes.count {
            index = (index + panes.count) % panes.count
            if let target = Self.firstFocusable(in: panes[index]) {
                window.makeFirstResponder(target)
                return
            }
            index += forward ? 1 : -1
        }
    }

    private static func firstFocusable(in view: NSView) -> NSView? {
        if !view.isHiddenOrHasHiddenAncestor, view.canBecomeKeyView, view.acceptsFirstResponder,
            !(view is NSButton)
        {
            return view
        }
        for subview in view.subviews {
            if let found = firstFocusable(in: subview) { return found }
        }
        return nil
    }

    /// System collapse animation; instant with Reduce Motion.
    override func toggleSidebar(_ sender: Any?) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let sidebarItem {
            sidebarItem.isCollapsed.toggle()
        } else {
            super.toggleSidebar(sender)
        }
    }

    /// Opens or closes the inspector with the system animation (instant with Reduce Motion).
    func setInspectorCollapsed(_ collapsed: Bool) {
        guard let inspectorItem, inspectorItem.isCollapsed != collapsed else { return }
        if collapsed {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.window == nil {
                inspectorItem.isCollapsed = true
            } else {
                inspectorItem.animator().isCollapsed = true
            }
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.window == nil {
            // Open at the shared inspector width (a collapsed split item does not reliably keep it).
            inspectorItem.isCollapsed = false
            applyWidths()
        } else {
            // Slide in with the system animation, then settle on the shared width.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionToken.panel.duration
                context.allowsImplicitAnimation = true
                inspectorItem.animator().isCollapsed = false
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.applyWidths() }
            }
        }
    }

    /// Esc anywhere in the workbench that nothing closer handled (search fields, sheets and the graph's own
    /// modes come first): clear the selection, which closes the inspector; or close a manually opened one.
    override func cancelOperation(_ sender: Any?) {
        // An open diff covers the graph: Esc returns to the graph first.
        if diffModel.target != nil {
            diffModel.requestClose()
            return
        }
        if graph?.clearSelection() == true { return }
        setInspectorCollapsed(true)
    }

    override func toggleInspector(_ sender: Any?) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let inspectorItem {
            inspectorItem.isCollapsed.toggle()
        } else {
            super.toggleInspector(sender)
        }
    }
}

/// The main region: the graph, with the repository's error / first-load state over it.
@MainActor
final class MainPaneController: NSViewController {
    let graph: GraphViewController
    let session: RepositorySession
    let tab: TabModel
    let actions: WorkbenchActions
    let diffModel: DiffViewModel
    let diffController: DiffViewController
    let blameModel: BlameModel
    let blameController: BlameViewController
    let operations: OperationsController
    private let focusContainer = NSView()
    private let blameContainer = NSView()
    private let resolverContainer = NSView()
    private weak var stateOverlay: NSView?
    private var resolverController: ResolverViewController?

    init(
        graph: GraphViewController, session: RepositorySession, tab: TabModel, actions: WorkbenchActions,
        diffModel: DiffViewModel, diffController: DiffViewController, blameModel: BlameModel,
        blameController: BlameViewController, operations: OperationsController
    ) {
        self.operations = operations
        self.blameModel = blameModel
        self.blameController = blameController
        self.graph = graph
        self.session = session
        self.tab = tab
        self.actions = actions
        self.diffModel = diffModel
        self.diffController = diffController
        super.init(nibName: nil, bundle: nil)
    }

    /// The error / first-load overlay is hidden once the repository is open, so it never intercepts clicks
    /// meant for the graph or its command bar (an empty NSHostingView still hit-tests to itself).
    private func observeOverlay() {
        withObservationTracking {
            stateOverlay?.isHidden = session.error == nil && session.info != nil && session.status != nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOverlay() }
        }
    }

    /// The conflict resolver covers the graph area (design §3.8) while open.
    private func observeResolver() {
        withObservationTracking {
            _ = operations.resolver
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyResolver()
                self?.observeResolver()
            }
        }
    }

    private func applyResolver() {
        let model = operations.resolver
        if resolverController?.model !== model {
            resolverController?.view.removeFromSuperview()
            resolverController?.removeFromParent()
            resolverController = nil
            if let model {
                let controller = ResolverViewController(model: model)
                addChild(controller)
                let view = controller.view
                view.frame = resolverContainer.bounds
                view.autoresizingMask = [.width, .height]
                resolverContainer.addSubview(view)
                resolverController = controller
            }
        }
        resolverContainer.isHidden = model == nil
        if model != nil { view.window?.makeFirstResponder(resolverController?.view) }
    }

    /// External edits while the resolver is open: re-check the file after every status refresh.
    private func observeRefreshes() {
        withObservationTracking {
            _ = session.refreshCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.operations.resolver?.checkDisk()
                self?.observeRefreshes()
            }
        }
    }

    /// Blame covers the graph area (design §3.5) while open; Esc or the close button returns.
    private func observeBlame() {
        withObservationTracking {
            _ = blameModel.isOpen
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyBlame()
                self?.observeBlame()
            }
        }
    }

    private func applyBlame() {
        let open = blameModel.isOpen
        blameContainer.isHidden = !open
        if open {
            if blameController.view.superview !== blameContainer {
                let view = blameController.view
                view.frame = blameContainer.bounds
                view.autoresizingMask = [.width, .height]
                blameContainer.addSubview(view)
            }
            view.window?.makeFirstResponder(blameController.codeView)
        }
    }

    /// An open diff covers the graph area (0.0.2; it used to open under the file list in the inspector):
    /// 200 ms fade in, instant with Reduce Motion. Esc or its close button returns to the graph.
    private func observeFocus() {
        withObservationTracking {
            _ = diffModel.isFocused
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyFocus()
                self?.observeFocus()
            }
        }
    }

    private func applyFocus() {
        let focused = diffModel.isFocused
        let instant = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if focused {
            // Another file of the same commit: the diff is already showing, nothing to animate.
            guard focusContainer.isHidden else { return }
            let view = diffController.view
            if view.superview !== focusContainer {
                view.removeFromSuperview()
                view.frame = focusContainer.bounds
                view.autoresizingMask = [.width, .height]
                focusContainer.addSubview(view)
            }
            focusContainer.isHidden = false
            focusContainer.alphaValue = instant ? 1 : 0
            if !instant {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = MotionToken.panel.duration
                    focusContainer.animator().alphaValue = 1
                }
            }
        } else if !focusContainer.isHidden {
            focusContainer.isHidden = true
            // Keyboard focus goes back to the graph unless it is somewhere else already (the file list).
            if let window = view.window, let responder = window.firstResponder as? NSView,
                responder.isDescendant(of: focusContainer)
            {
                window.makeFirstResponder(graph.tableView)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        addChild(graph)
        graph.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(graph.view)
        let overlay = NSHostingView(rootView: SessionStateOverlay(session: session, tab: tab, actions: actions))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = []
        root.addSubview(overlay)
        stateOverlay = overlay
        observeOverlay()
        focusContainer.translatesAutoresizingMaskIntoConstraints = false
        focusContainer.isHidden = true
        focusContainer.wantsLayer = true
        root.addSubview(focusContainer)
        observeFocus()
        blameContainer.translatesAutoresizingMaskIntoConstraints = false
        blameContainer.isHidden = true
        root.addSubview(blameContainer)
        observeBlame()
        resolverContainer.translatesAutoresizingMaskIntoConstraints = false
        resolverContainer.isHidden = true
        resolverContainer.wantsLayer = true
        root.addSubview(resolverContainer)
        observeResolver()
        observeRefreshes()
        let sheets = NSHostingView(rootView: OperationSheetsHost(controller: operations))
        sheets.translatesAutoresizingMaskIntoConstraints = false
        sheets.sizingOptions = []
        root.addSubview(sheets)
        NSLayoutConstraint.activate([
            sheets.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sheets.topAnchor.constraint(equalTo: root.topAnchor),
            sheets.widthAnchor.constraint(equalToConstant: 1),
            sheets.heightAnchor.constraint(equalToConstant: 1),
            resolverContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            resolverContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resolverContainer.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            resolverContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            blameContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blameContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blameContainer.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            blameContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            focusContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            focusContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Below the window toolbar: the diff's own glass chrome must not sit under it.
            focusContainer.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            focusContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for view in [graph.view, overlay] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
    }
}
