import AppKit
import Testing

@testable import Features

/// Soft wrap in `CodeLinesView` (0.0.3): row heights follow the number of visual lines, and points map back
/// to the right row.
@MainActor @Suite struct DiffWrapTests {
    final class Source: CodeLinesDataSource {
        var lines: [String]
        var columnCount = 1
        init(_ lines: [String]) { self.lines = lines }
        var rowCount: Int { lines.count }
        var maxColumnCharacters: Int { lines.map { $0.utf16.count }.max() ?? 0 }
        var maxLineNumber: Int { lines.count }
        func cell(row: Int, column: Int) -> CodeCell {
            if lines[row].hasPrefix("@@") { return CodeCell(kind: .hunk, text: lines[row]) }
            return CodeCell(kind: .context, oldNumber: row + 1, newNumber: row + 1, text: lines[row])
        }
        func isSelected(row: Int, column: Int) -> Bool { false }
        func highlights(row: Int, column: Int) -> (ranges: [NSRange], current: NSRange?) {
            row == 1 ? ([NSRange(location: 0, length: lines[1].utf16.count)], nil) : ([], nil)
        }
    }

    private func view(_ source: Source, wraps: Bool) -> CodeLinesView {
        let view = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.wrapsLines = wraps
        view.dataSource = source
        return view
    }

    @Test func lineCountRoundsUp() {
        #expect(CodeLinesView.lineCount(length: 0, capacity: 40) == 1)
        #expect(CodeLinesView.lineCount(length: 40, capacity: 40) == 1)
        #expect(CodeLinesView.lineCount(length: 41, capacity: 40) == 2)
        #expect(CodeLinesView.lineCount(length: 120, capacity: 40) == 3)
    }

    @Test func displayLengthMatchesDisplayText() {
        let view = CodeLinesView(frame: .zero)
        for text in ["", "abc", "a\tb", "\t\tx", "é😀\tz", "a b\t"] {
            #expect(view.displayLength(text) == (view.displayText(text) as NSString).length)
        }
    }

    @Test func rowsAreUniformWithoutWrapping() {
        let source = Source(["short", String(repeating: "x", count: 500), "end"])
        let view = view(source, wraps: false)
        #expect(view.frame.height == 3 * view.rowHeight)
        #expect(view.rowRect(1) == NSRect(x: 0, y: view.rowHeight, width: view.bounds.width, height: view.rowHeight))
        #expect(view.frame.width > 400)  // scrolls sideways instead
    }

    @Test func wrappedRowsGrowAndPointsMapBack() throws {
        let source = Source(["short", String(repeating: "x", count: 500), "@@ -1 +1 @@", "end"])
        let view = view(source, wraps: true)
        let capacity = view.wrapCapacity
        #expect(capacity >= 20 && capacity < 500)
        let lines = CodeLinesView.lineCount(length: 500, capacity: capacity)
        #expect(lines > 1)
        #expect(view.frame.width == 400)  // no horizontal scrolling
        #expect(view.rowRect(0).height == view.rowHeight)
        #expect(view.rowRect(1).minY == view.rowHeight)
        #expect(view.rowRect(1).height == CGFloat(lines) * view.rowHeight)
        #expect(view.rowRect(2).minY == CGFloat(lines + 1) * view.rowHeight)
        #expect(view.rowRect(2).height == view.rowHeight)  // full-width rows never wrap
        for row in 0..<source.rowCount {
            let rect = view.rowRect(row)
            #expect(view.row(at: NSPoint(x: 10, y: rect.minY + 0.5)) == row)
            #expect(view.row(at: NSPoint(x: 10, y: rect.maxY - 0.5)) == row)
        }
        #expect(view.row(at: NSPoint(x: 10, y: view.rowRect(3).maxY + 1)) == nil)
        #expect(view.rows(in: NSRect(x: 0, y: view.rowHeight * 1.5, width: 10, height: view.rowHeight)) == 1..<2)
        #expect(view.rows(in: view.bounds) == 0..<4)
        // Drawing a wrapped row with a search highlight across every visual line does not trap.
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    @Test func shortLinesNeedNoOffsets() {
        let source = Source(["a", "b", "c"])
        let view = view(source, wraps: true)
        #expect(view.rowRect(2).minY == 2 * view.rowHeight)
        #expect(view.row(at: NSPoint(x: 0, y: view.rowHeight * 2.5)) == 2)
    }

    @Test func sideBySideWrapsEachHalf() {
        let source = Source([String(repeating: "y", count: 200), "z"])
        let unified = view(source, wraps: true).wrapCapacity
        source.columnCount = 2
        let split = view(source, wraps: true)
        #expect(split.wrapCapacity < unified)
        #expect(
            split.rowRect(0).height
                == CGFloat(CodeLinesView.lineCount(length: 200, capacity: split.wrapCapacity)) * split.rowHeight)
    }

    @Test func narrowerPaneWrapsMore() {
        let source = Source([String(repeating: "w", count: 300)])
        let view = view(source, wraps: true)
        let wide = view.rowRect(0).height
        view.setFrameSize(NSSize(width: 250, height: 300))
        view.reloadData()
        #expect(view.rowRect(0).height > wide)
    }
}
