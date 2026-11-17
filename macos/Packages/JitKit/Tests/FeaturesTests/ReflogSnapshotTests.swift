import AppKit
import DesignSystem
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features
@testable import GitCore
@testable import Services

@MainActor
@Suite(.serialized, .enabled(if: Snapshot.isComparable, "snapshot references are pinned to another macOS version"))
struct ReflogSnapshotTests {
    @Test(arguments: [Snapshot.Variant.light, .dark, .lightOpaque, .darkOpaque])
    func explorer(_ variant: Snapshot.Variant) async throws {
        try await capture(variant, mode: .reflog)
    }

    @Test(arguments: [Snapshot.Variant.light, .dark])
    func lostCommits(_ variant: Snapshot.Variant) async throws {
        try await capture(variant, mode: .lost)
    }

    @Test(arguments: [Snapshot.Variant.light, .dark])
    func recoveryPoints(_ variant: Snapshot.Variant) async throws {
        try await capture(variant, mode: .recovery)
    }

    private func capture(_ variant: Snapshot.Variant, mode: ReflogModel.Mode) async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("snapshot-reflog")
        try repo.write("README.md", "A recovered project\n")
        try await repo.commit("Create project")
        try repo.write("README.md", "A project with documentation\n")
        try await repo.commit("Document setup and usage")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle,
            watchesFileSystem: false,
            recoveryLocation: StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/state")))
        session.activate(); await session.settle()
        let identity = GitIdentity(name: "Jit Tests", email: "tests@jit.invalid")
        _ = try await session.commit(
            CommitRequest(
                message: "Document setup, usage and recovery", amend: true,
                identity: IdentitySnapshot(author: identity, committer: identity)))
        await session.settle()
        let model = ReflogModel(session: session)
        model.open()
        #expect(await ClosedTabDeallocatesTests.waitUntil { !model.isLoading && !model.entries.isEmpty })
        if mode == .lost {
            model.findLostCommits()
            #expect(await ClosedTabDeallocatesTests.waitUntil { !model.isScanning && model.hasScanned })
        }
        // The actual operation uses wall time for its journal. Normalize that presentation-only date
        // so the screenshot stays deterministic; Git state and recovery targets come from the real repo.
        session.savedRecoveryPoints = session.savedRecoveryPoints.map {
            RecoveryPoint(
                id: $0.id, operationID: $0.operationID, operation: $0.operation, refName: $0.refName,
                oldOID: $0.oldOID, newOID: $0.newOID, timestamp: Date(timeIntervalSince1970: 1_767_268_800))
        }
        model.mode = mode
        model.selection = model.rows.first?.id
        let app = ClosedTabDeallocatesTests.makeModel(sandbox)
        let operations = OperationsController(session: session, model: app)
        let root = ReflogView(model: model, operations: operations, showInGraph: { _ in }, compareWithCurrent: { _ in })
        let host = Snapshot.host(root, variant: variant)
        let image = Snapshot.render(host, size: NSSize(width: 760, height: 540), variant: variant)
        let name = mode == .reflog ? "reflog" : mode == .lost ? "lost-commits" : "recovery-points"
        if let failure = Snapshot.verify(image, name: name, variant: variant) {
            Issue.record(Comment(rawValue: failure))
        }
        model.close(); session.close()
    }
}
