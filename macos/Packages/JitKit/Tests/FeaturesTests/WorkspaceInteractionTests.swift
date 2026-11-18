import AppKit
import DesignSystem
import GitCore
import GitTestKit
import Services
import SwiftUI
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct WorkspaceInteractionTests {
    @Test func zoomShortcutsScaleTheWorkspaceAndPersist() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        defer { controller.close() }
        let viewport = try #require(controller.window?.contentViewController?.view as? WorkspaceZoomView)
        #expect(viewport.zoomFactor == 1)
        controller.zoomIn(nil)
        #expect(await ClosedTabDeallocatesTests.waitUntil { viewport.zoomFactor == 1.1 })
        controller.zoomOut(nil)
        #expect(await ClosedTabDeallocatesTests.waitUntil { viewport.zoomFactor == 1 })
        controller.zoomOut(nil)
        #expect(await ClosedTabDeallocatesTests.waitUntil { viewport.zoomFactor == 0.9 })
        controller.resetZoom(nil)
        #expect(await ClosedTabDeallocatesTests.waitUntil { viewport.zoomFactor == 1 })
        let defaults = try #require(UserDefaults(suiteName: "jit.zoom.\(UUID())"))
        let preferences = PreferencesStore(defaults: defaults)
        preferences.zoomLevel = .percent125
        #expect(PreferencesStore(defaults: defaults).zoomLevel == .percent125)
        let byKey = { (key: String) in CommandRegistry.all.first { $0.key == key && $0.modifiers == .command } }
        #expect(byKey("+")?.action == #selector(MainWindowController.zoomIn(_:)))
        #expect(byKey("=")?.action == #selector(MainWindowController.zoomIn(_:)))
        #expect(byKey("-")?.action == #selector(MainWindowController.zoomOut(_:)))
        #expect(byKey("0")?.action == #selector(MainWindowController.resetZoom(_:)))
    }

    @Test func swiftUIButtonsReceiveClicksAtTheirDrawnPositions() async throws {
        _ = NSApplication.shared
        var leftClicks = 0
        var rightClicks = 0
        let host = WorkspaceHostingView(
            rootView: HStack(spacing: 0) {
                Button {
                    leftClicks += 1
                } label: {
                    Text("Left").typeStyle(.body).frame(width: 120, height: 60).contentShape(Rectangle())
                }
                Button {
                    rightClicks += 1
                } label: {
                    Text("Right").typeStyle(.body).frame(width: 120, height: 60).contentShape(Rectangle())
                }
            }.buttonStyle(.plain))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = NSRect(x: 100, y: 400, width: 240, height: 60)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        canvas.addSubview(host)
        let viewport = WorkspaceZoomView()
        viewport.documentView = canvas
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = viewport
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for factor in PreferencesStore.ZoomLevel.allCases.map({ CGFloat($0.factor) }) {
            viewport.setZoom(factor)
            window.layoutIfNeeded()
            viewport.layoutSubtreeIfNeeded()
            await ClosedTabDeallocatesTests.spin(50)
            let point = host.convert(NSPoint(x: 60 * factor, y: 30 * factor), to: nil)
            let before = leftClicks
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            #expect(
                await ClosedTabDeallocatesTests.waitUntil { leftClicks == before + 1 },
                "zoom=\(factor), left=\(leftClicks), right=\(rightClicks)")
            #expect(rightClicks == 0)
        }
    }

    @Test func graphColumnFollowsMouseWithoutSnappingAndRestores() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("First")
        try await repo.branch("a-very-long-branch-name-that-must-not-control-the-column-width")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        defer { controller.close() }
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(
            await ClosedTabDeallocatesTests.waitUntil { (controller.activeGraph?.history?.snapshot.count ?? 0) > 0 })
        let graph = try #require(controller.activeGraph)
        let table = graph.tableView
        let column = try #require(table.tableColumn(withIdentifier: GraphViewController.columnRefs))
        let window = try #require(controller.window)
        for target: CGFloat in [61, 139, 333] {
            let rect = table.rect(ofColumn: table.column(withIdentifier: column.identifier))
            let start = table.convert(NSPoint(x: rect.maxX, y: table.visibleRect.midY), to: nil)
            let end = NSPoint(x: start.x + target - column.width, y: start.y)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
                try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            table.mouseDown(with: try event(.leftMouseDown, start))
            table.mouseDragged(with: try event(.leftMouseDragged, end))
            table.mouseUp(with: try event(.leftMouseUp, end))
            graph.view.layoutSubtreeIfNeeded()
            #expect(abs(column.width - target) < 0.5)
            let saved = GraphColumnLayout(json: model.activeTab?.ui[GraphViewController.columnsKey])
            #expect(saved.widths[.refs] == target)
        }
    }

    @Test func workspaceLayoutsStaySeparatedAcrossZoomSizesAndAppearances() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a-long-file-name.swift", "let message = \"Hello world\"\n")
        try await repo.commit("Commit with a long description for layout verification")
        try await repo.branch("feature/a-very-long-local-branch-name")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        defer { controller.close() }
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { controller.activeGraph?.selectedOID != nil })
        let window = try #require(controller.window)
        let workbench = try #require(controller.activeWorkbench)
        let viewport = try #require(window.contentViewController?.view as? WorkspaceZoomView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width: CGFloat in [960, 1180, 1600] {
                window.setContentSize(NSSize(width: width, height: 720))
                for level in [PreferencesStore.ZoomLevel.percent75, .percent100, .percent150] {
                    model.preferences.zoomLevel = level
                    #expect(
                        await ClosedTabDeallocatesTests.waitUntil { abs(viewport.zoomFactor - level.factor) < 0.001 }
                    )
                    window.layoutIfNeeded()
                    viewport.layoutSubtreeIfNeeded()
                    await ClosedTabDeallocatesTests.spin(70)
                    let panes = workbench.splitViewItems.filter { !$0.isCollapsed }.map {
                        $0.viewController.view.convert($0.viewController.view.bounds, to: workbench.splitView)
                    }
                    for (left, right) in zip(panes, panes.dropFirst()) {
                        #expect(left.maxX <= right.minX + 0.5)
                    }
                    if let graph = controller.activeGraph,
                        let bar = graph.view.subviews.compactMap({ $0 as? WorkspaceHostingView<GraphBar> }).first
                    {
                        #expect(bar.convert(bar.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 1)
                        #expect(bar.safeAreaRegions.isEmpty)
                    }
                    #expect(abs(viewport.contentView.bounds.minX) < 1)
                    #expect(abs(workbench.view.convert(NSPoint.zero, to: nil).x) < 1)
                    #expect(abs(workbench.splitView.frame.minX) < 1)
                    #expect(abs(workbench.splitView.frame.width - workbench.view.bounds.width) < 1)
                    #expect(workbench.view.bounds.width >= PanelMetrics.windowMinWidth - 1)
                    let physical = workbench.view.convert(NSRect(x: 0, y: 0, width: 100, height: 100), to: nil)
                    #expect(abs(physical.width - 100 * level.factor) < 1)
                    if let directory = ProcessInfo.processInfo.environment["JIT_UI_EVIDENCE_DIR"],
                        let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        let name =
                            "\(appearance == .aqua ? "light" : "dark")-\(Int(width))-\(Int(level.factor * 100)).png"
                        try rep.representation(using: .png, properties: [:])?.write(
                            to: URL(fileURLWithPath: directory + "/" + name))
                    }
                }
            }
        }
    }

    @Test func bulkCleanupRequiresConfirmationAndCancelPreservesBranches() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("First")
        let remote = try await repo.bareClone("origin.git")
        try await repo.git("remote", "add", "origin", remote)
        try await repo.branch("local-only")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        defer { controller.close() }
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { controller.activeGraph?.selectedOID != nil })
        let operations = try #require(controller.activeWorkbench?.operations)
        operations.cleanUpLocalBranches()
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                if case .confirm = operations.sheet { return true }
                return false
            })
        #expect(try await repo.git("branch", "--list", "local-only").contains("local-only"))
        operations.cancelSheet()
        #expect(try await repo.git("branch", "--list", "local-only").contains("local-only"))
        operations.cleanUpLocalBranches()
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                if case .confirm = operations.sheet { return true }
                return false
            })
        guard case .confirm(let request) = operations.sheet else { return }
        #expect(request.losses.contains("local-only"))
        operations.confirmed(request)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                operations.session.operations.lastFinished?.title == "Clean up local branches" && !model.isBusy
            })
        #expect(model.toast?.failed == false)
        #expect(try await repo.git("branch", "--list", "local-only") == "")
        #expect(try await repo.git("ls-remote", "--heads", "origin").contains("refs/heads/main"))
    }

    @Test func localOnlyRowsOfferTrashAndLiveRemoteRowsDoNot() throws {
        let oid = testObjectID("a")
        let local = GitRef(fullName: "refs/heads/topic", kind: .local, object: oid, commit: oid)
        let remote = GitRef(fullName: "refs/remotes/origin/topic", kind: .remote, object: oid, commit: oid)
        let without = RefSnapshot(head: .unborn(branch: "main"), refs: [local], format: .sha1, revision: 1)
        #expect(!without.hasRemoteCounterpart(local))
        let with = RefSnapshot(head: .unborn(branch: "main"), refs: [local, remote], format: .sha1, revision: 2)
        #expect(with.hasRemoteCounterpart(local))
        let cell = NavigatorCellView()
        var deleted = false
        cell.configure(
            NavigatorNode(kind: .ref(local), title: "topic", id: local.fullName), pinned: false,
            canDelete: true, deleteBranch: { deleted = true })
        let trash = try #require(cell.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
        #expect(trash.toolTip == "Delete Local Branch topic…")
        trash.performClick(nil)
        #expect(deleted)
        cell.configure(NavigatorNode(kind: .ref(remote), title: "topic", id: remote.fullName), pinned: false)
        #expect(trash.isHidden)
    }
}
