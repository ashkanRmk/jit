import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct ReflogFeatureTests {
    @Test func testRecoverCommitAfterHardResetViaBranch() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "original\n")
        let initial = try await repo.commit("Initial")
        try repo.write("a.txt", "lost commit\n")
        let lost = try await repo.commit("Lost commit")
        try await repo.git("reset", "--hard", initial)
        try repo.write("keep.txt", "untracked local file\n")
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let window = MainWindowController(model: model)
        defer { window.close() }
        window.showWindow(nil)
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.loadedCount ?? 0 > 0 })
        window.showReflog(nil)
        let workbench = try #require(window.activeWorkbench)
        let reflog = workbench.reflogModel
        #expect(await ClosedTabDeallocatesTests.waitUntil { !reflog.isLoading && reflog.entries.count >= 3 })
        let entry = try #require(reflog.entries.first { $0.oid.hex() == lost })
        #expect(entry.isUnreachable)
        reflog.selection = entry.id
        #expect(workbench.inspectorModel.mode == .commit(entry.oid))
        let before = try await RepoFingerprint.capture(repo)
        workbench.operations.recoverBranch(at: lost)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                if case .recoverBranch = workbench.operations.sheet { return true }; return false
            })
        guard case .recoverBranch(let commit, let expected) = workbench.operations.sheet else { return }
        #expect(commit == lost)
        workbench.operations.cancelSheet()
        workbench.operations.createBranch("recovered", at: commit, switchTo: false, expected: expected)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                model.activeTab?.session?.history?.refs?.locals.contains { $0.shortName == "recovered" } == true
            })
        let after = try await RepoFingerprint.capture(repo)
        #expect(before.head == after.head && before.index == after.index && before.workingTree == after.workingTree)
        #expect(try await repo.git("rev-parse", "recovered") == lost)
    }

    @Test func staleRecoveryBranchDoesNotMutate() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let initial = try await repo.commit("Initial")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let expected = try await handle.captureState()
        try await repo.commit("Concurrent commit")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) {
            try await handle.createBranch("recovery", startPoint: initial, switchTo: false, expected: expected)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func recoveryGraphIncludesLostTipAndRestoresQuery() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let first = try await repo.commit("First")
        let lost = try await repo.commit("Lost")
        try await repo.git("reset", "--hard", first)
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let window = MainWindowController(model: model)
        defer { window.close() }
        window.showWindow(nil); model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path)); await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.loadedCount == 1 })
        let graph = try #require(window.activeGraph)
        let oid = try #require(ObjectID(hex: lost))
        let initialOID = try #require(ObjectID(hex: first))
        let workbench = try #require(window.activeWorkbench)
        window.showReflog(nil)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                !workbench.reflogModel.isLoading && !workbench.reflogModel.entries.isEmpty
            })
        workbench.reflogModel.selection = workbench.reflogModel.entries.first { $0.oid == oid }?.id
        #expect(workbench.inspectorModel.mode == .commit(oid))
        workbench.cancelOperation(nil)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                workbench.inspectorModel.mode == .commit(initialOID) && !workbench.reflogModel.isOpen
            })
        graph.revealRecoveryCommit(oid, unreachable: true)
        #expect(await ClosedTabDeallocatesTests.waitUntil { graph.selectedOID == lost })
        #expect(graph.viewModel.query.temporaryTip == lost)
        graph.clearRecoveryTip()
        #expect(await ClosedTabDeallocatesTests.waitUntil { graph.loadedCount == 1 })
        #expect(graph.viewModel.query.temporaryTip == nil)
        #expect(try await repo.git("for-each-ref", "refs/jit").isEmpty)
    }

    @Test func closingCancelsReadsAndCommandIsRegistered() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("First")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle,
            watchesFileSystem: false,
            recoveryLocation: StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/state")))
        let model = ReflogModel(session: session)
        model.open(); model.close()
        #expect(!model.isOpen && !model.isLoading && !model.isScanning)
        #expect(model.entries.isEmpty)
        #expect(CommandRegistry.all.contains { $0.id == "repo.reflog" })
    }
}
