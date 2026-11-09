import AppKit
import DesignSystem
import GitCore
import Observation
import SwiftUI

/// Rows of one resolver pane for `CodeLinesView` (only visible rows become strings; syntax lexed per row).
@MainActor
final class PaneSource: CodeLinesDataSource {
    let pane: PaneText.Pane
    weak var model: ResolverModel?
    private var lexer: Lexer?
    private var syntaxCache: [Int: [(NSRange, NSColor)]] = [:]

    init(pane: PaneText.Pane, model: ResolverModel) {
        self.pane = pane
        self.model = model
        if let path = model.entry?.path {
            let language = SyntaxLanguage.detect(path: path)
            lexer = language == .plain ? nil : Lexer(language)
        }
    }

    var text: PaneText {
        guard let model else { return PaneText() }
        switch pane {
        case .ours: return model.ours
        case .theirs: return model.theirs
        case .base: return model.base
        case .result: return model.result
        }
    }

    func invalidate() { syntaxCache = [:] }

    var rowCount: Int { text.lineCount }
    var columnCount: Int { 1 }
    var maxColumnCharacters: Int { text.maxColumns }
    var maxLineNumber: Int { Int(text.numbers.last ?? 1) }
    var lineNumberColumns: Int { 1 }

    func cell(row: Int, column: Int) -> CodeCell {
        let pane = text
        guard row < pane.lineCount else { return CodeCell(kind: .context) }
        let number = pane.numbers[row]
        return CodeCell(kind: pane.kinds[row], newNumber: number > 0 ? Int(number) : nil, text: pane.text(row))
    }

    func isSelected(row: Int, column: Int) -> Bool {
        guard let segment = model?.currentSegment, row < text.segments.count else { return false }
        return text.segments[row] == Int32(segment)
    }

    func highlights(row: Int, column: Int) -> (ranges: [NSRange], current: NSRange?) { ([], nil) }

    func syntax(row: Int, column: Int) -> [(NSRange, NSColor)] {
        guard let lexer, row < text.lineCount, text.kinds[row] != .marker else { return [] }
        if let cached = syntaxCache[row] { return cached }
        var state = LexerState()
        let spans = lexer.lex(Array(text.text(row).utf16), state: &state).map { ($0.range, $0.syntaxColor.nsColor) }
        if syntaxCache.count > 2_000 { syntaxCache.removeAll(keepingCapacity: true) }
        syntaxCache[row] = spans
        return spans
    }
}

/// A titled, opaque code pane (content layer: no glass behind code — ADR-0006).
@MainActor
final class ResolverPaneView: NSView, CodeLinesDelegate {
    let codeView = CodeLinesView()
    let source: PaneSource
    private let title = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    var onSelectSegment: ((Int) -> Void)?

    init(source: PaneSource, title text: String) {
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ColorToken.surfaceCanvas.nsColor.cgColor
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = ColorToken.surfacePanel.nsColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = text
        title.font = TypeToken.caption.nsFont
        title.textColor = ColorToken.textSecondary.nsColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ColorToken.surfaceCanvas.nsColor
        scroll.documentView = codeView
        codeView.delegate = self
        addSubview(header)
        addSubview(scroll)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Space.s8),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Space.s5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -Space.s5),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    func setTitle(_ text: String) {
        title.stringValue = text
        setAccessibilityLabel(text)
    }

    func reload() {
        source.invalidate()
        codeView.dataSource = source
        codeView.reloadData()
    }

    func reveal(segment: Int) {
        guard let rows = source.text.blockRows[segment] else { return }
        codeView.scrollToRow(rows.lowerBound, center: true)
        codeView.refreshRows()
    }

    // MARK: CodeLinesDelegate

    func codeLines(_ view: CodeLinesView, clickedRow row: Int, column: Int, modifiers: NSEvent.ModifierFlags) {
        let segments = source.text.segments
        guard row < segments.count, segments[row] >= 0 else { return }
        onSelectSegment?(Int(segments[row]))
    }

    func codeLines(_ view: CodeLinesView, draggedTo row: Int, column: Int) {}
    func codeLines(_ view: CodeLinesView, keyDown event: NSEvent) -> Bool { false }

    func codeLinesCopyText(_ view: CodeLinesView) -> String? {
        guard let segment = source.model?.currentSegment, let rows = source.text.blockRows[segment] else { return nil }
        return rows.map { source.text.text($0) }.joined(separator: "\n")
    }

    func codeLines(_ view: CodeLinesView, accessibilityLabelFor row: Int) -> String {
        let text = source.text
        guard row < text.lineCount else { return "" }
        let state: String
        switch text.kinds[row] {
        case .conflict: state = "unresolved conflict"
        case .resolved: state = "resolved"
        case .marker: state = "marker"
        default: state = "line \(text.numbers[row])"
        }
        return "\(state): \(text.text(row))"
    }
}

/// The resolver (design §3.8): covers the graph area. Ours / theirs (/ base) above, result below; the block
/// navigator and actions are one floating glass control group; the panes are opaque.
@MainActor
final class ResolverViewController: NSViewController {
    let model: ResolverModel
    private var oursPane: ResolverPaneView?
    private var theirsPane: ResolverPaneView?
    private var basePane: ResolverPaneView?
    private var resultPane: ResolverPaneView?
    private let sidesSplit = NSSplitView()
    private let mainSplit = NSSplitView()
    private var textContainer = NSView()
    private var stateHost: NSHostingView<ResolverStateView>?
    private var lastRevision = -1
    private var lastSegment: Int?
    private var lastEntry: String?

    init(model: ResolverModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = ResolverRootView()
        root.controller = self
        root.wantsLayer = true
        view = root

        sidesSplit.isVertical = true
        sidesSplit.dividerStyle = .thin
        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thin
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.addArrangedSubview(sidesSplit)
        textContainer = mainSplit

        let state = NSHostingView(rootView: ResolverStateView(model: model))
        state.translatesAutoresizingMaskIntoConstraints = false
        state.sizingOptions = []
        stateHost = state

        let header = NSHostingView(rootView: ResolverHeader(model: model))
        header.translatesAutoresizingMaskIntoConstraints = false
        header.sizingOptions = [.intrinsicContentSize]
        // The header keeps its natural height; the panes take the rest.
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.required, for: .vertical)

        root.addSubview(mainSplit)
        root.addSubview(state)
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: header.bottomAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            state.topAnchor.constraint(equalTo: header.bottomAnchor),
            state.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            state.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        observe()
        apply()
    }

    private func observe() {
        withObservationTracking {
            _ = model.revision
            _ = model.current
            _ = model.phase
            _ = model.showsBase
            _ = model.entry
            _ = model.labels
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
    }

    private func buildPanes() {
        for view in sidesSplit.arrangedSubviews { view.removeFromSuperview() }
        resultPane?.removeFromSuperview()
        let ours = ResolverPaneView(source: PaneSource(pane: .ours, model: model), title: "OURS — \(model.labels.ours)")
        let theirs = ResolverPaneView(
            source: PaneSource(pane: .theirs, model: model), title: "THEIRS — \(model.labels.theirs)")
        let base = ResolverPaneView(source: PaneSource(pane: .base, model: model), title: "BASE — common ancestor")
        let result = ResolverPaneView(
            source: PaneSource(pane: .result, model: model), title: "RESULT — \(model.entry?.path ?? "")")
        for pane in [ours, theirs, base, result] {
            pane.onSelectSegment = { [weak self] segment in self?.model.select(segment: segment) }
        }
        sidesSplit.addArrangedSubview(ours)
        if model.showsBase { sidesSplit.addArrangedSubview(base) }
        sidesSplit.addArrangedSubview(theirs)
        let resultContainer = NSView()
        let actions = NSHostingView(rootView: BlockActionStrip(model: model))
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.sizingOptions = [.intrinsicContentSize]
        actions.setContentHuggingPriority(.required, for: .vertical)
        actions.setContentCompressionResistancePriority(.required, for: .vertical)
        result.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.addSubview(actions)
        resultContainer.addSubview(result)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: resultContainer.topAnchor),
            actions.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
            result.topAnchor.constraint(equalTo: actions.bottomAnchor),
            result.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            result.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
            result.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor),
        ])
        if mainSplit.arrangedSubviews.count > 1 { mainSplit.arrangedSubviews[1].removeFromSuperview() }
        mainSplit.addArrangedSubview(resultContainer)
        oursPane = ours
        theirsPane = theirs
        basePane = base
        resultPane = result
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if mainSplit.bounds.height > 0 { mainSplit.setPosition(mainSplit.bounds.height * 0.45, ofDividerAt: 0) }
            // Equal side panes.
            let panes = sidesSplit.arrangedSubviews.count
            let width = sidesSplit.bounds.width
            for index in 0..<max(panes - 1, 0) where width > 0 {
                sidesSplit.setPosition(width * CGFloat(index + 1) / CGFloat(panes), ofDividerAt: index)
            }
        }
    }

    private func apply() {
        let isText = model.phase == .text
        mainSplit.isHidden = !isText
        stateHost?.isHidden = isText
        guard isText else { return }
        let entryChanged = model.entry?.path != lastEntry
        let baseChanged = (basePane?.superview != nil) != model.showsBase
        if oursPane == nil || entryChanged || baseChanged {
            buildPanes()
            lastEntry = model.entry?.path
            lastRevision = -1
        }
        oursPane?.setTitle("OURS — \(model.labels.ours)")
        theirsPane?.setTitle("THEIRS — \(model.labels.theirs)")
        if model.revision != lastRevision {
            lastRevision = model.revision
            for pane in [oursPane, theirsPane, basePane, resultPane] { pane?.reload() }
        } else {
            for pane in [oursPane, theirsPane, basePane, resultPane] { pane?.codeView.refreshRows() }
        }
        if let segment = model.currentSegment, segment != lastSegment || entryChanged {
            lastSegment = segment
            // Ours/theirs scroll-sync to the current block.
            for pane in [oursPane, theirsPane, basePane, resultPane] { pane?.reveal(segment: segment) }
        }
    }

    func focusResult() { view.window?.makeFirstResponder(resultPane?.codeView) }
}

/// Keyboard: ⌥⌘↓/↑ next/previous block, ⌘S save, ⇧⌘R mark resolved, ⌘Z/⇧⌘Z undo/redo, Esc closes.
final class ResolverRootView: NSView {
    weak var controller: ResolverViewController?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ColorToken.surfaceCanvas.nsColor.setFill()
        dirtyRect.fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model = controller?.model, !isHiddenOrHasHiddenAncestor else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (modifiers, event.keyCode, event.charactersIgnoringModifiers) {
        case ([.command, .option, .numericPad, .function], 125, _), ([.command, .option], 125, _):
            model.next(forward: true)
        case ([.command, .option, .numericPad, .function], 126, _), ([.command, .option], 126, _):
            model.next(forward: false)
        case ([.command], _, "s"):
            Task { await model.save() }
        case ([.command, .shift], _, "R"), ([.command, .shift], _, "r"):
            model.markResolved()
        case ([.command], _, "z"):
            model.undo()
        case ([.command, .shift], _, "Z"), ([.command, .shift], _, "z"):
            model.redo()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { controller?.model.controller.closeResolver() }
}

/// The floating glass control group (chrome): file, kind, operation, block navigator, Show Base, Save, Mark as
/// Resolved; plus the one-time rebase explanation and the external-change banner (both opaque strips).
struct ResolverHeader: View {
    @Bindable var model: ResolverModel
    @State private var showsRebaseNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s5) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(model.entry?.path ?? "Conflicts")
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([kindTitle, model.operationTitle].compactMap { $0 }.joined(separator: " · "))
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textSecondary))
                        .lineLimit(1)
                }
                .layoutPriority(-1)
                Spacer(minLength: Space.s4)
                GlassControlGroup(spacing: Space.s3) {
                    if model.phase == .text {
                        HStack(spacing: Space.s3) {
                            Button {
                                model.next(forward: false)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .help("Previous unresolved block (⌥⌘↑)")
                            .accessibilityLabel("Previous block")
                            Text(blockTitle)
                                .typeStyle(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.token(.textPrimary))
                                .lineLimit(1)
                                .fixedSize()
                            Button {
                                model.next(forward: true)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .help("Next unresolved block (⌥⌘↓)")
                            .accessibilityLabel("Next block")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Space.s5)
                        .padding(.vertical, Space.s3)
                        .jitGlass(in: Capsule())
                        Toggle("Show Base", isOn: $model.showsBase)
                            .toggleStyle(.button)
                            .buttonStyle(.glass)
                        Button("Save") { Task { await model.save() } }
                            .buttonStyle(.glass)
                            .disabled(!model.isDirty || model.externalChange)
                            .keyboardShortcut("s", modifiers: .command)
                        markResolvedButton
                    }
                    Button {
                        model.controller.closeResolver()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.glass)
                    .help("Close the resolver (Esc). Nothing is marked resolved.")
                    .accessibilityLabel("Close resolver")
                }
            }
            if model.isRebase, showsRebaseNote, let explanation = model.labels.explanation {
                InfoStrip(icon: "arrow.triangle.swap", text: explanation, tint: .statusInfo) {
                    showsRebaseNote = false
                }
            }
            if model.externalChange {
                HStack(spacing: Space.s4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.token(.statusWarning))
                        .accessibilityHidden(true)
                    Text("“\(model.entry?.path ?? "")” changed outside Jit. Saving is blocked until you choose.")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textPrimary))
                    Spacer()
                    Button("Reload from Disk") { model.reloadFromDisk() }
                    Button("Keep My Result") { model.keepMyResult() }
                }
                .padding(Space.s4)
                .background(ColorToken.conflictBackground.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .background(ColorToken.surfaceCanvas.color)
        .onAppear {
            if model.isRebase, !model.controller.explainedRebaseLabels {
                model.controller.explainedRebaseLabels = true
                showsRebaseNote = true
            }
        }
    }

    @ViewBuilder private var markResolvedButton: some View {
        if model.canMarkResolved {
            Button("Mark as Resolved") { model.markResolved() }
                .primaryGlassButton()
                .keyboardShortcut("r", modifiers: [.command, .shift])
        } else {
            Button("Mark as Resolved") {}
                .buttonStyle(.glass)
                .disabled(true)
                .help(
                    model.externalChange
                        ? "Choose how to handle the change on disk first." : "Resolve every block first.")
        }
    }

    private var blockTitle: String {
        let total = model.blocks.count
        guard total > 0 else { return "No blocks" }
        let unresolved = model.unresolvedCount
        return unresolved == 0
            ? "All \(total) resolved" : "Block \(model.current + 1) of \(total) · \(unresolved) unresolved"
    }

    private var kindTitle: String? {
        guard let entry = model.entry else { return nil }
        switch entry.code {
        case .bothModified: return "Both modified"
        case .bothAdded: return "Both added"
        case .deletedByThem: return "Deleted by them"
        case .deletedByUs: return "Deleted by us"
        case .addedByUs: return "Added by us"
        case .addedByThem: return "Added by them"
        case .bothDeleted: return "Both deleted"
        }
    }
}

/// Plain (opaque) per-block actions above the result pane — never per-block glass.
struct BlockActionStrip: View {
    @Bindable var model: ResolverModel

    var body: some View {
        HStack(spacing: Space.s4) {
            if let segment = model.currentSegment {
                Text(model.choicesLabel(segment))
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
                Spacer(minLength: Space.s4)
                Button("Take Ours") { model.choose(.ours) }
                Button("Take Theirs") { model.choose(.theirs) }
                Menu("Both") {
                    Button("Ours, then Theirs") { model.choose(.oursThenTheirs) }
                    Button("Theirs, then Ours") { model.choose(.theirsThenOurs) }
                    Button("Base") { model.choose(.base) }
                }
                .fixedSize()
                Button("Edit…") { model.editing = segment }
                Button("Reset") { model.reset() }
                    .disabled(model.isUnresolved(segment))
            } else {
                Text("No conflict blocks")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
                Spacer()
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .background(ColorToken.surfacePanel.color)
        .sheet(
            item: Binding(
                get: { model.editing.map { EditTarget(segment: $0) } }, set: { model.editing = $0?.segment })
        ) { target in
            BlockEditor(text: model.editableText(for: target.segment), path: model.entry?.path ?? "") { text in
                model.applyEdit(text, to: target.segment)
            } cancel: {
                model.editing = nil
            }
        }
    }

    struct EditTarget: Identifiable {
        let segment: Int
        var id: Int { segment }
    }
}

extension ResolverModel {
    func isUnresolved(_ segment: Int) -> Bool { choices[segment] == nil }

    func choicesLabel(_ segment: Int) -> String {
        switch choices[segment] {
        case nil: "Unresolved block — choose a side"
        case .ours?: "Resolved: ours"
        case .theirs?: "Resolved: theirs"
        case .oursThenTheirs?: "Resolved: ours, then theirs"
        case .theirsThenOurs?: "Resolved: theirs, then ours"
        case .base?: "Resolved: base"
        case .custom?: "Resolved: edited by hand"
        }
    }
}

/// Manual edit of one block (plain text editor in a standard sheet).
struct BlockEditor: View {
    @State var text: String
    let path: String
    let save: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Edit block in “\(path)”")
                .typeStyle(.headline)
            Text("Write the text this block should contain. It replaces the block in the result.")
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
            PlainCodeEditor(text: $text)
                .frame(minWidth: 560, minHeight: 280)
                .border(ColorToken.borderSubtle.color)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Text") { save(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s8)
    }
}

/// Loading, failure, fallback (non-text) and all-done states.
struct ResolverStateView: View {
    @Bindable var model: ResolverModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: Space.s4) {
                    ProgressView().controlSize(.small)
                    Text("Loading the conflict…")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textTertiary))
                }
            case .failed(let message):
                Text(message)
                    .typeStyle(.body)
                    .foregroundStyle(.token(.statusDanger))
            case .done:
                VStack(spacing: Space.s5) {
                    Image(systemName: "checkmark.circle")
                        .symbolSize(IconSize.hero, weight: .light)
                        .foregroundStyle(.token(.statusSuccess))
                    Text("All conflicts are resolved.")
                        .typeStyle(.title)
                        .foregroundStyle(.token(.textPrimary))
                    Text("Continue the operation to create the commit.")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                    HStack {
                        Button("Close") { model.controller.closeResolver() }
                        Button("Continue") {
                            model.controller.closeResolver()
                            model.controller.continueOperation()
                        }
                        .primaryGlassButton()
                    }
                }
            case .fallback:
                if let entry = model.entry { FallbackView(entry: entry, model: model) }
            case .text:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfaceCanvas.color)
    }
}

/// Non-text conflicts (design §3.9): every choice goes through a confirmation describing its effect.
struct FallbackView: View {
    let entry: ConflictEntry
    let model: ResolverModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            Label(title, systemImage: icon)
                .typeStyle(.title)
                .foregroundStyle(.token(.textPrimary))
            Text(explanation)
                .typeStyle(.body)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s3) {
                side("Ours", stage: entry.ours, label: model.labels.ours)
                side("Theirs", stage: entry.theirs, label: model.labels.theirs)
            }
            .padding(Space.s5)
            .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            HStack(spacing: Space.s4) { actions }
                .controlSize(.large)
        }
        .frame(maxWidth: PanelMetrics.contentColumnMax + 120, alignment: .leading)
        .padding(Space.s9)
    }

    private func side(_ name: String, stage: ConflictStage?, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            Text(name).typeStyle(.headline).frame(width: 60, alignment: .leading)
            Text(
                stage.map {
                    "\(label) — \($0.isSymlink ? "symbolic link" : $0.isSubmodule ? "submodule commit" : "blob") \($0.oid.prefix(7))"
                } ?? "\(label) — deleted"
            )
            .typeStyle(.monoCaption)
            .foregroundStyle(.token(.textSecondary))
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private var actions: some View {
        let controller = model.controller
        switch entry.presentation {
        case .modifyDelete(let deletedBy):
            Button("Keep the File") {
                controller.resolveFallback(
                    entry, choice: .keepFile, label: "Keep the File",
                    effect:
                        "The \(deletedBy == .theirs ? "modified (ours)" : "modified (theirs)") file stays in the working tree and is staged (git add)."
                )
            }
            Button("Delete the File") {
                controller.resolveFallback(
                    entry, choice: .deleteFile, label: "Delete the File",
                    effect: "The file is removed from the working tree and the index (git rm).")
            }
        case .pickSide, .bothDeleted, .text:
            Button("Use Ours") {
                controller.resolveFallback(
                    entry, choice: .ours, label: "Use Ours",
                    effect: "The working tree gets our version (git checkout --ours) and it is staged.")
            }
            Button("Use Theirs") {
                controller.resolveFallback(
                    entry, choice: .theirs, label: "Use Theirs",
                    effect: "The working tree gets their version (git checkout --theirs) and it is staged.")
            }
            Button("Reveal in Finder") {
                RepositoryActions.revealInFinder(
                    ((controller.session.info?.topLevel ?? controller.session.path) as NSString).appendingPathComponent(
                        entry.path))
            }
        case .submodule:
            Button("Resolve in Terminal") {
                RepositoryActions.openInTerminal(controller.session.info?.topLevel ?? controller.session.path)
            }
        }
    }

    private var title: String {
        switch entry.presentation {
        case .modifyDelete(let deletedBy): "Modified by one side, deleted by \(deletedBy == .ours ? "ours" : "theirs")"
        case .pickSide(let reason): reason
        case .submodule: "Submodule conflict"
        case .bothDeleted: "Both sides renamed this file"
        case .text: "Conflict"
        }
    }

    private var icon: String {
        switch entry.presentation {
        case .modifyDelete: "trash.slash"
        case .pickSide: "doc.richtext"
        case .submodule: "shippingbox"
        case .bothDeleted: "arrow.triangle.branch"
        case .text: "doc.text"
        }
    }

    private var explanation: String {
        switch entry.presentation {
        case .modifyDelete: "One side changed this file and the other deleted it. Keep the changed file, or delete it."
        case .pickSide: "Jit can't merge this file line by line. Choose which side's version to keep."
        case .submodule:
            "Submodule conflicts need Git commands in the submodule. Jit doesn't resolve them yet (planned)."
        case .bothDeleted:
            "Git kept the renamed copies as separate paths. Resolve them, then remove or keep this original path."
        case .text: ""
        }
    }
}

/// A dismissible one-line explanation strip (opaque).
struct InfoStrip: View {
    let icon: String
    let text: String
    let tint: ColorToken
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: icon)
                .foregroundStyle(.token(tint))
                .accessibilityHidden(true)
            Text(text)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Got It", action: dismiss)
                .controlSize(.small)
        }
        .padding(Space.s4)
        .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}

/// A plain-text code editor: monospaced, no smart quotes/dashes, no text replacement, spelling or
/// autocorrection — what is typed is exactly what is written to the file.
struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = TypeToken.monoBody.nsFont
        textView.textColor = ColorToken.textPrimary.nsColor
        textView.backgroundColor = ColorToken.surfaceRaised.nsColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}
