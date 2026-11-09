import AppKit
import GitCore

/// Serves one `DiffDocument` layout to `CodeLinesView`. Strings are made per visible row only.
@MainActor public final class DiffRowsSource: CodeLinesDataSource {
    public let document: DiffDocument
    public let layout: DiffLayout
    /// Selected changed lines (document line indices).
    public var selectedLines: Set<Int> = []
    /// Search matches per row and the focused one.
    public var matches: [Int: [NSRange]] = [:]
    public var currentMatch: (row: Int, range: NSRange)?
    /// Word-diff and syntax spans per document line (filled lazily by P3.7 providers).
    public var emphasisProvider: ((Int) -> [NSRange])?
    public var syntaxProvider: ((Int) -> [(NSRange, NSColor)])?

    public let maxColumnCharacters: Int
    public let maxLineNumber: Int

    public init(document: DiffDocument, layout: DiffLayout) {
        self.document = document
        self.layout = layout
        var longest = 0
        for line in 0..<document.storage.lineCount { longest = max(longest, document.bytes(ofLine: line).count) }
        maxColumnCharacters = longest + 30
        var highest = 0
        for hunk in document.hunks {
            highest = max(highest, Int(hunk.oldStart + hunk.oldCount), Int(hunk.newStart + hunk.newCount))
        }
        maxLineNumber = highest
    }

    public var rowCount: Int { document.rowCount(layout) }
    public var columnCount: Int { layout == .split ? 2 : 1 }

    /// The document line shown in `row`/`column`, if it is a line row.
    public func line(row: Int, column: Int = 0) -> Int? {
        if layout == .split {
            guard case .lines(let left, let right) = document.splitRow(row) else { return nil }
            return column == 0 ? left : right
        }
        if case .line(let line) = document.row(layout, row) { return line }
        return nil
    }

    /// Rows showing `line` (one in unified/full; one in split).
    public func row(ofLine line: Int) -> Int? {
        for row in 0..<rowCount
        where self.line(row: row, column: 0) == line || (layout == .split && self.line(row: row, column: 1) == line) {
            return row
        }
        return nil
    }

    public func cell(row: Int, column: Int) -> CodeCell {
        if layout == .split {
            switch document.splitRow(row) {
            case .file(let index): return fileCell(index)
            case .hunk(let index): return hunkCell(index)
            case .gap(let index): return gapCell(index)
            case .lines(let left, let right):
                guard let line = column == 0 ? left : right else { return CodeCell(kind: .filler) }
                return lineCell(line, splitColumn: column)
            }
        }
        switch document.row(layout, row) {
        case .file(let index): return fileCell(index)
        case .hunk(let index): return hunkCell(index)
        case .gap(let index): return gapCell(index)
        case .line(let line): return lineCell(line, splitColumn: nil)
        }
    }

    private func lineCell(_ line: Int, splitColumn: Int?) -> CodeCell {
        let kind: CodeCell.Kind
        switch document.kind(ofLine: line) {
        case .context: kind = .context
        case .added: kind = .added
        case .deleted: kind = .deleted
        }
        var oldNumber = document.oldNumber(ofLine: line)
        var newNumber = document.newNumber(ofLine: line)
        if splitColumn == 0 { newNumber = nil }
        if splitColumn == 1 { oldNumber = nil }
        var note: String?
        if document.noNewline(line: line) { note = "No newline at end of file" }
        return CodeCell(
            kind: kind, oldNumber: oldNumber, newNumber: newNumber, text: document.text(ofLine: line), note: note)
    }

    private func hunkCell(_ index: Int) -> CodeCell {
        let hunk = document.hunks[index]
        let raw = document.storage.bytes[hunk.headerRangeForDisplay]
        var text = String(decoding: raw, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return CodeCell(kind: .hunk, text: text)
    }

    private func gapCell(_ index: Int) -> CodeCell {
        let count = document.gaps[index].count
        return CodeCell(kind: .gap, text: "⋯ \(count) unchanged \(count == 1 ? "line" : "lines") — click to show")
    }

    private func fileCell(_ index: Int) -> CodeCell {
        let file = document.files[index]
        var text = file.path
        if let old = file.oldPath, file.status == .renamed || file.status == .copied { text = "\(old) → \(file.path)" }
        return CodeCell(kind: .file, text: text)
    }

    public func isSelected(row: Int, column: Int) -> Bool {
        guard !selectedLines.isEmpty, let line = line(row: row, column: column) else { return false }
        return selectedLines.contains(line)
    }

    public func highlights(row: Int, column: Int) -> (ranges: [NSRange], current: NSRange?) {
        guard column == 0 || layout != .split else { return ([], nil) }
        let ranges = matches[row] ?? []
        return (ranges, currentMatch?.row == row ? currentMatch?.range : nil)
    }

    public func emphasis(row: Int, column: Int) -> [NSRange] {
        guard let emphasisProvider, let line = line(row: row, column: column) else { return [] }
        return emphasisProvider(line)
    }

    public func syntax(row: Int, column: Int) -> [(NSRange, NSColor)] {
        guard let syntaxProvider, let line = line(row: row, column: column) else { return [] }
        return syntaxProvider(line)
    }
}
