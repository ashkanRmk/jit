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

/// The three-region workbench (design §3.3): system glass sidebar, opaque main content, system
/// inspector. Widths are global (`LayoutState`); collapse flags belong to the tab.
@MainActor
final class WorkbenchController: NSSplitViewController {
    let tab: TabModel
    let session: RepositorySession
    let model: AppModel
    private let actions: WorkbenchActions
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
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

        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.host(SidebarView(session: session)))
        sidebar.minimumThickness = PanelMetrics.sidebarMin
        sidebar.maximumThickness = PanelMetrics.sidebarMax
        sidebar.canCollapse = true
        sidebar.isCollapsed = tab.sidebarCollapsed

        let main = NSSplitViewItem(
            viewController: Self.host(WorkbenchMainView(session: session, tab: tab, actions: actions)))
        main.minimumThickness = PanelMetrics.contentColumnMax - 160

        let inspector = NSSplitViewItem(
            inspectorWithViewController: Self.host(InspectorView(session: session, actions: actions)))
        inspector.minimumThickness = PanelMetrics.inspectorMin
        inspector.maximumThickness = PanelMetrics.inspectorMax
        inspector.canCollapse = true
        inspector.isCollapsed = tab.inspectorCollapsed

        addSplitViewItem(sidebar)
        addSplitViewItem(main)
        addSplitViewItem(inspector)
        sidebarItem = sidebar
        inspectorItem = inspector
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

    override func toggleInspector(_ sender: Any?) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let inspectorItem {
            inspectorItem.isCollapsed.toggle()
        } else {
            super.toggleInspector(sender)
        }
    }
}
