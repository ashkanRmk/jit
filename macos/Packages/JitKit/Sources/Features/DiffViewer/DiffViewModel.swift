import AppKit
import Foundation
import GitCore
import Observation
import Services

/// State of the diff viewer (design §3.3): which target, which layout, the loaded document, search and
/// change navigation. Loads through `RepositorySession` (reads never take the write gate) and reloads
/// working-tree diffs when status changes (Observation, no polling).
@MainActor @Observable
public final class DiffViewModel {
    public enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Diffs larger than this are not rendered (design §3.3 large state).
    public static let maxBytes = 64 * 1024 * 1024

    public let session: RepositorySession
    public private(set) var target: DiffTarget?
    public private(set) var document: DiffDocument?
    public private(set) var state: State = .idle
    /// Shown after 120 ms of loading.
    public private(set) var showsSpinner = false
    public var layout: DiffLayout = DiffViewModel.storedLayout {
        didSet {
            guard layout != oldValue else { return }
            UserDefaults.standard.set(Self.name(layout), forKey: "diffLayout")
            rebuildSource()
        }
    }
    public var showsWhitespace = false { didSet { onSourceChange?() } }
    /// Word-level emphasis inside paired lines (ADR-0029).
    public var showsWordDiff = true { didSet { if showsWordDiff != oldValue { attachProviders(); onTextChange?() } } }
    /// Syntax colours (ADR-0012); applied when the off-main pass finishes.
    public var highlightsSyntax = true { didSet { if highlightsSyntax != oldValue { startHighlight() } } }
    public private(set) var language: SyntaxLanguage = .plain
    @ObservationIgnored private var highlight: HighlightResult?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var wordPairs: [Int: Int] = [:]
    @ObservationIgnored private var wordCache: [Int: [NSRange]] = [:]
    /// Text attributes changed (spans arrived): cached lines must be rebuilt.
    @ObservationIgnored public var onTextChange: (() -> Void)?
    public var ignoresWhitespace = false {
        didSet { if ignoresWhitespace != oldValue, let target { load(target, keepPosition: true) } }
    }
    /// Focused Diff: the viewer covers the graph area.
    public var isFocused = false
    /// The rows the view shows.
    public private(set) var source: DiffRowsSource?

    // Search.
    public var query = "" { didSet { if query != oldValue { runSearch() } } }
    public var caseSensitive = false { didSet { if caseSensitive != oldValue { runSearch() } } }
    public private(set) var matches: [RowMatch] = []
    public private(set) var currentMatch: Int?
    /// Rows where a run of changes starts, for ⌥↓/⌥↑.
    public private(set) var changeRows: [Int] = []
    public private(set) var currentChange: Int?

    // Line actions (P3.8).
    public private(set) var selection = LineSelection()
    /// Changed lines of the file in display order (selection ranges run over these).
    @ObservationIgnored private var changedLines: [Int] = []
    /// Banner over the diff: a stale reload, a refusal, a failure.
    public private(set) var banner: String?
    /// The discard / keep-only confirmation (design §3.2).
    public private(set) var pendingDiscard: LineDiscardRequest?
    @ObservationIgnored public var recovery = RecoveryStore()

    /// Opens blame for the diff's file (working copy, or the commit for commit diffs).
    @ObservationIgnored public var onBlame: (String, ObjectID?) -> Void = { _, _ in }

    public func blame() {
        guard let target, let path = document?.files.first?.newPath ?? target.path else { return }
        switch target {
        case .unstaged, .staged: onBlame(path, nil)
        case .commit(let oid, _): onBlame(path, oid)
        case .commits(_, let to, _, _): onBlame(path, to)
        case .commitToWorktree: onBlame(path, nil)
        }
    }

    /// Tells the view to reload (new source) or redraw (highlights).
    @ObservationIgnored public var onSourceChange: (() -> Void)?
    @ObservationIgnored public var onRedraw: (() -> Void)?
    @ObservationIgnored public var scrollToRow: ((Int, Bool) -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    public init(session: RepositorySession) {
        self.session = session
        observeLifecycle()
    }

    /// The document was dropped while the tab was hidden; it reloads when the tab shows again.
    public private(set) var isReleased = false

    /// Inactive tabs release diff buffers (P3.11): document, rows, spans; the target is kept.
    private func observeLifecycle() {
        withObservationTracking {
            _ = session.lifecycle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.lifecycleChanged()
                self.observeLifecycle()
            }
        }
    }

    private func lifecycleChanged() {
        switch session.lifecycle {
        case .inactive, .suspended, .closed:
            guard document != nil || state == .loading else { return }
            loadTask?.cancel()
            highlightTask?.cancel()
            highlight = nil
            document = nil
            source = nil
            selection.clear()
            wordPairs = [:]
            wordCache = [:]
            state = .idle
            isReleased = target != nil
            onSourceChange?()
        case .active:
            if isReleased, let target {
                isReleased = false
                load(target, keepPosition: false)
            }
        default:
            break
        }
    }

    static var storedLayout: DiffLayout {
        switch UserDefaults.standard.string(forKey: "diffLayout") {
        case "split": .split
        case "full": .fullFile
        default: .unified
        }
    }

    static func name(_ layout: DiffLayout) -> String {
        switch layout {
        case .unified: "unified"
        case .split: "split"
        case .fullFile: "full"
        }
    }

    // MARK: Loading

    public func open(_ target: DiffTarget) {
        guard target != self.target || state != .loaded else { return }
        query = ""
        load(target, keepPosition: false)
    }

    public func close() {
        selection.clear()
        banner = nil
        pendingDiscard = nil
        loadTask?.cancel()
        highlightTask?.cancel()
        highlight = nil
        spinnerTask?.cancel()
        target = nil
        document = nil
        source = nil
        state = .idle
        showsSpinner = false
        matches = []
        currentMatch = nil
        changeRows = []
        isFocused = false
        onSourceChange?()
    }

    public func reload() {
        guard let target else { return }
        load(target, keepPosition: true)
    }

    /// `diff.switch`: a new file was selected; ended by the view when the first frame with it is drawn.
    @ObservationIgnored public var switchSignpost: Signposts.Token?

    private func load(_ target: DiffTarget, keepPosition: Bool) {
        self.target = target
        if !keepPosition {
            switchSignpost.map(Signposts.end)
            switchSignpost = Signposts.begin(Signposts.diffSwitch)
        }
        loadTask?.cancel()
        spinnerTask?.cancel()
        if !keepPosition {
            state = .loading
            document = nil
            source = nil
            onSourceChange?()
        }
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, self.state == .loading else { return }
            self.showsSpinner = true
        }
        let options = DiffOptions(ignoreWhitespace: ignoresWhitespace)
        let session = self.session
        loadTask = Task { [weak self] in
            do throws(GitCoreError) {
                let document = try await session.openDiff(target, options: options)
                guard let self, !Task.isCancelled else { return }
                self.apply(document, keepPosition: keepPosition)
            } catch .cancelled {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.spinnerTask?.cancel()
                self.showsSpinner = false
                self.state = .failed(error.summary)
            }
        }
        observeStatus()
    }

    private func apply(_ newDocument: DiffDocument, keepPosition: Bool) {
        spinnerTask?.cancel()
        showsSpinner = false
        // A reload that shows the same bytes keeps everything (selection, expansion, scroll).
        if keepPosition, let document, document.storage.bytes == newDocument.storage.bytes,
            document.options == newDocument.options
        {
            self.document = DiffDocument(
                storage: document.storage, target: newDocument.target, options: newDocument.options,
                token: newDocument.token
            )
            .withGaps(of: document)
            state = .loaded
            return
        }
        // Different bytes: line indices changed, so a pending selection would point at other lines.
        if keepPosition, !selection.isEmpty {
            banner = "The file changed — diff updated and selection cleared."
        }
        selection.clear()
        document = newDocument
        state = .loaded
        wordPairs = WordDiff.pairs(in: newDocument)
        wordCache = [:]
        rebuildSource()
        startHighlight()
        #if DEBUG
            // `-JitFocusDiff YES` (screenshots).
            if UserDefaults.standard.bool(forKey: "JitFocusDiff"), !debugFocused {
                debugFocused = true
                isFocused = true
            }
            // `-JitDiffSelect <text>`: selects the changed lines containing it.
            if let text = UserDefaults.standard.string(forKey: "JitDiffSelect"), !debugSelected {
                debugSelected = true
                for line in changedLines where newDocument.text(ofLine: line).contains(text) {
                    selection.click(line, changed: changedLines, modifiers: .command)
                }
                selectionChanged()
            }
        #endif
    }

    @ObservationIgnored private var debugFocused = false
    @ObservationIgnored private var debugSelected = false

    /// Working-tree diffs follow status; commit diffs never change.
    private func observeStatus() {
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = session.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observing = false
                switch self.target {
                case .unstaged, .staged:
                    self.reload()
                default:
                    break
                }
            }
        }
    }

    // MARK: Layout

    public var isTooLarge: Bool { (document?.storage.bytes.count ?? 0) > Self.maxBytes }

    /// What to show instead of rows: binary, mode-only, empty.
    public var message: String? {
        guard let document, state == .loaded else { return nil }
        if isTooLarge {
            return "This diff is too large to display (\(document.storage.bytes.count / 1_048_576) MB)."
        }
        guard let file = document.files.first else { return "No changes." }
        if document.files.count == 1, document.hunks.isEmpty {
            if file.isBinary { return "Binary file changed." }
            if file.modeChanged {
                return
                    "Mode changed from \(String(file.oldMode ?? 0, radix: 8)) to \(String(file.newMode ?? 0, radix: 8))."
            }
            switch file.status {
            case .added: return "Empty file added."
            case .deleted: return "Empty file deleted."
            case .renamed: return "Renamed without changes."
            default: return "No changes."
            }
        }
        return nil
    }

    private func rebuildSource() {
        guard let document, !isTooLarge else {
            source = nil
            onSourceChange?()
            return
        }
        let source = DiffRowsSource(document: document, layout: layout)
        self.source = source
        changedLines = (0..<document.storage.lineCount).filter { document.kind(ofLine: $0) != .context }
        selection.restrict(to: Set(changedLines))
        source.selectedLines = selection.lines
        attachProviders()
        computeChangeRows()
        runSearch()
        onSourceChange?()
    }

    /// Highlights off the main actor; the body draws plain text until spans arrive (no layout shift:
    /// rows are fixed height).
    private func startHighlight() {
        highlightTask?.cancel()
        highlight = nil
        guard let document, highlightsSyntax else {
            attachProviders()
            onTextChange?()
            return
        }
        let path = document.files.first?.path ?? target?.path ?? ""
        let firstLine = document.storage.lineCount > 0 ? document.text(ofLine: 0) : nil
        let language = document.files.count == 1 ? SyntaxLanguage.detect(path: path, firstLine: firstLine) : .plain
        self.language = language
        highlightTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Highlighter.highlight(document, language: language)
            }.value
            guard let self, !Task.isCancelled, self.document === document else { return }
            self.highlight = result
            self.attachProviders()
            self.onTextChange?()
        }
    }

    private func attachProviders() {
        guard let source else { return }
        if let highlight, highlightsSyntax {
            source.syntaxProvider = { line in
                highlight.spans(forLine: line).map { ($0.range, $0.syntaxColor.nsColor) }
            }
        } else {
            source.syntaxProvider = nil
        }
        if showsWordDiff, !wordPairs.isEmpty, let document {
            source.emphasisProvider = { [weak self] line in
                guard let self, let partner = self.wordPairs[line] else { return [] }
                if let cached = self.wordCache[line] { return cached }
                let isOld = document.kind(ofLine: line) == .deleted
                let (old, new) = isOld ? (line, partner) : (partner, line)
                let ranges = WordDiff.ranges(old: document.text(ofLine: old), new: document.text(ofLine: new))
                self.wordCache[old] = ranges.old
                self.wordCache[new] = ranges.new
                return isOld ? ranges.old : ranges.new
            }
        } else {
            source.emphasisProvider = nil
        }
    }

    private func computeChangeRows() {
        guard let source else {
            changeRows = []
            return
        }
        var rows: [Int] = []
        var previousChanged = false
        for row in 0..<source.rowCount {
            let changed: Bool
            if let line = source.line(row: row, column: 0) ?? source.line(row: row, column: 1) {
                changed =
                    source.document.kind(ofLine: line) != .context
                    || (layout == .split && source.line(row: row, column: 0) != source.line(row: row, column: 1))
            } else {
                changed = false
            }
            if changed && !previousChanged { rows.append(row) }
            previousChanged = changed
        }
        changeRows = rows
        currentChange = nil
    }

    /// Reveals the collapsed lines of the gap shown in `row`.
    public func expandGap(atRow row: Int, lines: Int = 20) {
        guard let document, let source else { return }
        let gapIndex: Int?
        if layout == .split, case .gap(let index) = document.splitRow(row) {
            gapIndex = index
        } else if layout != .split, case .gap(let index) = document.row(layout, row) {
            gapIndex = index
        } else {
            gapIndex = nil
        }
        guard let gapIndex else { return }
        let selected = source.selectedLines
        self.document = document.expandingContext(gap: gapIndex, lines: lines)
        rebuildSource()
        self.source?.selectedLines = selected
    }

    // MARK: Line selection and actions

    private func selectionChanged() {
        source?.selectedLines = selection.lines
        onRedraw?()
    }

    /// A click on a row (`column` matters in side by side).
    public func click(row: Int, column: Int, modifiers: NSEvent.ModifierFlags) {
        guard let source, let document else { return }
        if layout == .split, case .hunk(let hunk) = document.splitRow(row) {
            selection.toggleHunk(document.hunks[hunk].lines.filter { document.kind(ofLine: $0) != .context })
        } else if layout != .split, case .hunk(let hunk) = document.row(layout, row) {
            selection.toggleHunk(document.hunks[hunk].lines.filter { document.kind(ofLine: $0) != .context })
        } else if let line = source.line(row: row, column: column) ?? source.line(row: row, column: 1 - column) {
            selection.click(line, changed: changedLines, modifiers: modifiers)
        } else {
            return
        }
        banner = nil
        selectionChanged()
    }

    public func drag(row: Int, column: Int) {
        guard let source, let line = source.line(row: row, column: column) ?? source.line(row: row, column: 1 - column)
        else { return }
        selection.drag(to: line, changed: changedLines)
        selectionChanged()
    }

    /// Keys while the diff body has focus: ↑/↓ (⇧ extends), Space, S, U, ⌫. Never while typing in a field.
    public func key(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command), !modifiers.contains(.option) else { return false }
        switch event.keyCode {
        case 125, 126:  // ↓ ↑
            selection.move(forward: event.keyCode == 125, extend: modifiers.contains(.shift), changed: changedLines)
            selectionChanged()
            if let cursor = selection.cursor, let row = source?.row(ofLine: cursor) { scrollToRow?(row, false) }
            return true
        case 49:  // Space
            selection.toggleCursor()
            selectionChanged()
            return true
        case 51:  // ⌫
            perform(.discard)
            return true
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": perform(.stage)
            case "u": perform(.unstage)
            default: return false
            }
            return true
        }
    }

    public var actionStates: [LineActionState] {
        LineActions.states(document: document, target: target, selectionCount: selection.count, isBusy: session.isBusy)
    }

    /// Runs `action` on the selection; discard and keep-only first show the confirmation sheet.
    public func perform(_ action: SelectionAction) {
        guard let state = actionStates.first(where: { $0.action == action }) else { return }
        guard state.isEnabled, let document else {
            if let reason = state.reason { banner = reason }
            return
        }
        if action == .discard || action == .keepOnly {
            pendingDiscard = LineDiscardRequest(document: document, selection: selection.lines, action: action)
            return
        }
        run(SelectionRequest(document: document, lines: selection.lines, action: action))
    }

    public func confirmDiscard() {
        guard let request = pendingDiscard else { return }
        pendingDiscard = nil
        run(SelectionRequest(document: request.document, lines: request.selection, action: request.action))
    }

    public func cancelDiscard() { pendingDiscard = nil }

    public func dismissBanner() { banner = nil }

    private func run(_ request: SelectionRequest) {
        banner = nil
        let session = self.session
        let recovery = self.recovery
        Task { [weak self] in
            do throws(GitCoreError) {
                _ = try await session.apply(request, recovery: recovery)
                self?.selection.clear()
                self?.selectionChanged()
            } catch .cancelled {
                return
            } catch {
                guard let self else { return }
                if case .staleSnapshot = error {
                    self.selection.clear()
                    self.selectionChanged()
                    self.banner =
                        "The file changed since you selected those lines. The diff was reloaded; nothing was changed."
                    self.reload()
                } else {
                    self.banner = error.summary
                }
            }
        }
    }

    // MARK: Navigation

    /// ⌥↓ / ⌥↑ from the first visible row.
    public func nextChange(from visibleRow: Int, forward: Bool) {
        guard !changeRows.isEmpty else { return }
        let target: Int?
        if forward {
            target = changeRows.first { $0 > (currentChange.map { changeRows[$0] } ?? visibleRow - 1) }
        } else {
            target = changeRows.last { $0 < (currentChange.map { changeRows[$0] } ?? visibleRow + 1) }
        }
        guard let row = target ?? (forward ? changeRows.first : changeRows.last),
            let index = changeRows.firstIndex(of: row)
        else { return }
        currentChange = index
        scrollToRow?(row, true)
    }

    /// ⌘L: the row showing new-side line `number` (old side for deleted-only files).
    public func row(forLine number: Int) -> Int? {
        guard let source else { return nil }
        var best: Int?
        var oldSide: Int?
        for row in 0..<source.rowCount {
            guard let line = source.line(row: row, column: layout == .split ? 1 : 0) ?? source.line(row: row, column: 0)
            else { continue }
            guard let value = source.document.newNumber(ofLine: line) else {
                if oldSide == nil, source.document.oldNumber(ofLine: line) == number { oldSide = row }
                continue
            }
            if value == number { return row }
            if value < number { best = row }
        }
        return best ?? oldSide
    }

    public func goToLine(_ number: Int) {
        if let row = row(forLine: number) { scrollToRow?(row, true) }
    }

    // MARK: Search

    private func runSearch() {
        guard let document, let source, !query.isEmpty, layout != .split else {
            matches = []
            currentMatch = nil
            source?.matches = [:]
            source?.currentMatch = nil
            onRedraw?()
            return
        }
        matches = document.search(query, caseSensitive: caseSensitive, layout: layout)
        var byRow: [Int: [NSRange]] = [:]
        for match in matches {
            byRow[match.row, default: []].append(NSRange(location: match.range.lowerBound, length: match.range.count))
        }
        source.matches = byRow
        currentMatch = matches.isEmpty ? nil : 0
        focusMatch()
    }

    /// ⌘G / ⇧⌘G.
    public func nextMatch(forward: Bool = true) {
        guard !matches.isEmpty else { return }
        let current = currentMatch ?? -1
        currentMatch = (current + (forward ? 1 : matches.count - 1)) % matches.count
        focusMatch()
    }

    private func focusMatch() {
        guard let source else { return }
        if let currentMatch, matches.indices.contains(currentMatch) {
            let match = matches[currentMatch]
            source.currentMatch = (match.row, NSRange(location: match.range.lowerBound, length: match.range.count))
            scrollToRow?(match.row, true)
        } else {
            source.currentMatch = nil
        }
        onRedraw?()
    }

    public var matchSummary: String {
        guard !query.isEmpty else { return "" }
        if layout == .split { return "Search in unified view" }
        guard let currentMatch else { return "No matches" }
        return "\(currentMatch + 1) of \(matches.count)"
    }

    /// Title for the header: path and what is compared.
    public var title: String {
        guard let target else { return "" }
        let path = document?.files.first?.path ?? target.path ?? "All files"
        return path
    }

    public var subtitle: String {
        switch target {
        case .unstaged: "Unstaged changes"
        case .staged: "Staged changes"
        case .commit(let oid, _): "Commit \(oid.hex(.sha1, length: 7))"
        case .commits(let a, let b, _, let mergeBase):
            "\(a.hex(.sha1, length: 7))\(mergeBase ? "..." : " → ")\(b.hex(.sha1, length: 7))"
        case .commitToWorktree(let oid, _): "\(oid.hex(.sha1, length: 7)) → working directory"
        case nil: ""
        }
    }
}

extension DiffDocument {
    /// The same expansion state as `other` (same storage shape).
    func withGaps(of other: DiffDocument) -> DiffDocument {
        guard other.storage.lineCount == storage.lineCount else { return self }
        return DiffDocument(storage: storage, target: target, options: options, token: token, gapsOverride: other.gaps)
    }
}

/// What a line discard / keep-only would remove and restore (design §3.2 preview).
public struct LineDiscardRequest: Identifiable {
    public let id = UUID()
    public let document: DiffDocument
    public let selection: Set<Int>
    public let action: SelectionAction

    /// Lines the working tree loses and lines that come back, in file order.
    public var effect: (lost: [Int], restored: [Int]) {
        let changed = (0..<document.storage.lineCount).filter { document.kind(ofLine: $0) != .context }
        let affected =
            action == .keepOnly ? changed.filter { !selection.contains($0) } : changed.filter { selection.contains($0) }
        return (
            affected.filter { document.kind(ofLine: $0) == .added },
            affected.filter { document.kind(ofLine: $0) == .deleted }
        )
    }

    public var path: String { document.files.first?.path ?? "" }
}
