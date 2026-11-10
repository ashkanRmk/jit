import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// P6.6: a closed repository tab releases everything it built — session, handle, history, graph, workbench,
/// diff and working-directory models — through a real window controller.
@MainActor @Suite(.serialized) struct ClosedTabDeallocatesTests {
    final class Weak {
        weak var object: AnyObject?
        let name: String
        init(_ object: AnyObject?, _ name: String) {
            self.object = object
            self.name = name
        }
    }

    static func makeModel(_ sandbox: GitSandbox) -> AppModel {
        let location = StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/AppSupport"))
        let defaults = UserDefaults(suiteName: "jit.dealloc.\(UUID().uuidString)") ?? .standard
        return AppModel(
            engine: sandbox.engine, preferences: PreferencesStore(defaults: defaults),
            recents: RecentsStore(location: location), profiles: ProfileStore(location: location),
            sessionStore: nil, watchesFileSystem: false)
    }

    static func spin(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            await spin(10)
        }
        return condition()
    }

    @Test func closedRepositoryTabDeallocates() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("dealloc")
        for index in 0..<30 {
            try repo.write("f\(index % 5).txt", "\(index)\n")
            try await repo.commit("Commit \(index)")
        }
        try repo.write("f0.txt", "changed\n")
        let model = Self.makeModel(sandbox)
        model.restore(nil)
        var controller: MainWindowController? = MainWindowController(model: model)
        controller?.showWindow(nil)
        model.setForeground(true)

        var probes: [Weak] = []
        do {
            model.open(URL(fileURLWithPath: repo.path))
            await model.settleOpen()
            let tab = try #require(model.activeTab)
            #expect(await Self.waitUntil { controller?.activeGraph?.loadedCount ?? 0 > 0 })
            let workbench = try #require(controller?.activeWorkbench)
            // Exercise the inspector, working directory and diff paths too.
            _ = workbench.graph?.selectWorkingDirectory()
            #expect(await Self.waitUntil { !(workbench.inspectorModel.workingDirectory?.allFiles.isEmpty ?? true) })
            if let file = workbench.inspectorModel.workingDirectory?.allFiles.first {
                workbench.inspectorModel.workingDirectory?.selection = [file.id]
            }
            #expect(await Self.waitUntil { workbench.diffModel.document != nil })
            probes = [
                Weak(tab, "TabModel"), Weak(tab.session, "RepositorySession"),
                Weak(tab.session?.history, "HistoryController"), Weak(workbench, "WorkbenchController"),
                Weak(workbench.graph, "GraphViewController"), Weak(workbench.diffModel, "DiffViewModel"),
                Weak(workbench.diffController, "DiffViewController"),
                Weak(workbench.operations, "OperationsController"),
                Weak(workbench.inspectorModel, "InspectorModel"),
                Weak(workbench.inspectorModel.workingDirectory, "WorkingDirectoryModel"),
                Weak(workbench.navigator, "NavigatorViewController"),
            ]
            model.closeTab(tab.id)
        }
        // Release can trail the close by more than a fixed pause when the suites run in parallel (a view
        // animation or a short task still holds the tab): wait for it, up to 5 s, instead of a fixed 500 ms.
        await Self.spin(500)
        _ = await Self.waitUntil { probes.allSatisfy { $0.object == nil } }
        let survivors = probes.filter { $0.object != nil }.map(\.name)
        #expect(survivors.isEmpty, "still alive after close: \(survivors)")
        controller?.close()
        controller = nil
    }
}
