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

    /// Tells the view to reload (new source) or redraw (highlights).
    @ObservationIgnored public var onSourceChange: (() -> Void)?
    @ObservationIgnored public var onRedraw: (() -> Void)?
    @ObservationIgnored public var scrollToRow: ((Int, Bool) -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    public init(session: RepositorySession) {
        self.session = session
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

    private func load(_ target: DiffTarget, keepPosition: Bool) {
        self.target = target
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
        #endif
    }

    @ObservationIgnored private var debugFocused = false

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
