import AppKit
import DesignSystem
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct GraphWorkflowTests {
    actor Pause {
        var continuation: CheckedContinuation<Void, Never>?
        var released = false
        func hold() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    @Test func busyRepositoryLocksTabsAndThenUnlocks() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("First")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        let tab = try #require(model.activeTab)
        let session = try #require(tab.session)
        #expect(await ClosedTabDeallocatesTests.waitUntil { session.repository != nil })
        let other = model.newTab()
        model.select(tab.id)
        let pause = Pause()
        let running = Task {
            await session.operations.run("Held operation", summarize: { _ in OperationSummary("Done") }) {
                _ throws(GitCoreError) in await pause.hold()
            }
        }
        #expect(await ClosedTabDeallocatesTests.waitUntil { model.isBusy })
        let count = model.tabs.count
        model.select(other.id)
        model.selectNextTab()
        model.closeTab(tab.id)
        model.newTab()
        #expect(model.activeTabID == tab.id)
        #expect(model.tabs.count == count)
        await pause.release()
        _ = await running.value
        model.select(other.id)
        #expect(model.activeTabID == other.id)
    }

    @Test func firstOpenRevealsHeadEvenWhenAnotherBranchIsNewer() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("first.txt", "first\n")
        try await repo.commit("Checked-out commit")
        let head = try await repo.git("rev-parse", "HEAD")
        try await repo.git("switch", "-c", "newer")
        try await repo.commit("Newer on another branch")
        try await repo.git("switch", "main")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let window = MainWindowController(model: model)
        window.showWindow(nil)
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.selectedOID == head })
        let operations = try #require(window.activeWorkbench?.operations)
        let newer = try await repo.git("rev-parse", "newer")
        operations.switchTo(.branch("newer"))
        #expect(
            await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.selectedOID == newer && model.toast != nil }
        )
        #expect(model.toast?.failed == false)
        let session = try #require(model.activeTab?.session)
        try repo.write("new.txt", "New commit\n")
        try await repo.git("add", "new.txt")
        let identity = GitIdentity(name: "QA", email: "qa@example.com")
        let outcome = try await session.commit(
            CommitRequest(message: "Commit from Jit", identity: IdentitySnapshot(author: identity, committer: identity))
        )
        #expect(await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.selectedOID == outcome.commitID })
        window.close()
    }

    @Test func changedFileNavigationKeepsTheSelectedCommit() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try repo.write("b.txt", "b\n")
        try await repo.commit("Files")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let oid = try #require(ObjectID(hex: try await repo.git("rev-parse", "HEAD")))
        let inspector = InspectorModel()
        inspector.handle = handle
        inspector.show(selection: [oid], wip: false)
        #expect(await ClosedTabDeallocatesTests.waitUntil { inspector.files.count == 2 })
        inspector.openDiff(inspector.files[0])
        inspector.moveFile(from: "a.txt", forward: true)
        #expect(inspector.openedFilePath == "b.txt")
        #expect(inspector.mode == .commit(oid))
        inspector.moveFile(from: "b.txt", forward: true)
        #expect(inspector.openedFilePath == "b.txt")
        inspector.moveFile(from: "b.txt", forward: false)
        #expect(inspector.openedFilePath == "a.txt")
    }

    @Test func graphShowsSavedStashesAndCountsEachChangedFileOnce() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "base\n")
        try await repo.commit("Initial commit")
        for message in ["Older stash", "Newest stash"] {
            try repo.write("a.txt", message + "\n")
            try await repo.git("stash", "push", "-m", message)
        }
        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "unstaged too\n")
        try repo.write("b.txt", "untracked\n")

        let model = ClosedTabDeallocatesTests.makeModel(sandbox, watchesFileSystem: true)
        var columns = GraphColumnLayout()
        columns.widths[.graph] = 43
        model.preferences.graphColumns = try JSONEncoder().encode(columns.json)
        model.restore(nil)
        let window = MainWindowController(model: model)
        window.showWindow(nil)
        defer { window.close() }
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                window.activeGraph?.loadedCount == 3 && window.activeGraph?.displayRow(0) == .wip
            })
        let graph = try #require(window.activeGraph)
        let session = try #require(graph.tab.session)
        let older = try #require(session.stashes?.last)
        let oid = try #require(ObjectID(hex: older.oid))
        #expect(graph.revealStash(oid))
        #expect(graph.selectedOID == older.oid)
        let graphColumn = try #require(graph.tableView.tableColumn(withIdentifier: GraphViewController.columnGraph))
        let history = try #require(graph.history?.snapshot)
        let stashIndex = try #require(history.row(for: oid))
        let metrics = GraphMetrics.forDensity(model.preferences.graphDensity == .compact ? .compact : .comfortable)
        #expect(graphColumn.width >= metrics.laneX(Int(history.row(stashIndex).nodeLane)) + metrics.nodeDiameter / 2)
        let subjectColumn = try #require(graph.tableView.tableColumn(withIdentifier: GraphViewController.columnSubject))
        let cell = try #require(graph.tableView(graph.tableView, viewFor: subjectColumn, row: 0) as? SubjectCellView)
        #expect(cell.content.subject == "// WIP")
        guard case .wip(let count) = cell.content.style else {
            Issue.record("Expected the working-tree row to use the WIP style")
            return
        }
        #expect(count == 2)

        // The newest stash still has the same OID after dropping the older entry outside Jit.
        #expect(await ClosedTabDeallocatesTests.waitUntil { session.isWatching })
        try await repo.git("stash", "drop", "stash@{1}")
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                graph.loadedCount == 2 && graph.history?.snapshot.row(for: oid) == nil
            })
    }

    @Test func hoverNamesDeletedBranchesOnTaggedCommitsAndSearchResults() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        var topology = Topology()
        topology.commit("Base")
        topology.branch("topic")
        topology.commit("Topic one")
        topology.tag("v-topic")
        topology.commit("Topic two")
        topology.checkout("main")
        topology.merge("topic", label: "Merge branch 'topic'")
        topology.tag("v-release")
        try await topology.write(to: repo)
        try await repo.git("branch", "-D", "topic")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let window = MainWindowController(model: model)
        window.showWindow(nil)
        defer { window.close() }
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.loadedCount == 4 })
        let graph = try #require(window.activeGraph)
        let refsColumn = graph.tableView.column(withIdentifier: GraphViewController.columnRefs)
        let headRow = try #require(graph.tableRow(forCommit: 0))
        let headCell = try #require(
            graph.tableView.view(atColumn: refsColumn, row: headRow, makeIfNecessary: true) as? RefsCellView)
        let existingLabels = headCell.content.labels
        #expect(existingLabels.map(\.text) == ["main", "v-release"])
        graph.mouseMoved(toRow: headRow)
        #expect(headCell.content.labels == existingLabels)
        #expect(headCell.content.ghost == nil)
        graph.mouseMoved(toRow: nil)
        for filtered in [false, true] {
            if filtered {
                graph.viewModel.searchText = "Topic"
                graph.searchTextChanged()
                graph.setFilterMode(.onlyMatches)
            }
            let snapshot = try #require(graph.history?.snapshot)
            var topics = 0
            for row in 0..<graph.tableView.numberOfRows {
                guard case .commit(let index) = graph.displayRow(row),
                    snapshot.row(index).subject.hasPrefix("Topic")
                else { continue }
                topics += 1
                let cell = try #require(
                    graph.tableView.view(atColumn: refsColumn, row: row, makeIfNecessary: true) as? RefsCellView)
                let frame = graph.tableView.frameOfCell(atColumn: refsColumn, row: row)
                graph.mouseMoved(toRow: row, at: NSPoint(x: frame.midX, y: frame.midY))
                #expect(await ClosedTabDeallocatesTests.waitUntil { cell.content.ghost?.text == "topic" })
                if snapshot.row(index).subject == "Topic one" {
                    #expect(cell.content.labels.contains { $0.kind == .tag && $0.text == "v-topic" })
                }
                graph.mouseMoved(toRow: nil)
                #expect(cell.content.ghost == nil)
            }
            #expect(topics == 2)
        }
    }

    @Test func crowdedRefHoverAndTooltipsNeverOverlap() throws {
        let style = try RefLabelGlyphTests.style()
        style.reduceMotion = true
        let labels = (0..<20).map {
            RefLabel(kind: $0 % 2 == 0 ? .current : .tag, text: "long-branch-or-tag-\($0)", fullName: "ref\($0)")
        }
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 140, height: 100))
        let hover = RefsHoverView()
        hover.show(
            row: 0, labels: labels, slot: 0, isSelected: true, style: style,
            cellFrame: NSRect(x: 0, y: 0, width: 96, height: 32), maxWidth: 140, in: table)
        for (_, frame) in hover.pillFrames { #expect(frame.minX >= 0 && frame.maxX <= 140) }
        for (a, b) in zip(hover.pillFrames, hover.pillFrames.dropFirst()) { #expect(a.1.maxX <= b.1.minX) }
        let regions = PillPainter(style: style, slot: 0).regions(labels[0], at: 0, mid: 16, width: 12)
        #expect(regions.allSatisfy { $0.rect.maxX <= 12 })
    }

    @Test func branchMenuIncludesRequestedWorkflowsAndFullNames() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("Initial")
        let name = "feature/a-very-long-branch-name-for-context-menus"
        try await repo.branch(name)
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        #expect(await ClosedTabDeallocatesTests.waitUntil { session.status != nil })
        let operations = OperationsController(session: session, model: model)
        operations.refs = try await handle.refs()
        let ref = try #require(operations.refs?.ref(named: "refs/heads/" + name))
        let items = NavigatorViewController.branchWriteItems(ref, operations: operations)
        let titles = items.map(\.title)
        #expect(titles.contains("Checkout"))
        #expect(titles.contains("Create Tag at \(name)…"))
        #expect(titles.contains("Create Annotated Tag at \(name)…"))
        #expect(titles.contains("Create Worktree from \(name)…"))
        #expect(titles.contains("Create Patch from Commit…"))
        #expect(titles.contains("Reset main to This Commit"))
        #expect(titles.contains("Push \(name)"))
        #expect(!titles.contains { $0.contains("...") })
        session.close()
    }

    @Test func tagPushPreferenceSurvivesRelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "jit.tag-preference.\(UUID())"))
        let preferences = PreferencesStore(defaults: defaults)
        #expect(!preferences.pushTagsAfterCreation)
        preferences.pushTagsAfterCreation = true
        #expect(PreferencesStore(defaults: defaults).pushTagsAfterCreation)
    }
}
