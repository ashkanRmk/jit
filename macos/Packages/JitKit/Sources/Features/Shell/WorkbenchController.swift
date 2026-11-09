import AppKit
import DesignSystem
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
            viewController: MainPaneController(graph: graph, session: session, tab: tab, actions: actions))
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
        graph.actions.selectionChanged = { [weak self, weak graph] model in
            inspector.show(selection: graph?.compareOrder(model.selection) ?? model.selection, wip: model.wipSelected)
            self?.setInspectorCollapsed(model.selection.isEmpty && !model.wipSelected)
        }
        graph.actions.refsChanged = { [weak graph, weak navigator] refs in
            navigator?.update(refs: refs)
            navigator?.repository = graph?.history?.repository
            inspector.handle = graph?.history?.repository
            inspector.refs = refs
            inspector.format = refs.format
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

    private static func host<V: View>(_ view: V) -> NSViewController {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return host
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        needsWidthRestore = true
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
    private func applyWidths() {
        isApplyingWidths = true
        defer { isApplyingWidths = false }
        let divider = splitView.dividerThickness
        if let sidebarItem, !sidebarItem.isCollapsed {
            splitView.setPosition(model.layout.sidebarWidth, ofDividerAt: 0)
        }
        if let inspectorItem, !inspectorItem.isCollapsed {
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
        } else {
            // Open at the shared inspector width (a collapsed split item does not reliably keep it).
            inspectorItem.isCollapsed = false
            applyWidths()
        }
    }

    /// Esc anywhere in the workbench that nothing closer handled (search fields, sheets and the graph's own
    /// modes come first): clear the selection, which closes the inspector; or close a manually opened one.
    override func cancelOperation(_ sender: Any?) {
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

    init(graph: GraphViewController, session: RepositorySession, tab: TabModel, actions: WorkbenchActions) {
        self.graph = graph
        self.session = session
        self.tab = tab
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
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
