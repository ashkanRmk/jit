import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// The single main window (ADR-0007): unified glass toolbar with the sidebar toggle and the tab strip; opaque
/// per-tab content below. The profile and Settings live at the bottom of the sidebar (0.0.3).
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, CommandAvailability
{
    public let model: AppModel
    private let container = ContentContainerViewController()

    /// The visible tab's graph (benchmarks).
    var activeGraph: GraphViewController? { activeWorkbench?.graph }
    /// The visible tab's workbench, if it is a repository tab.
    var activeWorkbench: WorkbenchController? { container.current as? WorkbenchController }
    /// One controller per loaded tab, kept while the tab is open (instant switching); dropped when the
    /// tab closes or its session is suspended under memory pressure.
    private var controllers: [UUID: NSViewController] = [:]
    private var profilePopover: NSPopover?
    private var activityPopover: NSPopover?
    private weak var activityItem: NSToolbarItem?
    private weak var updatesItem: NSToolbarItem?
    private weak var stripView: NSView?
    private weak var pendingSeparatorSplitView: NSSplitView?
    private static let trafficLightsWidth: CGFloat = 86
    private static let systemItemWidth: CGFloat = 50
    /// Kept free at the toolbar's trailing end, so the strip never pushes an item out of place.
    private static let trailingInset: CGFloat = 28
    private var stripWidth: NSLayoutConstraint?
    private var observers: [any NSObjectProtocol] = []
    private var palette: CommandPaletteController?

    static let stripIdentifier = NSToolbarItem.Identifier("jit.tabs")
    /// Operation activity (Phase 4): present only while the active tab has running or recent operations.
    static let activityIdentifier = NSToolbarItem.Identifier("jit.activity")
    /// The bell at the trailing end: the change log and updates (ADR-0051).
    static let updatesIdentifier = NSToolbarItem.Identifier("jit.updates")
    /// The sidebar toggle as the icon alone: the system item always draws a button platter around it.
    static let sidebarToggleIdentifier = NSToolbarItem.Identifier("jit.sidebar.toggle")
    /// Tracks the visible workbench's sidebar divider, so the sidebar toggle stays beside the window controls
    /// over the sidebar and the tab strip starts at the sidebar's edge (macOS standard, as in Mail/Notes).
    /// Without it the system placed the toggle after the sidebar of whichever split view it found — loaded
    /// tabs keep their (hidden) split views in the window — so the toggle moved after tab switches.
    static let sidebarSeparatorIdentifier = NSToolbarItem.Identifier("jit.sidebar.separator")

    public init(model: AppModel) {
        self.model = model
        RecentlyDiscardedMenu.shared.repositoryPath = { [weak model] in
            guard let tab = model?.activeTab else { return nil }
            return tab.session?.info?.topLevel ?? tab.path
        }
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
        ProfileMenu.shared.store = model.profiles
        // Not `model.accounts` here: that would create the accounts service (Keychain, path monitor) at launch.
        model.configureAccounts = { [weak self] accounts in
            accounts.passphrasePrompt = { [weak self] keyPath, fingerprint in
                await PassphrasePresenter.ask(on: self?.window, keyPath: keyPath, fingerprint: fingerprint)
            }
            accounts.publishedFingerprints = { [weak accounts] host in
                guard host == "github.com", let accounts else { return [] }
                let transport = await accounts.transport(for: .github)
                let provider = GitHubProvider(instance: .github, transport: transport, token: { SecretBytes([]) })
                return (try? await provider.publishedSSHFingerprints()) ?? []
            }
        }
        observeActivity()
        observeForeground()
        updateSidebarSeparator()
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
        updateSidebarSeparator()
        // Once more after layout: the new tab's sidebar has its width only then.
        DispatchQueue.main.async { [weak self] in self?.updateChromeWidth() }
        updateTitle()
        updateChromeWidth()
    }

    /// Present only while the visible tab has a sidebar, and always follows that tab's split view.
    private func updateSidebarSeparator() {
        guard let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.sidebarSeparatorIdentifier }
        guard let workbench = container.current as? WorkbenchController else {
            if let index { toolbar.removeItem(at: index) }
            return
        }
        if let index {
            if (toolbar.items[index] as? NSTrackingSeparatorToolbarItem)?.splitView === workbench.splitView { return }
            // A new item per split view: assigning `splitView` on the existing item throws inside AppKit
            // ("Cannot remove an observer … splitView._peeking", seen on a tab switch).
            toolbar.removeItem(at: index)
        }
        let after = toolbar.items.firstIndex { $0.itemIdentifier == Self.sidebarToggleIdentifier }.map { $0 + 1 } ?? 0
        pendingSeparatorSplitView = workbench.splitView
        toolbar.insertItem(withItemIdentifier: Self.sidebarSeparatorIdentifier, at: after)
        pendingSeparatorSplitView = nil
    }

    private func makeController(for tab: TabModel) -> NSViewController {
        if let session = tab.session {
            let workbench = WorkbenchController(tab: tab, session: session, model: model, actions: actions(for: tab))
            workbench.onSidebarGeometryChange = { [weak self] in self?.updateChromeWidth() }
            return workbench
        }
        let host = NSHostingController(rootView: NewTabView(model: model, actions: newTabActions()))
        host.sizingOptions = []
        // The page draws under the glass toolbar; its own layout keeps clear of it.
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
        #if DEBUG
            // `-JitAssumeForeground YES` (screenshots from a background launch or a locked screen): the visible
            // tab loads as if Jit were the active app.
            if UserDefaults.standard.bool(forKey: "JitAssumeForeground") {
                model.setForeground(true)
                return
            }
        #endif
        let foreground =
            NSApp.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        model.setForeground(foreground)
    }

    // MARK: - Window delegate

    public func windowDidResize(_ notification: Notification) {
        recordFrame()
        updateChromeWidth()
    }

    public func windowDidEndLiveResize(_ notification: Notification) { updateChromeWidth() }
    public func windowDidEnterFullScreen(_ notification: Notification) { updateChromeWidth() }
    public func windowDidExitFullScreen(_ notification: Notification) { updateChromeWidth() }

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

    /// The tab strip takes the toolbar space after the sidebar (or after the toggle when the sidebar is closed),
    /// minus the activity item and the bell. The estimate is deliberately the larger of the two possible
    /// origins plus the toggle: a strip that is too wide falls into the toolbar's overflow (the 0.0.3 "tabs
    /// gone" bug), one a little narrower only leaves a gap.
    func updateChromeWidth() {
        guard let window else { return }
        let width = window.frame.width
        var origin = Self.trafficLightsWidth
        if let workbench = container.current as? WorkbenchController, !workbench.isSidebarCollapsed {
            origin = max(origin, workbench.sidebarWidth)
        }
        origin += Self.systemItemWidth
        // The strip's real position wins when it is on screen and further right than the estimate.
        if let stripView, stripView.window != nil, !stripView.isHiddenOrHasHiddenAncestor {
            let measured = stripView.convert(stripView.bounds, to: nil).minX
            if measured > origin, measured < width - TabMetrics.minWidth { origin = measured }
        }
        let activityWidth =
            activityItem.map { _ in
                max(Self.systemItemWidth, (activityItem?.view?.fittingSize.width ?? 0) + Space.s6)
            } ?? 0
        let updatesWidth = max(Self.systemItemWidth, (updatesItem?.view?.fittingSize.width ?? 0) + Space.s6)
        let trailing = Self.trailingInset + activityWidth + updatesWidth
        let strip = max(TabMetrics.minWidth + TabMetrics.newTabButton, width - origin - trailing)
        if abs((stripWidth?.constant ?? 0) - strip) > 0.5 { stripWidth?.constant = strip }
    }

    // MARK: - Toolbar

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier, Self.stripIdentifier, Self.updatesIdentifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.sidebarSeparatorIdentifier, Self.activityIdentifier]
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.sidebarToggleIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let image =
                NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar") ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(toggleSidebar(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.symbolConfiguration = .init(pointSize: IconSize.md, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: IconSize.lg + Space.s4).isActive = true
            button.heightAnchor.constraint(equalToConstant: TabMetrics.height).isActive = true
            button.setAccessibilityLabel("Toggle Sidebar")
            item.view = button
            item.isBordered = false
            item.label = "Sidebar"
            item.toolTip = "Show or hide the sidebar (⌃⌘S)"
            item.visibilityPriority = .high
            return item
        case Self.sidebarSeparatorIdentifier:
            guard let splitView = pendingSeparatorSplitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
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
        case Self.activityIdentifier:
            // A standard toolbar item: macOS renders it inside the system Liquid Glass toolbar (no custom material).
            let item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(
                rootView: ActivityToolbarView(model: model) { [weak self] in self?.toggleActivityPopover() })
            item.view = host
            // The icon alone, like the sidebar toggle: no glass platter around it.
            item.isBordered = false
            item.label = "Activity"
            item.toolTip = "Activity (⌥⌘A)"
            activityItem = item
            return item
        case Self.updatesIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = NSHostingView(
                rootView: UpdateBellView(updates: model.updates) { [weak self] in self?.presentUpdates() })
            item.isBordered = false
            item.label = "What's New"
            item.visibilityPriority = .high
            updatesItem = item
            return item
        default:
            return nil
        }
    }

    // MARK: - Activity

    private func observeActivity() {
        withObservationTracking {
            _ = model.activeTabID
            _ = model.activeTab?.session?.operations.records.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateActivityItem()
                self?.observeActivity()
            }
        }
        updateActivityItem()
    }

    /// Idle with no history: no item at all (no reserved empty chrome, design §3.1).
    private func updateActivityItem() {
        guard let toolbar = window?.toolbar else { return }
        let hasActivity = !(model.activeTab?.session?.operations.records.isEmpty ?? true)
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.activityIdentifier }
        if hasActivity, index == nil {
            // Before the bell, which stays the last item.
            let bell = toolbar.items.firstIndex { $0.itemIdentifier == Self.updatesIdentifier }
            toolbar.insertItem(withItemIdentifier: Self.activityIdentifier, at: bell ?? toolbar.items.count)
            updateChromeWidth()
        } else if !hasActivity, let index {
            activityPopover?.performClose(nil)
            toolbar.removeItem(at: index)
            updateChromeWidth()
        }
    }

    public func toggleActivityPopover() {
        if let activityPopover, activityPopover.isShown {
            activityPopover.performClose(nil)
            return
        }
        guard let center = model.activeTab?.session?.operations else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: ActivityPopover(center: center))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        if let anchor = activityItem?.view, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let stripView, stripView.window != nil {
            // ⌥⌘A with no activity yet: the empty state, at the trailing end of the tab strip.
            let rect = NSRect(
                x: stripView.bounds.maxX - Space.s8, y: 0, width: Space.s8, height: stripView.bounds.height)
            popover.show(relativeTo: rect, of: stripView, preferredEdge: .minY)
        } else {
            return
        }
        activityPopover = popover
    }

    // MARK: - Profiles

    private func observeProfiles() {
        withObservationTracking {
            _ = model.profiles.activeProfileID
            _ = model.profiles.profiles
            _ = model.profiles.switchCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.announceSwitchIfNeeded()
                self?.observeProfiles()
            }
        }
    }

    private var announcedSwitch = 0

    /// "Switched to Work GitLab — new operations commit as ada@corp.example" (design §3.1): a short transient
    /// popover at the profile item (one-shot close, no timer loop) plus a VoiceOver announcement.
    private func announceSwitchIfNeeded() {
        let count = model.profiles.switchCount
        guard count != announcedSwitch else { return }
        announcedSwitch = count
        guard let profile = model.profiles.activeProfile, let anchor = profileAnchor(),
            profilePopover?.isShown != true, window?.isVisible == true
        else { return }
        let email = (profile.committer ?? profile.author).email
        let message = "Switched to \(profile.displayName) — new operations commit as \(email)"
        NSAccessibility.post(
            element: window as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let toast = NSPopover()
        toast.behavior = .transient
        toast.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(
            rootView: Text(message)
                .typeStyle(.callout)
                .padding(.horizontal, Space.s5)
                .padding(.vertical, Space.s3)
                .fixedSize())
        host.sizingOptions = .preferredContentSize
        toast.contentViewController = host
        toast.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak toast] in toast?.performClose(nil) }
    }

    /// Where the profile switcher opens: the profile row at the bottom of the sidebar, or — when the sidebar is
    /// closed or the tab has none — the same corner of the window's content.
    private func profileAnchor() -> (view: NSView, rect: NSRect)? {
        if let workbench = activeWorkbench, !workbench.isSidebarCollapsed,
            let footer = workbench.navigator?.profileAnchor, footer.window != nil
        {
            return (footer, footer.bounds)
        }
        guard let view = container.current?.view ?? window?.contentView, view.window != nil else { return nil }
        let height = SidebarMetrics.footerHeight
        let y = view.isFlipped ? view.bounds.maxY - height : view.bounds.minY
        return (view, NSRect(x: view.bounds.minX + Space.s5, y: y, width: 200, height: height))
    }

    public func toggleProfilePopover() {
        if let profilePopover, profilePopover.isShown {
            profilePopover.performClose(nil)
            return
        }
        // No window content to anchor to: Settings ▸ Profiles instead of silently doing nothing (P7.11 finding).
        guard let anchor = profileAnchor() else {
            NSApp.sendAction(Selector(("showSettingsProfiles:")), to: nil, from: self)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: ProfileSwitcherView(
                store: model.profiles,
                newProfile: { [weak self] prefill in
                    self?.profilePopover?.performClose(nil)
                    self?.presentProfileEditor(nil, prefillFromGitConfig: prefill)
                },
                editProfile: { [weak self] profile in
                    self?.profilePopover?.performClose(nil)
                    self?.presentProfileEditor(profile, prefillFromGitConfig: false)
                },
                manageProfiles: { [weak self] in
                    self?.profilePopover?.performClose(nil)
                    NSApp.sendAction(Selector(("showSettingsProfiles:")), to: nil, from: self)
                },
                dismiss: { [weak self] in self?.profilePopover?.performClose(nil) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
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
            clone: { [weak self] in self?.presentClone() },
            browse: { [weak self] in self?.browseRemoteRepositories(nil) },
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

    /// Repository ▸ Profile ▸ <name>.
    @objc public func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.profiles.setActive(id)
    }

    /// File ▸ Browse Remote Repositories… (and the new-tab page).
    @objc public func browseRemoteRepositories(_ sender: Any?) {
        _ = RepositoryBrowserWindowController.show(
            accounts: model.accounts,
            clone: { [weak self] url in
                self?.window?.makeKeyAndOrderFront(nil)
                self?.presentClone(url: url)
            },
            switchProfile: { [weak self] id in self?.model.profiles.setActive(id) },
            openSettings: { pane in
                NSApp.sendAction(
                    pane == "network" ? Selector(("showSettingsNetwork:")) : Selector(("showSettingsAccounts:")),
                    to: nil, from: nil)
            })
    }

    // MARK: Phase 4 actions (Repository / Branch / File menus)

    private var activeOperations: OperationsController? { (container.current as? WorkbenchController)?.operations }

    @objc public func showActivity(_ sender: Any?) { toggleActivityPopover() }
    @objc public func fetchRepository(_ sender: Any?) { activeOperations?.fetch() }
    @objc public func fetchAllRemotes(_ sender: Any?) { activeOperations?.fetchAll() }
    @objc public func pullRepository(_ sender: Any?) { activeOperations?.pull(.fastForwardOnly) }
    @objc public func pullWithMerge(_ sender: Any?) { activeOperations?.pull(.merge) }
    @objc public func pullWithRebase(_ sender: Any?) { activeOperations?.pull(.rebase) }
    @objc public func pushRepository(_ sender: Any?) { activeOperations?.push() }
    @objc public func showRemotes(_ sender: Any?) { activeOperations?.showRemotes() }
    @objc public func stashChanges(_ sender: Any?) { activeOperations?.createStash() }
    @objc public func popStash(_ sender: Any?) { activeOperations?.popLatest() }
    @objc public func newBranch(_ sender: Any?) {
        activeOperations?.newBranch(at: "HEAD", label: activeOperations?.currentBranch ?? "HEAD")
    }
    @objc public func resolveConflicts(_ sender: Any?) { activeOperations?.openNextConflict() }
    @objc public func continueOperation(_ sender: Any?) { activeOperations?.continueOperation() }
    @objc public func abortOperation(_ sender: Any?) { activeOperations?.abort() }

    @objc public func cloneRepository(_ sender: Any?) { presentClone() }

    // MARK: Phase 6 actions (View menu, palette)

    /// ⌘F / ⌘G / ⇧⌘G from anywhere in the window (sidebar, inspector): the graph's search when the focused view
    /// has no search of its own (the diff keeps its own — it is earlier in the responder chain).
    @objc public func jitFind(_ sender: Any?) { activeGraph?.jitFind(sender) }
    @objc public func jitFindNext(_ sender: Any?) { activeGraph?.jitFindNext(sender) }
    @objc public func jitFindPrevious(_ sender: Any?) { activeGraph?.jitFindPrevious(sender) }

    /// Edit ▸ Find ▸ Find in Open Tabs… (⇧⌘F): the palette scoped to open tabs and recent repositories by name.
    @objc public func findInOpenTabs(_ sender: Any?) {
        guard let window else { return }
        let controller = palette ?? CommandPaletteController(window: self)
        palette = controller
        if !controller.isOpen { controller.open(over: window) }
        controller.setQuery("#")
    }

    @objc public func focusNextPane(_ sender: Any?) { activeWorkbench?.cycleFocus(forward: true) }
    @objc public func focusPreviousPane(_ sender: Any?) { activeWorkbench?.cycleFocus(forward: false) }

    @objc public func increaseCodeTextSize(_ sender: Any?) { stepCodeTextSize(by: 1) }
    @objc public func decreaseCodeTextSize(_ sender: Any?) { stepCodeTextSize(by: -1) }
    @objc public func resetCodeTextSize(_ sender: Any?) { model.preferences.codeTextSize = .medium }

    private func stepCodeTextSize(by step: Int) {
        let next = model.preferences.codeTextSize.rawValue + step
        if let size = PreferencesStore.CodeTextSize(rawValue: next) { model.preferences.codeTextSize = size }
    }

    /// Types into the open palette (⇧⌘F, `-JitPaletteQuery`).
    public func setPaletteQuery(_ query: String) { palette?.setQuery(query) }

    /// View ▸ Command Palette… (⌘K): opens, or closes when open.
    @objc public func toggleCommandPalette(_ sender: Any?) {
        guard let window else { return }
        if let palette, palette.isOpen {
            palette.close()
            return
        }
        let controller = palette ?? CommandPaletteController(window: self)
        palette = controller
        controller.open(over: window)
    }

    /// The bell and Jit ▸ Check for Updates…: the change log as a standard sheet. `checkNow` also asks GitHub.
    public func presentUpdates(checkNow: Bool = false) {
        guard let window else { return }
        if window.attachedSheet == nil {
            let host = NSHostingController(rootView: AnyView(EmptyView()))
            let sheet = NSWindow(contentViewController: host)
            sheet.title = "What's New"
            sheet.identifier = NSUserInterfaceItemIdentifier("updates")
            host.rootView = AnyView(
                UpdatesSheet(
                    updates: model.updates, preferences: model.preferences,
                    openPage: { NSWorkspace.shared.open($0) },
                    close: { [weak window, weak sheet] in
                        if let window, let sheet { window.endSheet(sheet) }
                    }))
            host.sizingOptions = .preferredContentSize
            window.beginSheet(sheet)
        } else if window.attachedSheet?.identifier?.rawValue != "updates" {
            return
        }
        if checkNow { Task { await model.updates.check() } }
    }

    /// File ▸ Clone… (⇧⌘N) and the new-tab page: a standard sheet; the clone opens in a new tab.
    public func presentClone(url: String = "") {
        guard let window, window.attachedSheet == nil else { return }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let clone = CloneModel(engine: model.engine, preferences: model.preferences, url: url) { [weak self] in
            self?.model.accounts.execContext() ?? .anonymous
        }
        clone.finish = { [weak self, weak host] path in
            if let host { self?.window?.endSheet(host.view.window ?? NSWindow()) }
            if let path { self?.model.open(URL(fileURLWithPath: path)) }
        }
        host.rootView = AnyView(CloneSheet(model: clone))
        host.sizingOptions = .preferredContentSize
        let sheet = NSWindow(contentViewController: host)
        window.beginSheet(sheet)
    }

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
        case #selector(fetchRepository(_:)), #selector(fetchAllRemotes(_:)), #selector(showRemotes(_:)),
            #selector(showActivity(_:)), #selector(newBranch(_:)):
            return activeOperations != nil
        case #selector(pullRepository(_:)), #selector(pullWithMerge(_:)), #selector(pullWithRebase(_:)):
            return activeOperations?.session.status?.branch.upstream != nil
        case #selector(pushRepository(_:)):
            return activeOperations.map { !$0.headIsDetached } ?? false
        case #selector(stashChanges(_:)):
            return !(activeOperations?.session.status?.summary?.isClean ?? true)
        case #selector(popStash(_:)):
            return !(activeOperations?.session.stashes?.isEmpty ?? true)
        case #selector(resolveConflicts(_:)):
            return (activeOperations?.session.operationState.conflicted ?? 0) > 0
        case #selector(continueOperation(_:)), #selector(abortOperation(_:)):
            return activeOperations?.session.operationState.isDrivable ?? false
        case #selector(jitFind(_:)), #selector(jitFindNext(_:)), #selector(jitFindPrevious(_:)):
            return activeGraph != nil
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
            return activeWorkbench != nil
        case #selector(increaseCodeTextSize(_:)):
            return model.preferences.codeTextSize != PreferencesStore.CodeTextSize.allCases.last
        case #selector(decreaseCodeTextSize(_:)):
            return model.preferences.codeTextSize != PreferencesStore.CodeTextSize.allCases.first
        case #selector(resetCodeTextSize(_:)):
            return model.preferences.codeTextSize != .medium
        default: return true
        }
    }

    /// Why a menu command is unavailable, in the palette's words (ADR-0044). `nil` when it is available or the
    /// reason is obvious from context.
    public func disabledReason(for action: Selector) -> String? {
        let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
        guard !validateMenuItem(probe) else { return nil }
        let isRepository = model.activeTab?.isRepository == true
        let noRepository = "Open a repository first"
        switch action {
        case #selector(reopenClosedTab(_:)): return "No recently closed tab"
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): return "Only one tab is open"
        case #selector(moveTabLeft(_:)): return "The tab is already first"
        case #selector(moveTabRight(_:)): return "The tab is already last"
        case #selector(clearRecentRepositories(_:)): return "No recent repositories"
        case #selector(pullRepository(_:)), #selector(pullWithMerge(_:)), #selector(pullWithRebase(_:)):
            return isRepository ? "No upstream configured for the current branch" : noRepository
        case #selector(pushRepository(_:)):
            return isRepository ? "HEAD is detached" : noRepository
        case #selector(stashChanges(_:)): return isRepository ? "No changes to stash" : noRepository
        case #selector(popStash(_:)): return isRepository ? "No stashes" : noRepository
        case #selector(resolveConflicts(_:)): return isRepository ? "No conflicts" : noRepository
        case #selector(continueOperation(_:)), #selector(abortOperation(_:)):
            return isRepository ? "No merge, rebase, cherry-pick or revert in progress" : noRepository
        case #selector(increaseCodeTextSize(_:)): return "Already the largest size"
        case #selector(decreaseCodeTextSize(_:)): return "Already the smallest size"
        case #selector(resetCodeTextSize(_:)): return "Already the default size"
        default: return isRepository ? nil : noRepository
        }
    }

    #if DEBUG
        public func showDropOverlayForScreenshot() { (container.view as? DropTargetView)?.showOverlayForScreenshot() }
    #endif

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == Self.sidebarToggleIdentifier {
            return container.current is WorkbenchController
        }
        return true
    }
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
        // Loaded tabs keep their controllers (no reload on switching back), but only the visible tab's view is
        // in the window: macOS lays the toolbar out around every full-height sidebar in the window, hidden or
        // not, so a hidden tab's sidebar pushed the sidebar toggle out of place on other tabs. (Switching
        // `allowsFullHeightLayout` off for hidden tabs instead left the sidebar under the window controls after
        // quick back-and-forth switching.)
        if controller.parent !== self { addChild(controller) }
        previous?.view.removeFromSuperview()
        let child = controller.view
        if child.superview !== view {
            child.frame = view.bounds
            child.autoresizingMask = [.width, .height]
            (view as? DropTargetView)?.setContent(child)
        }
        (controller as? WorkbenchController)?.willBecomeVisible()
        view.window?.makeFirstResponder(controller.view)
    }

    /// Removes a closed or suspended tab's controller.
    /// Removes a tab's controller for good (closed tab, or suspended under memory pressure). Hosted SwiftUI
    /// views that hold their owning controller are detached first, so nothing outlives the tab (P6.6).
    func remove(_ controller: NSViewController) {
        guard controller.parent === self else { return }
        (controller as? WorkbenchController)?.tearDown()
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
