import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// Diff viewer rows and navigation (P3.6) on real diffs.
@Suite @MainActor struct DiffViewerTests {
    func document(_ before: String, _ after: String, context: Int = 3) async throws -> (DiffDocument, TestRepo) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", before)
        try await repo.commit("One")
        try repo.write("f.txt", after)
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return (try await handle.openDiff(.unstaged(path: "f.txt"), options: DiffOptions(contextLines: context)), repo)
    }

    @Test func splitRowsPairAndFill() async throws {
        let (doc, _) = try await document("a\nold1\nold2\nb\n", "a\nnew1\nb\nadded\n")
        let source = DiffRowsSource(document: doc, layout: .split)
        var rows: [(CodeCell.Kind, CodeCell.Kind)] = []
        for row in 0..<source.rowCount {
            let left = source.cell(row: row, column: 0)
            if left.isFullWidth { continue }
            rows.append((left.kind, source.cell(row: row, column: 1).kind))
        }
        let expected: [(CodeCell.Kind, CodeCell.Kind)] = [
            (.context, .context), (.deleted, .added), (.deleted, .filler), (.context, .context), (.filler, .added),
        ]
        #expect(rows.count == expected.count)
        for (got, want) in zip(rows, expected) { #expect(got == want) }
        // Numbers: old on the left, new on the right.
        let pair = try #require((0..<source.rowCount).first { source.cell(row: $0, column: 0).kind == .deleted })
        #expect(source.cell(row: pair, column: 0).oldNumber == 2 && source.cell(row: pair, column: 0).newNumber == nil)
        #expect(source.cell(row: pair, column: 1).newNumber == 2 && source.cell(row: pair, column: 1).oldNumber == nil)
    }

    @Test func collapsedContextExpandsOnClick() async throws {
        let before = (1...100).map { "line \($0)\n" }.joined()
        let (_, repo) = try await document(before, before.replacingOccurrences(of: "line 50\n", with: "fifty\n"))
        let session = RepositorySession(path: repo.path, engine: repo.sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session)
        model.layout = .unified
        model.open(.unstaged(path: "f.txt"))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.state != .loaded, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let source = try #require(model.source)
        let gapRows = (0..<source.rowCount).filter { source.cell(row: $0, column: 0).kind == .gap }
        #expect(gapRows.count == 2)
        let first = try #require(gapRows.first)
        #expect(source.cell(row: first, column: 0).text.contains("46 unchanged lines"))
        let before1 = source.rowCount
        model.expandGap(atRow: first, lines: 10)
        #expect(try #require(model.source).rowCount == before1 + 20)
        // A gap smaller than twice the step disappears entirely.
        let next = try #require(
            (0..<model.source!.rowCount).first { model.source!.cell(row: $0, column: 0).kind == .gap })
        model.expandGap(atRow: next, lines: 100)
        #expect(model.document?.gaps.count == 1)
        session.close()
    }

    @Test func navigateChangesAndSearch() async throws {
        let before = (1...60).map { "line \($0)\n" }.joined()
        var after = before.replacingOccurrences(of: "line 10\n", with: "ten\n")
        after = after.replacingOccurrences(of: "line 40\n", with: "forty\n")
        let (_, repo) = try await document(before, after)
        let session = RepositorySession(path: repo.path, engine: repo.sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session)
        model.layout = .fullFile
        var scrolled: [Int] = []
        model.scrollToRow = { row, _ in scrolled.append(row) }
        model.open(.unstaged(path: "f.txt"))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.state != .loaded, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.changeRows.count == 2)
        model.nextChange(from: 0, forward: true)
        model.nextChange(from: 0, forward: true)
        model.nextChange(from: 0, forward: true)  // wraps
        #expect(scrolled == [model.changeRows[0], model.changeRows[1], model.changeRows[0]])
        model.nextChange(from: 0, forward: false)
        #expect(scrolled.last == model.changeRows[1])

        model.query = "LINE 4"
        #expect(model.matches.count == 11)  // line 4, 41–49 (40 is "forty"), line 4 itself counted once
        #expect(model.matchSummary == "1 of 11")
        model.nextMatch(forward: false)
        #expect(model.matchSummary == "11 of 11")
        model.caseSensitive = true
        #expect(model.matches.isEmpty && model.matchSummary == "No matches")

        model.goToLine(40)
        let row = try #require(scrolled.last)
        let line = try #require(model.source?.line(row: row))
        #expect(model.document?.newNumber(ofLine: line) == 40)
        session.close()
    }

    @Test func renderedRowsDrawWithoutTouchingHiddenRows() async throws {
        let before = (1...5000).map { "line \($0)\n" }.joined()
        let (doc, _) = try await document(before, before.replacingOccurrences(of: "line 2500\n", with: "x\n"))
        let source = DiffRowsSource(document: doc.expandingAll(), layout: .unified)
        let view = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = view
        view.dataSource = source
        #expect(view.frame.height == CGFloat(source.rowCount) * view.rowHeight)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: scroll.documentVisibleRect))
        view.cacheDisplay(in: scroll.documentVisibleRect, to: bitmap)
        #expect(view.row(at: NSPoint(x: 10, y: view.rowHeight * 2.5)) == 2)
        #expect(view.displayText("a\tb") == "a   b")
        view.showsWhitespace = true
        #expect(view.displayText("a b\t") == "a·b→")  // tab at column 3 → one cell
        #expect(view.displayText("\tx") == "→   x")
    }
}
