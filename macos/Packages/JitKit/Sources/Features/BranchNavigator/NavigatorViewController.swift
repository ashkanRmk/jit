import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Left sidebar (design §3.5): Local / Remote / Tags in a view-based `NSOutlineView` (row reuse, so 10k
/// branches stay responsive) on the system's glass sidebar material. Double-click checks out; the context
/// menus carry the Phase 4 branch operations.
@MainActor
final class NavigatorViewController: NSViewController {
    struct Actions {
        var showInGraph: (ObjectID) -> Void = { _ in }
        var solo: (String) -> Void = { _ in }
        var togglePin: (String) -> Void = { _ in }
        var isPinned: (String) -> Bool = { _ in false }
    }

    let tab: TabModel
    let model: AppModel
    var actions = Actions()
    var repository: RepositoryHandle?
    /// Phase 4 write actions (checkout, branch operations, stashes).
    var operations: OperationsController?
    /// The tab's graph: the branch header at the top shows and switches its current branch.
    weak var graph: GraphViewController?
    /// The profile row at the bottom (the profile switcher popover opens from it).
    private(set) weak var profileAnchor: NSView?

    private let outline = NavigatorOutlineView()
    private let filterField = NSSearchField()
    private var roots: [NavigatorNode] = []
    private var refs: RefSnapshot?
    private var stashes: [StashEntry]?
    private var expanded = Set<String>()
    private var savedExpansion: Set<String>?
    private var isRestoringExpansion = false

    static let expandedKey = "navigator.expanded"
    /// Stored with the expansion set once a tab has seen the Stashes section (collapsing it then sticks).
    static let stashesSeenMarker = "marker/stashes"

    init(tab: TabModel, model: AppModel) {
        self.tab = tab
        self.model = model
        super.init(nibName: nil, bundle: nil)
        if case .array(let values) = tab.ui[Self.expandedKey] {
            expanded = Set(values.compactMap { if case .string(let s) = $0 { s } else { nil } })
            // Tabs saved before Phase 4 have no Stashes section yet: start it expanded.
            if !values.contains(.string(Self.stashesSeenMarker)) {
                expanded.formUnion(["section/Stashes", Self.stashesSeenMarker])
            }
        } else {
            expanded = ["section/Local", "section/Remote", "section/Stashes", Self.stashesSeenMarker]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        filterField.placeholderString = "Filter branches and tags"
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityLabel("Filter branches and tags")

        outline.style = .sourceList
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = SidebarMetrics.rowHeight
        outline.floatsGroupRows = false
        outline.indentationPerLevel = Space.s6
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ref"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.controller = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityLabel("Branches and tags")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(filterField)
        root.addSubview(scroll)
        let footer = NSHostingView(rootView: SidebarFooter(store: model.profiles))
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.sizingOptions = []
        footer.safeAreaRegions = []
        root.addSubview(footer)
        profileAnchor = footer
        var filterTop = filterField.topAnchor.constraint(
            equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Space.s4)
        if let graph {
            let header = NSHostingView(rootView: SidebarBranchHeader(source: .init(graph)))
            header.translatesAutoresizingMaskIntoConstraints = false
            header.sizingOptions = [.intrinsicContentSize]
            header.safeAreaRegions = []
            root.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Space.s3),
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            filterTop = filterField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Space.s4)
        }
        NSLayoutConstraint.activate([
            filterTop,
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: SidebarMetrics.footerHeight),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.s5),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.s5),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: Space.s4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
        view = root
    }

    /// The tab closed: drop the hosted SwiftUI rows (P6.6).
    func tearDown() {
        for subview in view.subviews where subview is NSHostingView<SidebarBranchHeader> {
            subview.removeFromSuperview()
        }
    }

    /// New stash list from the session (P4.16).
    func update(stashes: [StashEntry]?) {
        guard stashes != self.stashes else { return }
        self.stashes = stashes
        rebuild()
    }

    /// New refs from the history controller.
    func update(refs: RefSnapshot) {
        guard refs.revision != self.refs?.revision else { return }
        self.refs = refs
        rebuild()
    }

    @objc private func filterChanged() {
        let filter = filterField.stringValue
        if !filter.isEmpty, savedExpansion == nil { savedExpansion = expanded }
        rebuild()
        if filter.isEmpty, let saved = savedExpansion {
            savedExpansion = nil
            expanded = saved
            applyExpansion()
        }
    }

    func focusFilter() {
        view.window?.makeFirstResponder(filterField)
    }

    private func rebuild() {
        guard let refs else { return }
        let filter = filterField.stringValue
        roots = NavigatorTreeBuilder.build(refs, filter: filter, stashes: stashes)
        outline.reloadData()
        if !filter.isEmpty {
            // Auto-expand everything leading to a match while filtering.
            var ids = Set<String>()
            for root in roots { ids.formUnion(root.expandableIDs { FuzzyMatch.matches(filter, $0.shortName) }) }
            isRestoringExpansion = true
            for node in allNodes() where ids.contains(node.id) || node.kind == .section(.local) {
                outline.expandItem(node)
            }
            isRestoringExpansion = false
        } else {
            applyExpansion()
        }
    }

    private func applyExpansion() {
        isRestoringExpansion = true
        for node in allNodes() where expanded.contains(node.id) { outline.expandItem(node) }
        isRestoringExpansion = false
    }

    private func allNodes() -> [NavigatorNode] {
        var result: [NavigatorNode] = []
        func walk(_ nodes: [NavigatorNode]) {
            for node in nodes {
                result.append(node)
                walk(node.children)
            }
        }
        walk(roots)
        return result
    }

    private func persistExpansion() {
        guard !isRestoringExpansion, filterField.stringValue.isEmpty else { return }
        tab.ui[Self.expandedKey] = .array(expanded.sorted().map(JSONValue.string))
        model.scheduleSave()
    }

    /// Reveals and selects a ref's row (graph label ▸ Show in Navigator).
    func reveal(fullName: String) {
        if !filterField.stringValue.isEmpty {
            filterField.stringValue = ""
            filterChanged()
        }
        guard let node = allNodes().first(where: { $0.ref?.fullName == fullName }) else { return }
        var ancestors: [NavigatorNode] = []
        var current = outline.parent(forItem: node) as? NavigatorNode
        while let parent = current {
            ancestors.insert(parent, at: 0)
            current = outline.parent(forItem: parent) as? NavigatorNode
        }
        if ancestors.isEmpty {
            // Not yet loaded as a child row: expand every folder on its id path.
            for candidate in allNodes() where candidate.children.contains(where: { $0 === node }) {
                ancestors.append(candidate)
            }
        }
        for ancestor in ancestors { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        view.window?.makeFirstResponder(outline)
    }

    /// Double-click checks out: a local branch is switched to; a remote branch checks out its local tracking
    /// branch (created when missing); a stash is applied only from its menu.
    @objc func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? NavigatorNode else { return }
        if let ref = node.ref, ref.kind == .local || ref.kind == .remote, let operations {
            if ref.isHead { return showInGraph(row: row) }
            operations.checkout(ref: ref)
        } else {
            showInGraph(row: row)
        }
    }

    @objc func rowClicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        showInGraph(row: row)
    }

    func showInGraph(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? NavigatorNode else { return }
        if let stash = node.stash, let oid = ObjectID(hex: stash.oid) {
            operations?.inspectCommit(oid)
            return
        }
        guard let commit = node.ref?.commit else { return }
        actions.showInGraph(commit)
    }

    private func showTagMessage(_ ref: GitRef, row: Int) {
        guard let repository else { return }
        Task { [weak self] in
            let message: String
            do throws(GitCoreError) {
                message = try await repository.tagMessage(object: ref.object)
            } catch {
                message = error.summary
            }
            guard let self, let rowView = self.outline.rowView(atRow: row, makeIfNecessary: false) else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            let label = NSTextField(
                wrappingLabelWithString: message.isEmpty
                    ? "(empty message)" : DisplayText.sanitize(message, keepNewlines: true))
            label.isSelectable = true
            label.font = TypeToken.body.nsFont
            label.textColor = ColorToken.textPrimary.nsColor
            label.preferredMaxLayoutWidth = 320
            let controller = NSViewController()
            let container = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: Space.s6),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Space.s6),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Space.s6),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Space.s6),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            ])
            controller.view = container
            popover.contentViewController = controller
            popover.show(relativeTo: rowView.bounds, of: rowView, preferredEdge: .maxX)
        }
    }
}

extension NavigatorViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NavigatorNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? NavigatorNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NavigatorNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .section = (item as? NavigatorNode)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? NavigatorNode else { return false }
        if case .section = node.kind { return false }
        if case .note = node.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NavigatorNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("navigatorCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NavigatorCellView ?? NavigatorCellView()
        cell.identifier = id
        cell.configure(node, pinned: node.ref.map { actions.isPinned($0.fullName) } ?? false)
        return cell
    }

    /// Section rows are taller: the extra height is the gap between two section containers.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // `rowHeight` follows the system's sidebar icon size.
        if case .section = (item as? NavigatorNode)?.kind {
            return outlineView.rowHeight + NavigatorOutlineView.sectionGap
        }
        return outlineView.rowHeight
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? NavigatorNode else { return }
        if !isRestoringExpansion, filterField.stringValue.isEmpty {
            expanded.insert(node.id)
            persistExpansion()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? NavigatorNode else { return }
        if !isRestoringExpansion, filterField.stringValue.isEmpty {
            expanded.remove(node.id)
            persistExpansion()
        }
    }
}

extension NavigatorViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        func item(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        if row >= 0, let node = outline.item(atRow: row) as? NavigatorNode, let stash = node.stash, let operations {
            item("Apply \(stash.name)") { operations.apply(stash, pop: false) }
            item("Pop \(stash.name)") { operations.apply(stash, pop: true) }
            item("Show Changes") { [weak self] in self?.showInGraph(row: row) }
            menu.addItem(.separator())
            item("Copy SHA") { Pasteboard.copy(stash.oid) }
            menu.addItem(.separator())
            item("Drop \(stash.name)…") { operations.drop(stash) }
            return
        }
        if row >= 0, let node = outline.item(atRow: row) as? NavigatorNode, node.kind == .section(.stashes),
            let operations
        {
            item("Stash Changes…") { operations.createStash() }
            return
        }
        guard row >= 0, let node = outline.item(atRow: row) as? NavigatorNode, let ref = node.ref else { return }
        let format = refs?.format ?? .sha1
        switch ref.kind {
        case .tag:
            if let operations, let commit = ref.commit {
                let hex = commit.hex(format)
                item("Check Out \(ref.shortName)…") { operations.switchTo(.detach(hex)) }
                item("New Branch Here…") { operations.newBranch(at: ref.fullName, label: ref.shortName) }
                item("Merge \(ref.shortName) into \(operations.currentBranch ?? "HEAD")…") {
                    operations.merge(source: ref.fullName, label: ref.shortName)
                }
                menu.addItem(.separator())
            }
            item("Copy Tag Name") { Pasteboard.copy(ref.shortName) }
            item("Copy SHA") { Pasteboard.copy((ref.commit ?? ref.object).hex(format)) }
            if ref.commit != nil { item("Show in Graph") { [weak self] in self?.showInGraph(row: row) } }
            if ref.isAnnotatedTag {
                item("Show Tag Message") { [weak self] in self?.showTagMessage(ref, row: row) }
            }
        default:
            if let operations {
                Self.branchWriteItems(ref, operations: operations).forEach(menu.addItem)
                menu.addItem(.separator())
            }
            item("Copy Branch Name") { Pasteboard.copy(ref.shortName) }
            item("Copy SHA") { Pasteboard.copy((ref.commit ?? ref.object).hex(format)) }
            menu.addItem(.separator())
            let pinned = actions.isPinned(ref.fullName)
            item(pinned ? "Unpin" : "Pin to Left") { [weak self] in
                self?.actions.togglePin(ref.fullName)
                self?.outline.reloadItem(node)
            }
            item("Solo") { [weak self] in self?.actions.solo(ref.fullName) }
            item("Show in Graph") { [weak self] in self?.showInGraph(row: row) }
        }
    }
}

extension NavigatorViewController {
    /// Branch write actions shared by the navigator and graph label menus (design §3.6).
    static func branchWriteItems(_ ref: GitRef, operations: OperationsController) -> [NSMenuItem] {
        let current = operations.currentBranch ?? "HEAD"
        // Git writes the argument into its merge message ("Merge branch 'feature/x'"), so pass the short name
        // unless a tag or other ref makes it ambiguous.
        let source = operations.unambiguousName(for: ref)
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: @escaping () -> Void) {
            items.append(ClosureMenuItem(title: title, action: action))
        }
        switch ref.kind {
        case .local:
            let name = ref.shortName
            if !ref.isHead { add("Switch to \(name)") { operations.checkout(ref: ref) } }
            add("New Branch from \(name)…") { operations.newBranch(at: ref.fullName, label: name) }
            if !ref.isHead {
                items.append(.separator())
                add("Merge \(name) into \(current)…") { operations.merge(source: source, label: name) }
                add("Rebase \(current) onto \(name)…") { operations.rebase(onto: source, label: name) }
            }
            items.append(.separator())
            if ref.isHead { add("Push…") { operations.push() } }
            add("Rename \(name)…") { operations.rename(name) }
            if ref.upstream != nil || ref.upstreamGone {
                add("Unset Upstream") { operations.setUpstream(name, to: nil) }
            }
            add(ref.upstream == nil ? "Set Upstream…" : "Change Upstream…") { operations.setUpstream(for: name) }
            if !ref.isHead { add("Delete \(name)…") { operations.delete(branch: name) } }
            if let remote = operations.webRemoteURL, let url = WebLink.map(remoteURL: remote, target: .branch(name)) {
                add("Copy Link to Branch") { Pasteboard.copy(url.absoluteString) }
            }
        case .remote:
            guard let branch = ref.remoteBranchName else { return [] }
            add("Check Out \(branch)") { operations.checkout(ref: ref) }
            add("New Branch from \(ref.shortName)…") { operations.newBranch(at: ref.fullName, label: ref.shortName) }
            items.append(.separator())
            add("Merge \(ref.shortName) into \(current)…") {
                operations.merge(source: ref.fullName, label: ref.shortName)
            }
            add("Rebase \(current) onto \(ref.shortName)…") {
                operations.rebase(onto: ref.fullName, label: ref.shortName)
            }
            items.append(.separator())
            add("Delete \(ref.shortName) on Remote…") { operations.deleteRemote(ref: ref) }
            if let remote = operations.webRemoteURL, let url = WebLink.map(remoteURL: remote, target: .branch(branch)) {
                add("Copy Link to Branch") { Pasteboard.copy(url.absoluteString) }
            }
        case .tag, .other:
            break
        }
        return items
    }
}

/// ↩ shows the selected ref in the graph; ⌥⌘F focuses the filter.
final class NavigatorOutlineView: NSOutlineView {
    weak var controller: NavigatorViewController?

    static let sectionGap: CGFloat = Space.s4

    /// One container per section (0.0.2): a rounded, lightly filled shape behind each top-level section and
    /// the rows under it. Drawn here, behind the rows, so row reuse and selection are untouched.
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        // A light wash: the sidebar's glass shows through the containers.
        let fill = ColorToken.stateHover.nsColor.withAlphaComponent(
            ColorToken.stateHover.nsColor.alphaComponent * SidebarMetrics.cardOpacity)
        let stroke = ColorToken.borderSubtle.nsColor
        var row = 0
        while row < numberOfRows {
            guard level(forRow: row) == 0 else {
                row += 1
                continue
            }
            var last = row
            while last + 1 < numberOfRows, level(forRow: last + 1) > 0 { last += 1 }
            var rect = self.rect(ofRow: row).union(self.rect(ofRow: last))
            rect.origin.y += Self.sectionGap
            rect.size.height -= Self.sectionGap
            rect = rect.insetBy(dx: Space.s3, dy: 0)
            if rect.intersects(clipRect) {
                let path = NSBezierPath(roundedRect: rect, xRadius: Radius.md, yRadius: Radius.md)
                fill.setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = Border.hairline
                path.stroke()
            }
            row = last + 1
        }
    }

    /// The containers follow the rows: redraw the background when rows are added, removed or resized.
    override func noteNumberOfRowsChanged() {
        super.noteNumberOfRowsChanged()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {  // Return / Enter
            controller?.showInGraph(row: selectedRow)
        } else if modifiers == [.command, .option], event.charactersIgnoringModifiers == "f" {
            controller?.focusFilter()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Glyph, name, and trailing tracking info.
final class NavigatorCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let pin = NSImageView()
    /// Section titles sit in their container, below the gap at the top of a section row.
    private lazy var sectionOffset = title.centerYAnchor.constraint(equalTo: centerYAnchor)

    init() {
        super.init(frame: .zero)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pin.contentTintColor = .tertiaryLabelColor
        pin.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        for view in [icon, title, badge, dot, pin] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = title
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = TypeToken.caption.nsFont
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.alignment = .right
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s1),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            sectionOffset,
            icon.widthAnchor.constraint(equalToConstant: IconSize.md),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Space.s3),
            dot.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Space.s3),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            pin.leadingAnchor.constraint(greaterThanOrEqualTo: dot.trailingAnchor, constant: Space.s3),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: Space.s2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s4),
            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ node: NavigatorNode, pinned: Bool) {
        title.font = GraphTypography.sidebar
        title.textColor = .labelColor
        badge.stringValue = ""
        badge.textColor = .secondaryLabelColor
        dot.isHidden = true
        pin.isHidden = true
        icon.isHidden = false
        toolTip = nil
        if case .section = node.kind {
            sectionOffset.constant = NavigatorOutlineView.sectionGap / 2
        } else {
            sectionOffset.constant = 0
        }
        switch node.kind {
        case .section(let section):
            title.stringValue = section.rawValue
            title.font = GraphTypography.sidebarSection
            badge.stringValue = node.refCount > 0 ? "\(node.refCount)" : ""
            icon.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil)
            setAccessibilityLabel("\(section.rawValue), \(node.refCount) items")
        case .remote(let name):
            title.stringValue = DisplayText.sanitize(name)
            icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            badge.stringValue = "\(node.refCount)"
            setAccessibilityLabel("Remote \(name)")
        case .folder:
            title.stringValue = DisplayText.sanitize(node.title)
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            setAccessibilityLabel("Folder \(node.title)")
        case .stash(let entry):
            title.stringValue = DisplayText.sanitize(entry.message)
            icon.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            badge.stringValue = formatter.localizedString(for: entry.date, relativeTo: Date())
            toolTip =
                "\(entry.name)\(entry.branch.map { " · on \($0)" } ?? "")\(entry.hasUntracked ? " · includes untracked files" : "")"
            setAccessibilityLabel("Stash \(entry.message), \(entry.name), \(badge.stringValue)")
        case .note(let text):
            title.stringValue = text
            title.textColor = .tertiaryLabelColor
            icon.isHidden = true
            setAccessibilityLabel(text)
        case .ref(let ref):
            title.stringValue = DisplayText.sanitize(node.title)
            toolTip = DisplayText.sanitize(ref.shortName)
            var spoken = ref.kind == .tag ? "Tag \(ref.shortName)" : "Branch \(ref.shortName)"
            switch ref.kind {
            case .tag:
                icon.image = NSImage(
                    systemSymbolName: ref.commit == nil ? "tag.slash" : "tag", accessibilityDescription: nil)
                if ref.commit == nil {
                    badge.stringValue = "non-commit tag"
                    spoken += ", non-commit tag"
                }
            default:
                icon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            }
            if ref.isHead && ref.kind == .local {
                title.font = GraphTypography.sidebarEmphasized
                dot.isHidden = false
                dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                spoken += ", current branch"
            }
            if ref.upstreamGone {
                badge.stringValue = "upstream gone"
                badge.textColor = ColorToken.statusWarning.nsColor
                spoken += ", upstream gone"
            } else if ref.ahead + ref.behind > 0 {
                badge.stringValue = "↑\(ref.ahead) ↓\(ref.behind)"
                spoken += ", \(ref.ahead) ahead, \(ref.behind) behind"
            }
            if pinned {
                pin.isHidden = false
                spoken += ", pinned"
            }
            setAccessibilityLabel(spoken)
        }
        icon.contentTintColor = .secondaryLabelColor
    }
}

extension NavigatorNode.Section {
    /// The glyph before a section title: where its refs live.
    var symbolName: String {
        switch self {
        case .local: "laptopcomputer"
        case .remote: "cloud"
        case .tags: "tag"
        case .stashes: "tray.full"
        }
    }
}
