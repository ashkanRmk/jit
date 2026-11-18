import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct ResetFeatureTests {
    @Test func testHardResetSheetListsFilesAndOffersStash() async throws {
        let (_, repo, handle, first, head) = try await ResetTestsFixture.make()
        try repo.write("README.md", "working copy\n")
        try repo.write("notes.txt", "untracked\n")
        let model = ResetModel()
        await model.load(repository: handle, commit: first, mode: .hard)
        let preview = try #require(model.preview)
        #expect(model.stashFirst)
        #expect(preview.discardedPaths == ["README.md"])
        #expect(preview.unreachableCount == 1)
        #expect(ResetModel.isBlocked(preview, stashFirst: true, hasProfile: false))
        #expect(!ResetModel.isBlocked(preview, stashFirst: false, hasProfile: false))
        let request = ResetModel.request(preview, stashFirst: true, context: "reset · main")
        #expect(request.verb == "Stash and Hard Reset" && request.isHighRisk)
        #expect(request.recoveryValue == head)
        let session = RepositorySession(
            path: repo.path, engine: repo.sandbox.engine, handle: handle,
            watchesFileSystem: false,
            recoveryLocation: StoreLocation(directory: URL(fileURLWithPath: repo.sandbox.root + "/state")))
        let identity = GitIdentity(name: "Reset QA", email: "reset@jit.invalid")
        let result = await session.reset(
            preview, stashFirst: true, token: request.confirm(),
            context: ExecContext(identity: IdentitySnapshot(author: identity, committer: identity)))
        let outcome = try result.get()
        #expect(outcome.stashOID != nil)
        #expect(session.recoveryPoints.first?.oldOID == head)
        #expect(session.savedRecoveryPoints.first?.oldOID == head)
        let reflog = ReflogModel(session: session)
        reflog.open()
        #expect(await ClosedTabDeallocatesTests.waitUntil { !reflog.isLoading && !reflog.entries.isEmpty })
        #expect(reflog.entries.contains { $0.oid.hex() == head })
        let app = ClosedTabDeallocatesTests.makeModel(repo.sandbox)
        let controller = OperationsController(session: session, model: app)
        controller.recoverBranch(at: head)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                if case .recoverBranch = controller.sheet { return true }; return false
            })
        _ = try await handle.createBranch(
            "recovered", startPoint: head, switchTo: true, expected: handle.captureState())
        try await repo.git("stash", "apply", "--index", #require(outcome.stashOID))
        #expect(try String(contentsOfFile: repo.path + "/README.md", encoding: .utf8) == "working copy\n")
        #expect(try String(contentsOfFile: repo.path + "/notes.txt", encoding: .utf8) == "untracked\n")
        reflog.close(); session.close()
    }

    @Test func resetModelShowsFailureAndReloads() async throws {
        let (_, repo, handle, first, _) = try await ResetTestsFixture.make()
        defer { withExtendedLifetime(repo) {} }
        let model = ResetModel()
        await model.load(repository: handle, commit: "bad-revision", mode: .hard)
        #expect(model.preview == nil && model.error != nil)
        await model.load(repository: handle, commit: first, mode: .keep)
        #expect(model.preview?.mode == .keep && model.error == nil && !model.stashFirst)
    }
}

enum ResetTestsFixture {
    static func make() async throws -> (GitSandbox, TestRepo, RepositoryHandle, String, String) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("reset-preview")
        try repo.write("README.md", "initial\n")
        let first = try await repo.commit("Create project")
        try repo.write("README.md", "committed\n")
        let head = try await repo.commit("Document recovery workflow")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return (sandbox, repo, handle, first, head)
    }
}
