import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// P6.10: VoiceOver semantics of the diff and the graph (labels, headings, rotors) and line staging through
/// accessibility actions alone, against real repositories.
@MainActor @Suite(.serialized) struct AccessibilityTests {
    static func loadedDiff(_ repo: TestRepo) async throws -> (DiffViewController, DiffViewModel, RepositorySession) {
        _ = NSApplication.shared
        let session = RepositorySession(path: repo.path, engine: repo.sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session)
        model.layout = .unified
        let controller = DiffViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentViewController = controller
        model.open(.unstaged(path: "f.txt"))
        #expect(await ClosedTabDeallocatesTests.waitUntil { model.state == .loaded && model.source != nil })
        window.layoutIfNeeded()
        return (controller, model, session)
    }

    static func codeView(_ controller: DiffViewController) throws -> CodeLinesView {
        func find(_ view: NSView) -> CodeLinesView? {
            if let code = view as? CodeLinesView { return code }
            return view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(controller.view))
    }

    @Test func diffLinesHaveLabelsHeadingsAndRotors() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let before = (1...40).map { "line \($0)\n" }.joined()
        try repo.write("f.txt", before)
        try await repo.commit("One")
        try repo.write(
            "f.txt",
            before.replacingOccurrences(of: "line 5\n", with: "five\n")
                .replacingOccurrences(of: "line 30\n", with: "thirty\n"))
        let (controller, model, session) = try await Self.loadedDiff(repo)
        defer { session.close() }
        let view = try Self.codeView(controller)
        let source = try #require(model.source)
        let hunk = try #require((0..<source.rowCount).first { source.cell(row: $0, column: 0).kind == .hunk })
        let added = try #require((0..<source.rowCount).first { source.cell(row: $0, column: 0).kind == .added })
        #expect(view.accessibilityElement(forRow: hunk).accessibilityRole()?.rawValue == "AXHeading")
        let label = view.accessibilityElement(forRow: added).accessibilityLabel() ?? ""
        #expect(label.hasPrefix("Added line 5: five"))
        // Rotors: two change blocks, two hunks (30 is beyond the first hunk's context).
        #expect(view.accessibilityCustomRotors().map(\.label) == ["Changes", "Hunks"])
        let firstChange = try #require(view.rotorTarget("Changes", from: nil, forward: true))
        let secondChange = try #require(view.rotorTarget("Changes", from: firstChange, forward: true))
        #expect(secondChange > firstChange)
        #expect(view.rotorTarget("Hunks", from: nil, forward: true) == hunk)
        #expect(view.rotorTarget("Changes", from: secondChange + 2, forward: false) == secondChange)
    }

    /// VoiceOverStageLine: select a line and stage it through the element's custom actions only.
    @Test func stageLineThroughAccessibilityActions() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "a\nb\nc\nd\n")
        try await repo.commit("One")
        try repo.write("f.txt", "a\nB\nc\nD\n")
        let (controller, model, session) = try await Self.loadedDiff(repo)
        defer { session.close() }
        let view = try Self.codeView(controller)
        let source = try #require(model.source)
        let addedB = try #require(
            (0..<source.rowCount).first {
                source.cell(row: $0, column: 0).kind == .added && source.cell(row: $0, column: 0).text == "B"
            })
        func action(_ name: String, _ row: Int) throws -> NSAccessibilityCustomAction {
            let actions = view.accessibilityElement(forRow: row).accessibilityCustomActions() ?? []
            return try #require(actions.first { $0.name == name }, "\(actions.map(\.name))")
        }
        _ = try action("Select line", addedB).handler?()
        let deletedB = try #require(
            (0..<source.rowCount).first {
                source.cell(row: $0, column: 0).kind == .deleted && source.cell(row: $0, column: 0).text == "b"
            })
        _ = try action("Extend selection to this line", deletedB).handler?()
        _ = try action("Stage selected lines", addedB).handler?()
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                (try? String(contentsOfFile: repo.path + "/.git/index", encoding: .isoLatin1)) != nil
                    && model.state == .loaded
            })
        // Only b→B is staged; d→D stays unstaged.
        var staged = ""
        for _ in 0..<100 {
            staged = try await repo.git("diff", "--cached", "--", "f.txt")
            if staged.contains("+B") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(staged.contains("-b\n+B"))
        #expect(!staged.contains("+D"))
        #expect(try await repo.git("diff", "--", "f.txt").contains("+D"))
    }

    @Test func graphRowsSpeakCommitAndRotorsFindRefsAndMerges() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("graph-a11y")
        try repo.write("a.txt", "1\n")
        try await repo.commit("Base")
        try await repo.git("checkout", "-q", "-b", "feature")
        try repo.write("b.txt", "2\n")
        try await repo.commit("Feature work")
        try await repo.git("checkout", "-q", "main")
        try repo.write("c.txt", "3\n")
        try await repo.commit("Main work")
        try await repo.git("merge", "-q", "--no-ff", "feature", "-m", "Merge feature")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        let graph = try #require(await waitForGraph(controller))
        let head = try #require(graph.rotorRow(.head, from: nil, forward: true))
        let label = graph.tableView.rowView(atRow: head, makeIfNecessary: true)?.accessibilityLabel() ?? ""
        #expect(label.contains("Merge feature"))
        #expect(label.contains("merge of 2 parents"))
        #expect(label.contains("main"))
        let merge = try #require(graph.rotorRow(.merges, from: nil, forward: true))
        #expect(merge == head)
        #expect(graph.rotorRow(.merges, from: merge, forward: true) == nil)
        let refs = try #require(graph.rotorRow(.refs, from: head, forward: true))
        let refLabel = graph.tableView.rowView(atRow: refs, makeIfNecessary: true)?.accessibilityLabel() ?? ""
        #expect(refLabel.contains("Feature work") && refLabel.contains("feature"))
        #expect((graph.tableView as? GraphTableView)?.accessibilityCustomRotors().count == 3)
        controller.close()
    }

    func waitForGraph(_ controller: MainWindowController) async -> GraphViewController? {
        _ = await ClosedTabDeallocatesTests.waitUntil { controller.activeGraph?.loadedCount ?? 0 >= 4 }
        return controller.activeGraph
    }
}
