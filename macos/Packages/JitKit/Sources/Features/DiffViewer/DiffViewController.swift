import AppKit
import DesignSystem
import GitCore
import SwiftUI

/// The diff viewer (design §3.3): an opaque `CodeLinesView` body under floating glass chrome (layout,
/// change navigator, find) in one container. Menu actions (⌘F, ⌘G, ⌥↓/⌥↑, ⌘L, Focus Diff) arrive
/// through the responder chain while the diff has focus.
@MainActor
public final class DiffViewController: NSViewController, CodeLinesDelegate, NSMenuItemValidation {
    public let model: DiffViewModel
    let codeView = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    private let scrollView = NSScrollView()
    private var chrome: NSHostingView<DiffChromeView>?
    private var messageHost: NSHostingView<DiffMessageView>?
    /// Line selection (P3.8) hooks: clicks on line rows go here when set.
    var onLineClick: ((_ row: Int, _ column: Int, _ modifiers: NSEvent.ModifierFlags) -> Void)?
    var onLineDrag: ((_ row: Int, _ column: Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    public init(model: DiffViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ColorToken.surfaceCanvas.nsColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: DiffChromeView.height, left: 0, bottom: 0, right: 0)
        scrollView.documentView = codeView
        codeView.delegate = self
        root.addSubview(scrollView)
        let messageHost = NSHostingView(rootView: DiffMessageView(model: model))
        messageHost.translatesAutoresizingMaskIntoConstraints = false
        messageHost.sizingOptions = []
        messageHost.safeAreaRegions = []
        root.addSubview(messageHost)
        self.messageHost = messageHost
        // Separate hosting views sized to their content: the body between them takes the clicks.
        let chrome = NSHostingView(rootView: DiffChromeView(model: model, controller: self))
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.sizingOptions = [.intrinsicContentSize]
        chrome.safeAreaRegions = []  // the bar sits at the pane's top, not below the window toolbar
        chrome.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chrome.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(chrome)
        self.chrome = chrome
        let capsule = NSHostingView(rootView: SelectionCapsuleHost(model: model))
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.sizingOptions = [.intrinsicContentSize]
        capsule.safeAreaRegions = []
        root.addSubview(capsule)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            messageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            messageHost.topAnchor.constraint(equalTo: root.topAnchor),
            messageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            capsule.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            capsule.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
        ])
        view = root
        model.onSourceChange = { [weak self] in self?.sourceChanged() }
        model.onRedraw = { [weak self] in
            self?.codeView.showsWhitespace = self?.model.showsWhitespace ?? false
            self?.codeView.refreshRows()
        }
        model.scrollToRow = { [weak self] row, center in self?.codeView.scrollToRow(row, center: center) }
        model.onTextChange = { [weak self] in self?.codeView.invalidateText() }
        onLineClick = { [weak self] row, column, modifiers in
            self?.model.click(row: row, column: column, modifiers: modifiers)
        }
        onLineDrag = { [weak self] row, column in self?.model.drag(row: row, column: column) }
        onKey = { [weak self] event in self?.model.key(event) ?? false }
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        sourceChanged()
    }

    @objc private func frameChanged() { codeView.reloadData() }

    /// Breaks the controller → view → chrome host → `DiffChromeView` → controller cycle (P6.6). Called once when
    /// the tab's workbench is removed for good.
    func tearDown() {
        chrome?.removeFromSuperview()
        chrome = nil
    }

    /// The file whose rows are on screen: another file starts at the top, a reload of the same one keeps its place.
    private var shownTarget: DiffTarget?

    private func sourceChanged() {
        codeView.showsWhitespace = model.showsWhitespace
        codeView.wrapsLines = model.wrapsLines
        scrollView.hasHorizontalScroller = !model.wrapsLines
        codeView.dataSource = model.source
        scrollView.isHidden = model.source == nil
        let target = model.source?.document.target
        if model.source != nil, target != shownTarget {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        shownTarget = model.source == nil ? nil : target
        updateMessage()
        if model.source != nil, let token = model.switchSignpost {
            model.switchSignpost = nil
            view.window?.displayIfNeeded()
            Signposts.end(token)
        }
    }

    /// The message layer exists only when there is something to say (it would otherwise eat clicks).
    private func updateMessage() {
        withObservationTracking {
            messageHost?.isHidden =
                model.state == .loaded && model.message == nil
                || model.state == .idle || (model.state == .loading && !model.showsSpinner)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateMessage() }
        }
    }

    /// First visible row (for change navigation).
    var firstVisibleRow: Int {
        // The rows under the floating chrome do not count as visible.
        var visible = scrollView.documentVisibleRect
        visible.origin.y = max(0, visible.minY + scrollView.contentInsets.top)
        return codeView.rows(in: visible).lowerBound
    }

    public func focusBody() { view.window?.makeFirstResponder(codeView) }

    // MARK: CodeLinesDelegate

    public func codeLines(_ view: CodeLinesView, clickedRow row: Int, column: Int, modifiers: NSEvent.ModifierFlags) {
        guard let source = model.source else { return }
        let cell = source.cell(row: row, column: column)
        if cell.kind == .gap {
            model.expandGap(atRow: row)
            return
        }
        onLineClick?(row, column, modifiers)
    }

    public func codeLines(_ view: CodeLinesView, draggedTo row: Int, column: Int) { onLineDrag?(row, column) }

    public func codeLines(_ view: CodeLinesView, keyDown event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        if event.keyCode == 53 {  // Esc
            if !model.query.isEmpty {
                model.query = ""
                return true
            }
            if model.target != nil {
                model.requestClose()
                return true
            }
        }
        return false
    }

    public func codeLinesCopyText(_ view: CodeLinesView) -> String? {
        guard let source = model.source else { return nil }
        let lines = source.selectedLines.sorted()
        if !lines.isEmpty { return lines.map { source.document.text(ofLine: $0) }.joined(separator: "\n") }
        // Without a selection: the visible rows.
        return codeView.rows(in: scrollView.documentVisibleRect).map { source.cell(row: $0, column: 0).text }
            .joined(separator: "\n")
    }

    public func codeLines(_ view: CodeLinesView, accessibilityLabelFor row: Int) -> String {
        guard let source = model.source else { return "" }
        var parts: [String] = []
        for column in 0..<source.columnCount {
            let cell = source.cell(row: row, column: column)
            switch cell.kind {
            case .added: parts.append("Added line \(cell.newNumber ?? 0): \(cell.text)")
            case .deleted: parts.append("Removed line \(cell.oldNumber ?? 0): \(cell.text)")
            case .context: parts.append("Line \(cell.newNumber ?? cell.oldNumber ?? 0): \(cell.text)")
            case .hunk: parts.append("Hunk \(cell.text)")
            case .gap: parts.append(cell.text)
            case .file: parts.append("File \(cell.text)")
            case .filler: continue
            case .conflict, .resolved, .marker: parts.append(cell.text)
            }
            if cell.isFullWidth { break }
        }
        if source.isSelected(row: row, column: 0) { parts.append("selected") }
        return parts.joined(separator: "; ")
    }

    /// VoiceOver line staging (design §3.6): select a line, extend the selection, then act on it — the same
    /// paths as clicks and the selection capsule.
    public func codeLines(_ view: CodeLinesView, accessibilityActionsFor row: Int) -> [NSAccessibilityCustomAction] {
        guard let source = model.source, source.cell(row: row, column: 0).kind != .hunk else { return [] }
        let changed = (0..<source.columnCount).contains {
            [.added, .deleted].contains(source.cell(row: row, column: $0).kind)
        }
        guard changed else { return [] }
        var actions = [
            NSAccessibilityCustomAction(name: "Select line") { [weak self] in
                self?.model.click(row: row, column: 0, modifiers: [])
                return true
            },
            NSAccessibilityCustomAction(name: "Extend selection to this line") { [weak self] in
                self?.model.click(row: row, column: 0, modifiers: .shift)
                return true
            },
        ]
        guard !model.selection.lines.isEmpty, case .some(let target) = model.target else { return actions }
        switch target {
        case .unstaged:
            actions.append(
                NSAccessibilityCustomAction(name: "Stage selected lines") { [weak self] in
                    self?.model.perform(.stage)
                    return true
                })
            actions.append(
                NSAccessibilityCustomAction(name: "Discard selected lines…") { [weak self] in
                    self?.model.perform(.discard)
                    return true
                })
        case .staged:
            actions.append(
                NSAccessibilityCustomAction(name: "Unstage selected lines") { [weak self] in
                    self?.model.perform(.unstage)
                    return true
                })
        default:
            break
        }
        return actions
    }

    // MARK: Menu actions

    @objc public func jitFind(_ sender: Any?) {
        guard model.source != nil else { return }
        findRequested &+= 1
    }

    /// Bumped to focus the find field (observed by the chrome).
    var findRequested = 0 {
        didSet { chrome?.rootView = DiffChromeView(model: model, controller: self, findRequest: findRequested) }
        // (chrome is nil after tearDown, so a late find request cannot recreate the cycle.)
    }

    @objc public func jitFindNext(_ sender: Any?) { model.nextMatch(forward: true) }
    @objc public func jitFindPrevious(_ sender: Any?) { model.nextMatch(forward: false) }
    @objc public func diffNextChange(_ sender: Any?) { model.nextChange(from: firstVisibleRow, forward: true) }
    @objc public func diffPreviousChange(_ sender: Any?) { model.nextChange(from: firstVisibleRow, forward: false) }
    /// View ▸ Close Diff (⌥⌘↩): back to the graph.
    @objc public func toggleFocusDiff(_ sender: Any?) { model.requestClose() }
    @objc public func showBlame(_ sender: Any?) { model.blame() }

    @objc public func diffGoToLine(_ sender: Any?) {
        guard let window = view.window, model.source != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Line number in the new version of the file."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces))
            else { return }
            MainActor.assumeIsolated { self?.model.goToLine(number) }
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(jitFindNext(_:)), #selector(jitFindPrevious(_:)): return !model.matches.isEmpty
        case #selector(diffNextChange(_:)), #selector(diffPreviousChange(_:)): return !model.changeRows.isEmpty
        case #selector(toggleFocusDiff(_:)):
            return model.target != nil
        case #selector(diffGoToLine(_:)), #selector(jitFind(_:)): return model.source != nil
        case #selector(showBlame(_:)): return model.document?.files.first?.newPath != nil
        default: return true
        }
    }
}

/// The diff's header (0.0.4; it was floating glass capsules): an opaque two-row bar over the body. Row one
/// names the file and carries Stage File and Close; row two has the side on the left, File View / Diff View in
/// the middle and the tools on the right — blame, change navigation, layout, whitespace, wrap, find, options.
struct DiffChromeView: View {
    static let height: CGFloat = 76

    @Bindable var model: DiffViewModel
    let controller: DiffViewController
    var findRequest = 0
    @State private var showsFind = false
    /// The layout "Diff View" returns to after "File View".
    @State private var diffLayout = DiffLayout.unified
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .padding(.horizontal, Space.s5)
                .frame(height: 34)
            toolsRow
                .padding(.horizontal, Space.s5)
                .frame(height: 40)
            Rectangle().fill(ColorToken.borderSubtle.color).frame(height: Border.hairline)
            if let banner = model.banner {
                HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.token(.statusInfo))
                        .accessibilityHidden(true)
                    Text(banner)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textPrimary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
                .padding(Space.s4)
                .background(ColorToken.surfaceRaised.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.surfacePanel.color)
        .ignoresSafeArea()
        .sheet(item: Binding(get: { model.pendingDiscard }, set: { if $0 == nil { model.cancelDiscard() } })) {
            request in
            LineDiscardSheet(request: request, cancel: model.cancelDiscard, confirm: model.confirmDiscard)
        }
        .onChange(of: findRequest) {
            showsFind = true
            findFocused = true
        }
        .onChange(of: model.layout, initial: true) { _, layout in
            if layout != .fullFile { diffLayout = layout }
        }
    }

    // MARK: Row one — the file

    private var titleRow: some View {
        let path = DisplayText.sanitize(model.title)
        return HStack(spacing: Space.s4) {
            Image(systemName: "doc.text")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            FilePathText(
                directory: (path as NSString).deletingLastPathComponent, name: (path as NSString).lastPathComponent
            )
            .font(TypeToken.body.font)
            .help(path)
            Spacer(minLength: Space.s4)
            if let action = model.fileStageAction, model.onStageFile != nil {
                Button(action.stage ? "Stage File" : "Unstage File") { model.stageFile() }
                    .outlineButton(action.stage ? .success : .danger)
                    .help(action.stage ? "Stage every change in this file" : "Unstage every change in this file")
            }
            Button {
                model.requestClose()
            } label: {
                Image(systemName: "xmark")
                    .symbolSize(IconSize.md - 2, weight: .medium)
                    .foregroundStyle(.token(.textSecondary))
                    .frame(width: IconSize.lg + Space.s2, height: IconSize.lg + Space.s2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Diff (Esc)")
            .accessibilityLabel("Close diff")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Row two — side, view, tools

    private var toolsRow: some View {
        ViewThatFits(in: .horizontal) {
            tools(compact: false)
            tools(compact: true)
        }
    }

    private func tools(compact: Bool) -> some View {
        HStack(spacing: Space.s4) {
            Text(model.subtitle)
                .typeStyle(.caption)
                .foregroundStyle(.token(.textSecondary))
                .lineLimit(1)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1)
                .background(
                    ColorToken.stateHover.color, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                )
                .fixedSize()
            Spacer(minLength: Space.s2)
            if model.source != nil {
                viewPicker
                Spacer(minLength: Space.s2)
                if compact {
                    navigator(showsCount: false)
                    findGroup
                    compactMenu
                } else {
                    Button("Blame") { model.blame() }
                        .outlineButton(.neutral)
                        .help("Blame this file")
                    navigator(showsCount: true)
                    layoutButtons
                    displayToggles
                    findGroup
                    optionsMenu
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The whole file, or only what changed.
    private var viewPicker: some View {
        Picker(
            "View",
            selection: Binding(
                get: { model.layout == .fullFile },
                set: { model.layout = $0 ? .fullFile : diffLayout })
        ) {
            Text("File View").tag(true)
            Text("Diff View").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Show the whole file, or only the changes")
    }

    private func navigator(showsCount: Bool) -> some View {
        HStack(spacing: Space.s1) {
            ChromeToggle(symbol: "arrow.up", title: "Previous Change (⌥↑)", isOn: false) {
                controller.diffPreviousChange(nil)
            }
            ChromeToggle(symbol: "arrow.down", title: "Next Change (⌥↓)", isOn: false) {
                controller.diffNextChange(nil)
            }
            if showsCount {
                Text("\(model.changeRows.count)")
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textTertiary))
                    .help("\(model.changeRows.count) \(model.changeRows.count == 1 ? "change" : "changes")")
            }
        }
    }

    /// One page (unified) or side by side: one click each.
    private var layoutButtons: some View {
        HStack(spacing: Space.s1) {
            ChromeToggle(symbol: "rectangle", title: "Unified (one page)", isOn: model.layout == .unified) {
                model.layout = .unified
            }
            ChromeToggle(symbol: "rectangle.split.2x1", title: "Side by Side", isOn: model.layout == .split) {
                model.layout = .split
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout")
    }

    /// Ignore whitespace changes and wrap long lines, as switches.
    private var displayToggles: some View {
        HStack(spacing: Space.s1) {
            ChromeToggle(
                symbol: "paragraphsign",
                title: model.ignoresWhitespace
                    ? "Ignoring leading and trailing whitespace changes"
                    : "Ignore leading and trailing whitespace changes",
                isOn: model.ignoresWhitespace
            ) {
                model.ignoresWhitespace.toggle()
            }
            ChromeToggle(
                symbol: "text.alignleft", title: model.wrapsLines ? "Wrapping long lines" : "Wrap long lines",
                isOn: model.wrapsLines
            ) {
                model.wrapsLines.toggle()
            }
        }
    }

    private var compactMenu: some View {
        Menu {
            Picker("Layout", selection: $model.layout) {
                Text("Unified").tag(DiffLayout.unified)
                Text("Side by Side").tag(DiffLayout.split)
                Text("Full File").tag(DiffLayout.fullFile)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Wrap Lines", isOn: $model.wrapsLines)
            Toggle("Ignore Whitespace Changes", isOn: $model.ignoresWhitespace)
            Toggle("Show Whitespace", isOn: $model.showsWhitespace)
            Toggle("Highlight Word Changes", isOn: $model.showsWordDiff)
            Toggle("Syntax Highlighting", isOn: $model.highlightsSyntax)
            Divider()
            Button("Go to Line…") { controller.diffGoToLine(nil) }
            Button("Blame File") { model.blame() }
        } label: {
            Image(systemName: "ellipsis").symbolSize(IconSize.md)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Layout and Options")
        .accessibilityLabel("Layout and options")
    }

    @ViewBuilder
    private var findGroup: some View {
        if showsFind {
            HStack(spacing: Space.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.token(.textSecondary))
                    .accessibilityHidden(true)
                TextField("Find", text: $model.query)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
                    .focused($findFocused)
                    .onSubmit { model.nextMatch(forward: true) }
                    .onExitCommand {
                        model.query = ""
                        showsFind = false
                        controller.focusBody()
                    }
                Text(model.matchSummary)
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textTertiary))
                Button {
                    model.nextMatch(forward: false)
                } label: {
                    Image(systemName: "chevron.left").symbolSize(IconSize.sm)
                }
                .accessibilityLabel("Previous match")
                Button {
                    model.nextMatch(forward: true)
                } label: {
                    Image(systemName: "chevron.right").symbolSize(IconSize.sm)
                }
                .accessibilityLabel("Next match")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(ColorToken.stateHover.color, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        } else {
            ChromeToggle(symbol: "magnifyingglass", title: "Find in Diff (⌘F)", isOn: false) {
                showsFind = true
                findFocused = true
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Whitespace", isOn: $model.showsWhitespace)
            Toggle("Highlight Word Changes", isOn: $model.showsWordDiff)
            Toggle("Syntax Highlighting", isOn: $model.highlightsSyntax)
            Divider()
            Button("Go to Line…") { controller.diffGoToLine(nil) }
        } label: {
            Image(systemName: "ellipsis").symbolSize(IconSize.md)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Diff Options")
        .accessibilityLabel("Diff options")
    }
}

/// An icon switch in the diff chrome: accent fill while on, plain while off.
private struct ChromeToggle: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolSize(IconSize.md - 2, weight: isOn ? .semibold : .regular)
                .foregroundStyle(isOn ? .token(.accentBase) : .token(.textSecondary))
                .frame(width: IconSize.lg + Space.s3, height: IconSize.lg + Space.s2)
                .background(
                    isOn ? ColorToken.accentMuted.color : isHovered ? ColorToken.stateHover.color : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Hosts the shared diff controller's view in SwiftUI (inspector) — reparents it on appear.
struct DiffPane: NSViewRepresentable {
    let controller: DiffViewController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        let view = controller.view
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

/// Loading / failed / binary / empty messages over the body; hidden (no hit testing) when rows show.
struct DiffMessageView: View {
    let model: DiffViewModel

    var body: some View {
        VStack {
            content
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .loading:
            if model.showsSpinner { ProgressView().controlSize(.small).accessibilityLabel("Loading diff") }
        case .failed(let message):
            VStack(spacing: Space.s4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.statusDanger))
                Button("Reload") { model.reload() }
            }
            .padding(.top, DiffChromeView.height + Space.s8)
        case .loaded:
            if let message = model.message {
                Text(message)
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.top, DiffChromeView.height + Space.s8)
            }
        }
    }

}

/// Hosts the selection capsule at its own size, so the rest of the body stays clickable.
struct SelectionCapsuleHost: View {
    let model: DiffViewModel

    var body: some View {
        if model.selection.isEmpty {
            EmptyView()
        } else {
            SelectionCapsule(model: model).padding(Space.s4)
        }
    }
}

/// The floating glass action capsule for a line selection (design §3.3): primary action first, each
/// disabled one explains why.
struct SelectionCapsule: View {
    let model: DiffViewModel

    var body: some View {
        GlassControlGroup(spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Text("\(model.selection.count) selected")
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textSecondary))
                ForEach(Array(model.actionStates.enumerated()), id: \.offset) { index, state in
                    let button = Button(state.title) { model.perform(state.action) }
                        .disabled(!state.isEnabled)
                        .help(state.reason ?? shortcut(state.action))
                    if index == 0 {
                        button.primaryGlassButton()
                    } else {
                        button.secondaryGlassButton()
                            .foregroundStyle(state.isDestructive ? .token(.statusDanger) : .token(.textPrimary))
                    }
                }
            }
            .padding(.leading, Space.s5)
            .padding(.trailing, Space.s3)
            .padding(.vertical, Space.s3)
            .jitGlass(in: ChromeShape.control, interactive: false)
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection actions")
    }

    private func shortcut(_ action: SelectionAction) -> String {
        switch action {
        case .stage: "Stage the selected lines (S)"
        case .unstage: "Unstage the selected lines (U)"
        case .discard: "Discard the selected lines (⌫)"
        case .keepOnly: "Discard every other changed line in this file"
        }
    }
}

/// Confirmation for discarding lines (design §3.2): the exact lines lost and restored, recovery, and a
/// destructive button that is never default.
struct LineDiscardSheet: View {
    let request: LineDiscardRequest
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        let effect = request.effect
        let count = effect.lost.count + effect.restored.count
        VStack(alignment: .leading, spacing: Space.s6) {
            HStack(alignment: .top, spacing: Space.s5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolSize(IconSize.lg)
                    .foregroundStyle(.token(.statusWarning))
                    .accessibilityHidden(true)
                Text(
                    request.action == .keepOnly
                        ? "Keep only the selected lines in “\(DisplayText.sanitize(request.path))”?"
                        : "Discard \(count) selected \(count == 1 ? "line" : "lines") in “\(DisplayText.sanitize(request.path))”?"
                )
                .typeStyle(.headline)
                .foregroundStyle(.token(.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Only the working tree changes. Staged changes are kept.")
                Text(
                    "\(effect.lost.count) \(effect.lost.count == 1 ? "line is" : "lines are") removed and \(effect.restored.count) deleted \(effect.restored.count == 1 ? "line comes" : "lines come") back."
                )
                Text(
                    "A copy of the file is kept in Jit’s recovery folder for 7 days (Repository ▸ Recently Discarded).")
            }
            .typeStyle(.callout)
            .foregroundStyle(.token(.textSecondary))
            VStack(alignment: .leading, spacing: 0) {
                ForEach((effect.lost + effect.restored).sorted().prefix(20), id: \.self) { line in
                    let lost = request.document.kind(ofLine: line) == .added
                    HStack(spacing: Space.s3) {
                        Text(lost ? "−" : "+")
                            .foregroundStyle(.token(lost ? .diffDeleteMark : .diffAddMark))
                            .frame(width: 10)
                        Text(DisplayText.sanitize(request.document.text(ofLine: line)))
                            .foregroundStyle(.token(.textPrimary))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .typeStyle(.monoCaption)
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, 1)
                    .background((lost ? ColorToken.diffDeleteBackground : .diffAddBackground).color)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(lost ? "Removed" : "Restored"): \(request.document.text(ofLine: line))")
                }
                if count > 20 {
                    Text("and \(count - 20) more")
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                        .padding(.horizontal, Space.s4)
                }
            }
            .padding(.vertical, Space.s3)
            .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: confirm) {
                    Text("Discard").foregroundStyle(.token(.statusDanger))
                }
            }
            .controlSize(.large)
        }
        .padding(Space.s8)
        .frame(width: 480)
        .onExitCommand(perform: cancel)
    }
}
