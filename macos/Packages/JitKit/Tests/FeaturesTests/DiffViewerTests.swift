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
        let model = DiffViewModel(session: session, defaults: .scratch())
        model.layout = .unified
        model.open(.unstaged(path: "f.txt"))
        let clock = ContinuousClock()
        let deadline = clock.now + TimingBudget.latency(.seconds(5))
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
        let model = DiffViewModel(session: session, defaults: .scratch())
        model.layout = .fullFile
        var scrolled: [Int] = []
        model.scrollToRow = { row, _ in scrolled.append(row) }
        model.open(.unstaged(path: "f.txt"))
        let clock = ContinuousClock()
        let deadline = clock.now + TimingBudget.latency(.seconds(5))
        while model.state != .loaded, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // `#require`, not `#expect`: the indexing below would crash the whole test process if loading failed.
        try #require(model.changeRows.count == 2)
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

@Suite @MainActor struct DiffReleaseTests {
    @Test func inactiveTabReleasesDiffBuffersAndReloadsOnReturn() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "a\n")
        try await repo.commit("One")
        try repo.write("f.txt", "a\nb\n")
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session, defaults: .scratch())
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + TimingBudget.latency(.seconds(5))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await wait { session.lifecycle == .active }
        model.open(.unstaged(path: "f.txt"))
        try await wait { model.state == .loaded }
        #expect(model.document != nil && model.source != nil)
        session.deactivate()
        try await wait { model.isReleased }
        #expect(model.document == nil && model.source == nil && model.target != nil)
        session.activate()
        try await wait { model.state == .loaded }
        #expect(model.document != nil && !model.isReleased)
        session.close()
    }

    /// Switching files keeps the previous rows on screen until the next file is ready (0.0.5: the blank frame
    /// between them read as a flicker), and the new file replaces them in one step.
    @Test func switchingFilesKeepsRowsUntilTheNextFileLoads() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "a\n")
        try repo.write("g.txt", "x\n")
        try await repo.commit("One")
        try repo.write("f.txt", "a\nb\n")
        try repo.write("g.txt", "x\ny\n")
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session, defaults: .scratch())
        var cleared = 0
        model.onSourceChange = { if model.source == nil { cleared += 1 } }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + TimingBudget.latency(.seconds(5))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        model.open(.unstaged(path: "f.txt"))
        try await wait { model.state == .loaded }
        #expect(model.title == "f.txt")
        cleared = 0
        model.open(.unstaged(path: "g.txt"))
        // Synchronously after the switch: still the old rows, already the new title.
        #expect(model.state == .loading && model.source != nil && !model.showsCurrentTarget)
        #expect(model.title == "g.txt")
        try await wait { model.state == .loaded }
        #expect(model.showsCurrentTarget && model.document?.files.first?.path == "g.txt")
        // A fast load never shows the empty state (a slow one may, after the spinner delay).
        if !model.showsSpinner { #expect(cleared == 0) }
        session.close()
    }

    /// View options are app-wide: a new model starts with them, an existing one (another tab) takes them on
    /// the next file it opens.
    @Test func viewOptionsAreRememberedForEveryTab() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "a\n")
        try await repo.commit("One")
        try repo.write("f.txt", "a\nb\n")
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        let defaults = UserDefaults.scratch()
        let other = DiffViewModel(session: session, defaults: defaults)
        let model = DiffViewModel(session: session, defaults: defaults)
        #expect(!model.wrapsLines && model.layout == .unified && model.showsWordDiff && model.highlightsSyntax)
        model.layout = .split
        model.wrapsLines = true
        model.showsWhitespace = true
        model.ignoresWhitespace = true
        model.showsWordDiff = false
        model.highlightsSyntax = false
        let fresh = DiffViewModel(session: session, defaults: defaults)
        #expect(fresh.layout == .split && fresh.wrapsLines && fresh.showsWhitespace && fresh.ignoresWhitespace)
        #expect(!fresh.showsWordDiff && !fresh.highlightsSyntax)
        #expect(!other.wrapsLines)
        other.open(.unstaged(path: "f.txt"))
        #expect(other.layout == .split && other.wrapsLines && other.showsWhitespace && other.ignoresWhitespace)
        #expect(!other.showsWordDiff && !other.highlightsSyntax)
        let deadline = ContinuousClock.now + TimingBudget.latency(.seconds(5))
        while other.state != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(other.document?.options.ignoreWhitespace == true)
        session.close()
    }
}

extension UserDefaults {
    /// A throwaway suite, so parallel tests never share remembered diff options.
    static func scratch() -> UserDefaults {
        UserDefaults(suiteName: "jit.tests.\(UUID().uuidString)") ?? .standard
    }
}

@Suite @MainActor struct DiffAccessibilityTests {
    @Test func visibleDiffRowsExposeSpokenLabels() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "keep\nold\n")
        try await repo.commit("One")
        try repo.write("f.txt", "keep\nnew\n")
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session, defaults: .scratch())
        model.layout = .unified
        let controller = DiffViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = controller.view
        model.open(.unstaged(path: "f.txt"))
        let deadline = ContinuousClock.now + TimingBudget.latency(.seconds(5))
        while model.state != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        controller.view.layoutSubtreeIfNeeded()
        let labels = (controller.codeView.accessibilityChildren() ?? []).compactMap {
            ($0 as? NSAccessibilityElement)?.accessibilityLabel()
        }
        #expect(labels.contains("Removed line 2: old"))
        #expect(labels.contains("Added line 2: new"))
        #expect(labels.contains("Line 1: keep"))
        #expect(labels.contains { $0.hasPrefix("Hunk @@") })
        #expect(controller.codeView.accessibilityRole() == .list)
        session.close()
    }
}
