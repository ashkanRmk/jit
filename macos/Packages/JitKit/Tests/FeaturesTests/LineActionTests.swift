import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// Line selection, action availability and Scenario C (§24) through the diff viewer model (P3.8).
@Suite @MainActor struct LineActionTests {
    // MARK: Selection model

    @Test func lineSelectionModel() {
        let changed = [2, 3, 4, 8, 9]
        var selection = LineSelection()
        selection.click(3, changed: changed, modifiers: [])
        #expect(selection.lines == [3])
        selection.click(8, changed: changed, modifiers: .shift)
        #expect(selection.lines == [3, 4, 8])  // range over changed lines only
        selection.click(4, changed: changed, modifiers: .command)
        #expect(selection.lines == [3, 8])
        selection.click(5, changed: changed, modifiers: [])  // a context line clears
        #expect(selection.isEmpty)
        selection.click(2, changed: changed, modifiers: [])
        selection.drag(to: 6, changed: changed)  // context line: nearest changed line (4 or 8)
        #expect(selection.lines == [2, 3, 4] || selection.lines == [2, 3, 4, 8])
        selection.toggleHunk([8, 9])
        #expect(selection.lines == [8, 9])
        selection.toggleHunk([8, 9])
        #expect(selection.isEmpty)
        selection.clear()
        selection.move(forward: true, extend: false, changed: changed)
        #expect(selection.lines == [2])
        selection.move(forward: true, extend: true, changed: changed)
        #expect(selection.lines == [2, 3])
        selection.move(forward: false, extend: false, changed: changed)
        #expect(selection.lines == [2])
        selection.toggleCursor()
        selection.restrict(to: [2])
        #expect(selection.lines.isSubset(of: [2]))
    }

    // MARK: Availability

    func world(_ files: [String: String]) async throws -> (GitSandbox, TestRepo, RepositorySession) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        session.activate()
        return (sandbox, repo, session)
    }

    func loaded(_ session: RepositorySession, _ target: DiffTarget, options: DiffOptions = DiffOptions()) async throws
        -> DiffDocument
    {
        try await session.openDiff(target, options: options)
    }

    @Test func actionAvailability() async throws {
        let (_, repo, session) = try await world(["a.txt": "a\n", "bin": "\u{0}x"])
        try repo.write("a.txt", "a\nb\n")
        try Data([0, 1]).write(to: URL(fileURLWithPath: repo.path + "/bin"))
        let text = try await loaded(session, .unstaged(path: "a.txt"))

        let none = LineActions.states(
            document: text, target: .unstaged(path: "a.txt"), selectionCount: 0, isBusy: false)
        #expect(none.map(\.action) == [.stage, .discard, .keepOnly])
        #expect(none.allSatisfy { !$0.isEnabled && $0.reason == UnsupportedReason.noSelection.explanation })
        let ready = LineActions.states(
            document: text, target: .unstaged(path: "a.txt"), selectionCount: 3, isBusy: false)
        #expect(
            ready.map(\.title) == ["Stage 3 Lines", "Discard 3 Lines…", "Keep Only Selected…"]
                && ready.allSatisfy(\.isEnabled))
        #expect(ready.filter(\.isDestructive).map(\.action) == [.discard, .keepOnly])
        let busy = LineActions.states(document: text, target: .unstaged(path: "a.txt"), selectionCount: 1, isBusy: true)
        #expect(busy.allSatisfy { !$0.isEnabled } && busy.first?.title == "Stage Line")

        let binary = try await loaded(session, .unstaged(path: "bin"))
        #expect(
            LineActions.states(document: binary, target: .unstaged(path: "bin"), selectionCount: 1, isBusy: false)
                .allSatisfy { $0.reason == UnsupportedReason.binary.explanation })
        let hidden = try await loaded(session, .unstaged(path: "a.txt"), options: DiffOptions(ignoreWhitespace: true))
        #expect(
            LineActions.states(document: hidden, target: .unstaged(path: "a.txt"), selectionCount: 1, isBusy: false)
                .allSatisfy { $0.reason == UnsupportedReason.whitespaceIgnored.explanation })
        try await repo.git("add", "a.txt")
        let head = try #require(ObjectID(hex: try await repo.git("rev-parse", "HEAD")))
        let commit = try await loaded(session, .commit(head, path: "a.txt"))
        #expect(
            LineActions.states(document: commit, target: .commit(head, path: "a.txt"), selectionCount: 1, isBusy: false)
                .isEmpty)
        let staged = try await loaded(session, .staged(path: "a.txt"))
        #expect(
            LineActions.states(document: staged, target: .staged(path: "a.txt"), selectionCount: 1, isBusy: false).map(
                \.title) == ["Unstage Line"])
        for reason in UnsupportedReason.allCases { #expect(!reason.explanation.isEmpty) }
        session.close()
    }

    // MARK: Scenario C

    func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + TimingBudget.latency(timeout)
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func open(_ model: DiffViewModel, _ target: DiffTarget) async throws {
        model.close()
        model.open(target)
        #expect(try await waitUntil { model.state == .loaded && model.source != nil })
    }

    func row(_ model: DiffViewModel, text: String, kind: DiffLineKind) throws -> Int {
        let source = try #require(model.source)
        return try #require(
            (0..<source.rowCount).first { row in
                guard let line = source.line(row: row) else { return false }
                return source.document.text(ofLine: line) == text && source.document.kind(ofLine: line) == kind
            })
    }

    @Test func scenarioCPartialStaging() async throws {
        let original = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        let (sandbox, repo, session) = try await world(["f.txt": original, "other.txt": "keep me\n"])
        try repo.write("f.txt", "alpha\nBETA\ngamma\nDELTA\nepsilon\nzeta\n")
        try repo.write("other.txt", "keep me\nunrelated edit\n")
        _ = sandbox
        let model = DiffViewModel(session: session)
        model.layout = .unified
        model.recovery = RecoveryStore(
            location: StoreLocation(directory: URL(fileURLWithPath: repo.sandbox.root + "/AppSupport")))

        // Diff shows the changes; stage one selected line.
        try await open(model, .unstaged(path: "f.txt"))
        #expect(model.changeRows.count == 3)
        model.click(row: try row(model, text: "zeta", kind: .added), column: 0, modifiers: [])
        model.perform(.stage)
        #expect(try await waitUntil { (try? self.index(repo)) == "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n" })
        // Other lines remain unstaged.
        #expect(
            try String(contentsOfFile: repo.path + "/f.txt", encoding: .utf8)
                == "alpha\nBETA\ngamma\nDELTA\nepsilon\nzeta\n")

        // Unstage the selected line.
        try await open(model, .staged(path: "f.txt"))
        model.click(row: try row(model, text: "zeta", kind: .added), column: 0, modifiers: [])
        model.perform(.unstage)
        #expect(try await waitUntil { (try? self.index(repo)) == original })

        // Discard another selected line (confirmation first).
        try await open(model, .unstaged(path: "f.txt"))
        model.click(row: try row(model, text: "DELTA", kind: .added), column: 0, modifiers: [])
        model.click(row: try row(model, text: "delta", kind: .deleted), column: 0, modifiers: .command)
        model.perform(.discard)
        let request = try #require(model.pendingDiscard)
        #expect(request.effect.lost.count == 1 && request.effect.restored.count == 1)
        #expect(try String(contentsOfFile: repo.path + "/f.txt", encoding: .utf8).contains("DELTA"))  // not yet
        model.confirmDiscard()
        #expect(
            try await waitUntil {
                (try? String(contentsOfFile: repo.path + "/f.txt", encoding: .utf8))
                    == "alpha\nBETA\ngamma\ndelta\nepsilon\nzeta\n"
            })
        // Unrelated changes are preserved.
        #expect(try String(contentsOfFile: repo.path + "/other.txt", encoding: .utf8) == "keep me\nunrelated edit\n")
        #expect(try index(repo) == original)
        #expect(model.recovery.entries().count == 1)

        // Scenario C ends with a commit authored by the active profile (P3.10 exit criterion).
        try await open(model, .unstaged(path: "f.txt"))
        model.click(row: try row(model, text: "BETA", kind: .added), column: 0, modifiers: [])
        model.click(row: try row(model, text: "beta", kind: .deleted), column: 0, modifiers: .command)
        model.perform(.stage)
        #expect(try await waitUntil { (try? self.index(repo)) == "alpha\nBETA\ngamma\ndelta\nepsilon\n" })
        let location = StoreLocation(directory: URL(fileURLWithPath: repo.sandbox.root + "/AppSupport"))
        let profiles = ProfileStore(location: location)
        profiles.create(
            GitProfile(
                displayName: "Work", colorIndex: 0, author: GitIdentity(name: "Ana Ruiz", email: "ana@work.example")),
            activate: true)
        let composer = CommitComposerModel(
            session: session, profiles: profiles, drafts: CommitDrafts(location: location))
        var committed: String?
        composer.onCommitted = { committed = $0 }
        composer.summary = "Capitalise beta"
        session.reload()
        #expect(try await waitUntil { composer.disabledReason == nil })
        composer.commit()
        #expect(try await waitUntil { committed != nil })
        #expect(
            try await repo.git("log", "-1", "--format=%an <%ae>|%s") == "Ana Ruiz <ana@work.example>|Capitalise beta")
        #expect(try await repo.git("show", "--format=", "--stat", "HEAD").contains("f.txt"))
        // Unstaged work survives the commit.
        #expect(
            try String(contentsOfFile: repo.path + "/f.txt", encoding: .utf8)
                == "alpha\nBETA\ngamma\ndelta\nepsilon\nzeta\n")
        #expect(try String(contentsOfFile: repo.path + "/other.txt", encoding: .utf8) == "keep me\nunrelated edit\n")
        session.close()
    }

    nonisolated func index(_ repo: TestRepo) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path, "show", ":f.txt"]
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func chromeDoesNotSwallowBodyClicks() async throws {
        let (_, repo, session) = try await world(["f.txt": "a\n"])
        try repo.write("f.txt", "a\nb\n")
        let model = DiffViewModel(session: session)
        let controller = DiffViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = controller.view
        try await open(model, .unstaged(path: "f.txt"))
        controller.view.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 300, y: 150)  // in the body, below the chrome bar
        let hit = controller.view.hitTest(point)
        #expect(
            hit === controller.codeView || hit?.isDescendant(of: controller.codeView) == true,
            "hit \(String(describing: hit))")
        session.close()
    }
}
