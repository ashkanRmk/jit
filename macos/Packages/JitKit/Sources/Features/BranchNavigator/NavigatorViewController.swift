import AppKit
import DesignSystem
import GitCore
import Services

/// Left sidebar (design §3.5): Local / Remote / Tags in a view-based `NSOutlineView` (row reuse, so 10k
/// branches stay responsive) on the system's glass sidebar material. Read-only plus copy actions —
/// checkout and every branch mutation are Phase 4.
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

    private let outline = NavigatorOutlineView()
    private let filterField = NSSearchField()
    private var roots: [NavigatorNode] = []
    private var refs: RefSnapshot?
    private var expanded = Set<String>()
    private var savedExpansion: Set<String>?
    private var isRestoringExpansion = false

    static let expandedKey = "navigator.expanded"

    init(tab: TabModel, model: AppModel) {
        self.tab = tab
        self.model = model
        super.init(nibName: nil, bundle: nil)
        if case .array(let values) = tab.ui[Self.expandedKey] {
            expanded = Set(values.compactMap { if case .string(let s) = $0 { s } else { nil } })
        } else {
            expanded = ["section/Local", "section/Remote"]
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
        outline.rowSizeStyle = .default
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
        outline.doubleAction = #selector(rowClicked)
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
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Space.s4),
            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.s5),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.s5),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: Space.s4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
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
        roots = NavigatorTreeBuilder.build(refs, filter: filter)
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

    @objc func rowClicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        showInGraph(row: row)
    }

    func showInGraph(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? NavigatorNode, let commit = node.ref?.commit else {
            return
        }
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
        guard row >= 0, let node = outline.item(atRow: row) as? NavigatorNode, let ref = node.ref else { return }
        func item(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        let format = refs?.format ?? .sha1
        switch ref.kind {
        case .tag:
            item("Copy Tag Name") { Pasteboard.copy(ref.shortName) }
            item("Copy SHA") { Pasteboard.copy((ref.commit ?? ref.object).hex(format)) }
            if ref.commit != nil { item("Show in Graph") { [weak self] in self?.showInGraph(row: row) } }
            if ref.isAnnotatedTag {
                item("Show Tag Message") { [weak self] in self?.showTagMessage(ref, row: row) }
            }
        default:
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

/// ↩ shows the selected ref in the graph; ⌥⌘F focuses the filter.
final class NavigatorOutlineView: NSOutlineView {
    weak var controller: NavigatorViewController?

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
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: IconSize.md),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Space.s3),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Space.s3),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            pin.leadingAnchor.constraint(greaterThanOrEqualTo: dot.trailingAnchor, constant: Space.s3),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: Space.s2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        switch node.kind {
        case .section(let section):
            title.stringValue = section.rawValue
            badge.stringValue = node.refCount > 0 ? "\(node.refCount)" : ""
            icon.isHidden = true
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
