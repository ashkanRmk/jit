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
        let chrome = NSHostingView(rootView: DiffChromeView(model: model, controller: self))
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.sizingOptions = []
        chrome.safeAreaRegions = []  // the bar sits at the pane's top, not below the window toolbar
        root.addSubview(chrome)
        self.chrome = chrome
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        model.onSourceChange = { [weak self] in self?.sourceChanged() }
        model.onRedraw = { [weak self] in
            self?.codeView.showsWhitespace = self?.model.showsWhitespace ?? false
            self?.codeView.refreshRows()
        }
        model.scrollToRow = { [weak self] row, center in self?.codeView.scrollToRow(row, center: center) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        sourceChanged()
    }

    @objc private func frameChanged() { codeView.reloadData() }

    private func sourceChanged() {
        codeView.showsWhitespace = model.showsWhitespace
        codeView.dataSource = model.source
        scrollView.isHidden = model.source == nil
    }

    /// First visible row (for change navigation).
    var firstVisibleRow: Int {
        Int(max(0, scrollView.documentVisibleRect.minY) / codeView.rowHeight)
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
            if model.isFocused {
                model.isFocused = false
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
        let first = firstVisibleRow
        let count = Int(scrollView.documentVisibleRect.height / codeView.rowHeight)
        return (first..<min(source.rowCount, first + count)).map { source.cell(row: $0, column: 0).text }
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
            }
            if cell.isFullWidth { break }
        }
        if source.isSelected(row: row, column: 0) { parts.append("selected") }
        return parts.joined(separator: "; ")
    }

    // MARK: Menu actions

    @objc public func jitFind(_ sender: Any?) {
        guard model.source != nil else { return }
        findRequested &+= 1
    }

    /// Bumped to focus the find field (observed by the chrome).
    var findRequested = 0 {
        didSet { chrome?.rootView = DiffChromeView(model: model, controller: self, findRequest: findRequested) }
    }

    @objc public func jitFindNext(_ sender: Any?) { model.nextMatch(forward: true) }
    @objc public func jitFindPrevious(_ sender: Any?) { model.nextMatch(forward: false) }
    @objc public func diffNextChange(_ sender: Any?) { model.nextChange(from: firstVisibleRow, forward: true) }
    @objc public func diffPreviousChange(_ sender: Any?) { model.nextChange(from: firstVisibleRow, forward: false) }
    @objc public func toggleFocusDiff(_ sender: Any?) { model.isFocused.toggle() }

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
            menuItem.state = model.isFocused ? .on : .off
            return model.target != nil
        case #selector(diffGoToLine(_:)), #selector(jitFind(_:)): return model.source != nil
        default: return true
        }
    }
}

/// Floating glass chrome over the diff body (ADR-0006): file title, layout switcher, change navigator,
/// find, options and focus. Only the capsules are glass; the body stays opaque.
struct DiffChromeView: View {
    static let height: CGFloat = 52

    @Bindable var model: DiffViewModel
    let controller: DiffViewController
    var findRequest = 0
    @State private var showsFind = false
    @FocusState private var findFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            content
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    bar(compact: false)
                    bar(compact: true)
                }
                .padding(.horizontal, Space.s5)
                .padding(.top, Space.s4)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .onChange(of: findRequest) {
            showsFind = true
            findFocused = true
        }
    }

    /// Full bar, or (narrow inspector) title + compact controls: layout and options in one menu.
    private func bar(compact: Bool) -> some View {
        GlassControlGroup(spacing: Space.s4) {
            titleCapsule
                .frame(minWidth: compact ? 80 : 160, maxWidth: compact ? 220 : 360, alignment: .leading)
            Spacer(minLength: Space.s3)
            if model.source != nil {
                if compact {
                    compactNavigator
                    findGroup
                    compactMenu
                } else {
                    layoutPicker
                    changeNavigator
                    findGroup
                    optionsMenu
                }
            }
            focusButton
        }
        .fixedSize(horizontal: !compact, vertical: true)
    }

    private var compactNavigator: some View {
        HStack(spacing: Space.s2) {
            Button {
                controller.diffPreviousChange(nil)
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel("Previous change")
            Button {
                controller.diffNextChange(nil)
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Next change")
        }
        .buttonStyle(.borderless)
        .help("\(model.changeRows.count) changes (⌥↑ ⌥↓)")
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .jitGlass(in: Capsule())
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
            Toggle("Show Whitespace", isOn: $model.showsWhitespace)
            Toggle("Ignore Whitespace Changes", isOn: $model.ignoresWhitespace)
            Divider()
            Button("Go to Line…") { controller.diffGoToLine(nil) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Layout and Options")
        .accessibilityLabel("Layout and options")
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
            .padding(.top, Self.height + Space.s8)
        case .loaded:
            if let message = model.message {
                Text(message)
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.top, Self.height + Space.s8)
            }
        }
    }

    private var titleCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DisplayText.sanitize(model.title))
                .typeStyle(.callout)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.subtitle)
                .typeStyle(.caption)
                .foregroundStyle(.token(.textSecondary))
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s2)
        .jitGlass(in: Capsule(), interactive: false)
        .accessibilityElement(children: .combine)
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $model.layout) {
            Image(systemName: "rectangle").tag(DiffLayout.unified).help("Unified").accessibilityLabel("Unified")
            Image(systemName: "rectangle.split.2x1").tag(DiffLayout.split).help("Side by Side")
                .accessibilityLabel("Side by side")
            Image(systemName: "doc.plaintext").tag(DiffLayout.fullFile).help("Full File").accessibilityLabel(
                "Full file")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Layout")
    }

    private var changeNavigator: some View {
        HStack(spacing: Space.s2) {
            Button {
                controller.diffPreviousChange(nil)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous Change (⌥↑)")
            .accessibilityLabel("Previous change")
            Text("\(model.changeRows.count) \(model.changeRows.count == 1 ? "change" : "changes")")
                .typeStyle(.caption)
                .monospacedDigit()
                .foregroundStyle(.token(.textSecondary))
            Button {
                controller.diffNextChange(nil)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next Change (⌥↓)")
            .accessibilityLabel("Next change")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .jitGlass(in: Capsule())
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
                    .frame(width: 140)
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
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous match")
                Button {
                    model.nextMatch(forward: true)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next match")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .jitGlass(in: Capsule())
        } else {
            Button {
                showsFind = true
                findFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.glass)
            .help("Find in Diff (⌘F)")
            .accessibilityLabel("Find in diff")
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Whitespace", isOn: $model.showsWhitespace)
            Toggle("Ignore Whitespace Changes", isOn: $model.ignoresWhitespace)
            Divider()
            Button("Go to Line…") { controller.diffGoToLine(nil) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Diff Options")
        .accessibilityLabel("Diff options")
    }

    private var focusButton: some View {
        Button {
            model.isFocused.toggle()
        } label: {
            Image(
                systemName: model.isFocused
                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.glass)
        .help(model.isFocused ? "Exit Focused Diff (Esc)" : "Focus Diff (⌥⌘↩)")
        .accessibilityLabel(model.isFocused ? "Exit focused diff" : "Focus diff")
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
