import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// The single main window (ADR-0007): unified glass toolbar with the tab strip, overflow menu,
/// sidebar/inspector toggles and the profile capsule; opaque per-tab content below.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSMenuDelegate
{
    public let model: AppModel
    private let container = ContentContainerViewController()
    /// One controller per loaded tab, kept while the tab is open (instant switching); dropped when the
    /// tab closes or its session is suspended under memory pressure.
    private var controllers: [UUID: NSViewController] = [:]
    private let chrome = ChromeState()
    private var profilePopover: NSPopover?
    private weak var profileItem: NSToolbarItem?
    private weak var stripView: NSView?
    private weak var profileHost: NSView?
    private static let trafficLightsWidth: CGFloat = 86
    private static let systemItemWidth: CGFloat = 50
    private static let trailingInset: CGFloat = 40
    private var stripWidth: NSLayoutConstraint?
    private var observers: [any NSObjectProtocol] = []

    static let stripIdentifier = NSToolbarItem.Identifier("jit.tabs")
    static let overflowIdentifier = NSToolbarItem.Identifier("jit.tabs.overflow")
    static let profileIdentifier = NSToolbarItem.Identifier("jit.profile")

    public init(model: AppModel) {
        self.model = model
        let frame = Self.initialFrame(model.windowFrame)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Jit"
        window.titleVisibility = .hidden  // the tab strip shows the name; title/subtitle stay set for the system
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed  // Jit's own tabs, not system window tabs
        window.isRestorable = false  // restored from session.json instead
        window.minSize = NSSize(width: PanelMetrics.windowMinWidth, height: PanelMetrics.windowMinHeight)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrame(frame, display: false)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = container
        window.setFrame(frame, display: false)

        let toolbar = NSToolbar(identifier: "jit.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        container.onDropFolder = { [weak self] url in self?.openDropped(url) }
        model.onChange = { [weak self] change in self?.handle(change) }
        model.presentOpenPanel = { [weak self] in self?.chooseRepository() }
        model.onOpenFailure = { [weak self] url, error in self?.presentOpenFailure(url, error) }
        observeProfiles()
        observeForeground()
        updateChromeWidth()
        recordFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func initialFrame(_ saved: SessionState.WindowFrame?) -> NSRect {
        let fallbackSize = NSSize(width: 1180, height: 760)
        if let saved {
            let rect = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return rect
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screen.midX - fallbackSize.width / 2, y: screen.midY - fallbackSize.height / 2,
            width: min(fallbackSize.width, screen.width), height: min(fallbackSize.height, screen.height))
    }

    // MARK: - Model changes

    private func handle(_ change: AppModel.Change) {
        switch change {
        case .tabs:
            let open = Set(model.tabs.map(\.id))
            for id in controllers.keys where !open.contains(id) {
                controllers[id].map(container.remove)
                controllers[id] = nil
            }
        case .activeTab:
            showActiveTab()
        case .activeTabDetails:
            updateTitle()
        case .suspended(let ids):
            for id in ids where id != model.activeTabID {
                controllers[id].map(container.remove)
                controllers[id] = nil
            }
        }
    }

    func showActiveTab() {
        guard let tab = model.activeTab else { return }
        let controller = controllers[tab.id] ?? makeController(for: tab)
        controllers[tab.id] = controller
        container.show(controller)
        updateTitle()
        updateChromeWidth()
    }

    private func makeController(for tab: TabModel) -> NSViewController {
        if let session = tab.session {
            let workbench = WorkbenchController(tab: tab, session: session, model: model, actions: actions(for: tab))
            workbench.onSidebarGeometryChange = { [weak self] in self?.updateChromeWidth() }
            return workbench
        }
        let host = NSHostingController(rootView: NewTabView(model: model, actions: newTabActions()))
        host.sizingOptions = []
        return host
    }

    private func updateTitle() {
        guard let window else { return }
        let tab = model.activeTab
        window.title = tab?.isRepository == true ? (tab?.title ?? "Jit") : "Jit"
        if let status = tab?.session?.status {
            window.subtitle = BranchLabel.subtitle(for: status)
        } else {
            window.subtitle = tab?.branch ?? ""
        }
    }

    // MARK: - Foreground (only the visible tab of an active app works)

    private func observeForeground() {
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateForeground() }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
        for name in [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main, using: update))
        }
    }

    public func updateForeground() {
        guard let window else { return }
        let foreground =
            NSApp.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        model.setForeground(foreground)
    }

    // MARK: - Window delegate

    public func windowDidResize(_ notification: Notification) {
        recordFrame()
        updateChromeWidth()
    }

    public func windowDidMove(_ notification: Notification) { recordFrame() }

    public func windowWillClose(_ notification: Notification) {
        model.setForeground(false)
        model.flush()
    }

    /// Stores the current frame in the session (also called before the final flush at quit).
    public func recordFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        model.windowFrame = .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        model.scheduleSave()
    }

    /// The tab strip takes the toolbar space not used by the other items. With an expanded sidebar the
    /// toolbar's leading items start at the sidebar's trailing edge; otherwise after the traffic lights.
    func updateChromeWidth() {
        guard let window else { return }
        let width = window.frame.width
        chrome.showsProfileName = width >= ProfileMetrics.nameHiddenBelowWindowWidth
        profileHost?.layoutSubtreeIfNeeded()
        let profileWidth = max(ProfileMetrics.avatar + Space.s6, profileHost?.fittingSize.width ?? 160)
        var leading = Self.trafficLightsWidth
        if let workbench = container.current as? WorkbenchController, !workbench.isSidebarCollapsed {
            leading = max(leading, workbench.sidebarWidth)
        }
        leading += Self.systemItemWidth  // sidebar toggle
        let trailing = 2 * Self.systemItemWidth + profileWidth + Self.trailingInset
        let strip = max(TabMetrics.minWidth + TabMetrics.newTabButton, width - leading - trailing)
        if abs((stripWidth?.constant ?? 0) - strip) > 0.5 { stripWidth?.constant = strip }
    }

    // MARK: - Toolbar

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, Self.stripIdentifier, Self.overflowIdentifier, .toggleInspector,
            Self.profileIdentifier,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.stripIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(rootView: TabStripView(model: model))
            host.translatesAutoresizingMaskIntoConstraints = false
            host.clipsToBounds = true
            let width = host.widthAnchor.constraint(equalToConstant: 600)
            width.isActive = true
            host.heightAnchor.constraint(equalToConstant: TabMetrics.height + Space.s2 * 2).isActive = true
            stripWidth = width
            stripView = host
            item.view = host
            // The strip is its own single glass container; without this the toolbar would wrap it in a
            // second glass platter (glass nested in glass).
            item.isBordered = false
            item.label = "Tabs"
            item.visibilityPriority = .high
            updateChromeWidth()
            return item
        case Self.overflowIdentifier:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            let menu = NSMenu(title: "All Tabs")
            menu.delegate = self
            item.menu = menu
            item.showsIndicator = false
            item.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "All Tabs")
            item.label = "All Tabs"
            item.toolTip = "Show all tabs"
            return item
        case Self.profileIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(
                rootView: ProfileCapsuleView(store: model.profiles, chrome: chrome) { [weak self] in
                    self?.toggleProfilePopover()
                })
            item.view = host
            profileHost = host
            item.label = "Profile"
            item.toolTip = "Git profile"
            profileItem = item
            applyProfileTint()
            return item
        default:
            return nil
        }
    }

    // MARK: - Overflow menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "All Tabs" else { return }
        menu.removeAllItems()
        for (index, tab) in model.tabs.enumerated() {
            let item = NSMenuItem(title: tab.title, action: #selector(selectTabFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = tab.id
            item.state = tab.id == model.activeTabID ? .on : .off
            item.subtitle = tab.path.map { "\($0) — \(tab.statusDot.description)" }
            item.image = StatusDotImage.image(for: tab.statusDot)
            menu.addItem(item)
        }
    }

    @objc func selectTabFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { model.select(id) }
    }

    // MARK: - Profiles

    private func observeProfiles() {
        withObservationTracking {
            _ = model.profiles.activeProfileID
            _ = model.profiles.profiles
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyProfileTint()
                self?.updateChromeWidth()
                self?.observeProfiles()
            }
        }
    }

    /// "No Profile" uses the system prominent toolbar style tinted `status.warning` — the one non-accent
    /// tint in the chrome, because it's a state the user must act on (docs/design-system.md).
    private func applyProfileTint() {
        guard let profileItem else { return }
        if model.profiles.activeProfile == nil {
            profileItem.style = .prominent
            profileItem.backgroundTintColor = ColorToken.statusWarning.nsColor
        } else {
            profileItem.style = .plain
            profileItem.backgroundTintColor = nil
        }
    }

    public func toggleProfilePopover() {
        if let profilePopover, profilePopover.isShown {
            profilePopover.performClose(nil)
            return
        }
        guard let anchor = profileItem?.view else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: ProfileSwitcherView(
                store: model.profiles,
                newProfile: { [weak self] prefill in
                    self?.profilePopover?.performClose(nil)
                    self?.presentProfileEditor(nil, prefillFromGitConfig: prefill)
                },
                manageProfiles: { [weak self] in
                    self?.profilePopover?.performClose(nil)
                    NSApp.sendAction(Selector(("showSettingsProfiles:")), to: nil, from: self)
                },
                dismiss: { [weak self] in self?.profilePopover?.performClose(nil) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        profilePopover = popover
    }

    public func presentProfileEditor(_ profile: GitProfile?, prefillFromGitConfig: Bool) {
        guard let window else { return }
        ProfileEditorPresenter.present(
            on: window, store: model.profiles, engine: model.engine, editing: profile,
            prefillFromGitConfig: prefillFromGitConfig)
    }

    // MARK: - Opening

    func chooseRepository(then handler: ((URL) -> Void)? = nil) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder that contains a Git repository."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let handler { handler(url) } else { self?.model.open(url) }
        }
    }

    private func openDropped(_ url: URL) {
        model.open(url)
    }

    private func presentOpenFailure(_ url: URL, _ error: GitCoreError) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.summary
        alert.informativeText = [url.path, ErrorGuidance.text(for: error)].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func newTabActions() -> NewTabActions {
        NewTabActions(
            open: { [weak self] in self?.chooseRepository() },
            openPath: { [weak self] path in self?.model.open(URL(fileURLWithPath: path)) },
            locate: { [weak self] path in
                self?.chooseRepository { url in self?.model.open(url, forgettingRecent: path) }
            },
            reveal: { path in RepositoryActions.revealInFinder(path) })
    }

    private func actions(for tab: TabModel) -> WorkbenchActions {
        let id = tab.id
        return WorkbenchActions(
            locate: { [weak self] in self?.chooseRepository { url in self?.model.relocate(id, to: url) } },
            removeTab: { [weak self] in self?.model.closeTab(id) },
            retry: { [weak self] in self?.model.tab(id)?.session?.reload() },
            revealInFinder: { [weak self] in self?.model.tab(id)?.path.map(RepositoryActions.revealInFinder) },
            openInTerminal: { [weak self] in self?.model.tab(id)?.path.map(RepositoryActions.openInTerminal) })
    }

    // MARK: - Menu actions (first responder)

    private var activeRepositoryPath: String? { model.activeTab?.path }

    @objc public func newTab(_ sender: Any?) { model.newTab() }
    @objc public func openRepository(_ sender: Any?) { chooseRepository() }
    @objc public func closeTab(_ sender: Any?) {
        if let id = model.activeTabID { model.closeTab(id) }
    }
    @objc public func reopenClosedTab(_ sender: Any?) { model.reopenClosedTab() }
    @objc public func selectNextTab(_ sender: Any?) { model.selectNextTab() }
    @objc public func selectPreviousTab(_ sender: Any?) { model.selectPreviousTab() }
    @objc public func moveTabLeft(_ sender: Any?) {
        if let id = model.activeTabID { model.moveTab(id, by: -1) }
    }
    @objc public func moveTabRight(_ sender: Any?) {
        if let id = model.activeTabID { model.moveTab(id, by: 1) }
    }
    @objc public func selectTabFromWindowMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { model.select(id) }
    }
    @objc public func toggleSidebar(_ sender: Any?) {
        (container.current as? WorkbenchController)?.toggleSidebar(sender)
    }
    @objc public func toggleInspector(_ sender: Any?) {
        (container.current as? WorkbenchController)?.toggleInspector(sender)
    }
    @objc public func refreshRepository(_ sender: Any?) { model.activeTab?.session?.reload() }
    @objc public func revealRepositoryInFinder(_ sender: Any?) {
        activeRepositoryPath.map(RepositoryActions.revealInFinder)
    }
    @objc public func openRepositoryInTerminal(_ sender: Any?) {
        activeRepositoryPath.map(RepositoryActions.openInTerminal)
    }
    @objc public func copyRepositoryPath(_ sender: Any?) { activeRepositoryPath.map(RepositoryActions.copyPath) }
    @objc public func openRecentRepository(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { model.open(URL(fileURLWithPath: path)) }
    }
    @objc public func clearRecentRepositories(_ sender: Any?) { model.recents.clear() }
    @objc public func showProfileSwitcher(_ sender: Any?) { toggleProfilePopover() }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isRepository = model.activeTab?.isRepository == true
        switch menuItem.action {
        case #selector(reopenClosedTab(_:)): return model.canReopenClosedTab
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): return model.tabs.count > 1
        case #selector(moveTabLeft(_:)): return (model.activeIndex ?? 0) > 0
        case #selector(moveTabRight(_:)): return (model.activeIndex ?? model.tabs.count) < model.tabs.count - 1
        case #selector(selectTabFromWindowMenu(_:)):
            menuItem.state = (menuItem.representedObject as? UUID) == model.activeTabID ? .on : .off
            return true
        case #selector(toggleSidebar(_:)):
            let controller = container.current as? WorkbenchController
            menuItem.title = controller?.isSidebarCollapsed == false ? "Hide Sidebar" : "Show Sidebar"
            return controller != nil
        case #selector(toggleInspector(_:)):
            let controller = container.current as? WorkbenchController
            menuItem.title = controller?.isInspectorCollapsed == false ? "Hide Inspector" : "Show Inspector"
            return controller != nil
        case #selector(refreshRepository(_:)), #selector(revealRepositoryInFinder(_:)),
            #selector(openRepositoryInTerminal(_:)), #selector(copyRepositoryPath(_:)):
            return isRepository
        case #selector(clearRecentRepositories(_:)): return !model.recents.entries.isEmpty
        default: return true
        }
    }

    #if DEBUG
        public func showDropOverlayForScreenshot() { (container.view as? DropTargetView)?.showOverlayForScreenshot() }
    #endif

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleSidebar || item.itemIdentifier == .toggleInspector {
            return container.current is WorkbenchController
        }
        return true
    }
}

/// Small chrome state shared with hosted toolbar views.
@MainActor @Observable
final class ChromeState {
    var showsProfileName = true
}

/// Hosts the active tab's controller and the window-wide folder drop target.
@MainActor
final class ContentContainerViewController: NSViewController {
    private(set) var current: NSViewController?
    var onDropFolder: ((URL) -> Void)?

    override func loadView() {
        let view = DropTargetView()
        view.onDrop = { [weak self] url in self?.onDropFolder?(url) }
        self.view = view
    }

    func show(_ controller: NSViewController) {
        guard controller !== current else { return }
        let previous = current
        current = controller
        // Loaded tabs keep their views in the hierarchy and are only hidden, so switching back doesn't
        // re-insert (and re-lay out) a whole SwiftUI/split-view tree.
        if controller.parent !== self {
            addChild(controller)
            let child = controller.view
            child.frame = view.bounds
            child.autoresizingMask = [.width, .height]
            (view as? DropTargetView)?.setContent(child)
        }
        (controller as? WorkbenchController)?.willBecomeVisible()
        controller.view.isHidden = false
        previous?.view.isHidden = true
        view.window?.makeFirstResponder(controller.view)
    }

    /// Removes a closed or suspended tab's controller.
    func remove(_ controller: NSViewController) {
        guard controller.parent === self else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        if current === controller { current = nil }
    }
}

/// Accepts folders dragged anywhere over the content and shows an opaque overlay while dragging.
final class DropTargetView: NSView {
    var onDrop: ((URL) -> Void)?
    private let overlay = NSHostingView(rootView: DropOverlay())
    private weak var content: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        overlay.isHidden = true
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setContent(_ view: NSView) {
        addSubview(view, positioned: .below, relativeTo: overlay)
        content = view
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
    }

    private func folder(in info: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return nil }
        return urls.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    #if DEBUG
        /// Screenshots of the drop state (`-JitShowDropOverlay YES`); a real drag can't be captured reliably.
        func showOverlayForScreenshot() { overlay.isHidden = false }
    #endif

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard folder(in: sender) != nil else { return [] }
        overlay.isHidden = false
        return .generic
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folder(in: sender) != nil ? .generic : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { overlay.isHidden = true }

    override func draggingEnded(_ sender: any NSDraggingInfo) { overlay.isHidden = true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        overlay.isHidden = true
        guard let url = folder(in: sender) else { return false }
        onDrop?(url)
        return true
    }
}

/// Opaque content overlay (never glass: it covers content).
struct DropOverlay: View {
    var body: some View {
        ZStack {
            ColorToken.surfaceCanvas.color.opacity(OverlayMetrics.dropCanvasOpacity)
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    ColorToken.accentBase.color,
                    style: StrokeStyle(lineWidth: OverlayMetrics.dropLineWidth, dash: OverlayMetrics.dropDash)
                )
                .padding(Space.s6)
            VStack(spacing: Space.s4) {
                Image(systemName: "arrow.down.doc")
                    .symbolSize(IconSize.hero, weight: .light)
                    .foregroundStyle(.token(.accentBase))
                Text("Open as Repository")
                    .typeStyle(.title)
                    .foregroundStyle(.token(.textPrimary))
            }
        }
        // Content only: the glass toolbar stays visible above it.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
