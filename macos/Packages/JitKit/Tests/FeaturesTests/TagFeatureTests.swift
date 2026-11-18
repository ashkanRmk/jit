import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct TagFeatureTests {
    @Test func testCreateAnnotatedTagAndPushThenDeleteRemoteAndLocal() async throws {
        let (sandbox, repo, handle, first, _) = try await TagTestFixture.make()
        let bare = try await repo.bareClone("remote.git")
        try await repo.git("remote", "add", "origin", bare)
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle,
            watchesFileSystem: false,
            recoveryLocation: StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/state")))
        session.activate(); await session.settle()
        let app = ClosedTabDeallocatesTests.makeModel(sandbox)
        app.profiles.create(
            GitProfile(
                displayName: "Release", colorIndex: 1, author: GitIdentity(name: "Tag QA", email: "tag@jit.invalid")),
            activate: true)
        let controller = OperationsController(session: session, model: app)
        controller.refs = try await handle.refs()
        controller.createTag(
            "release/v1", at: first, message: "Release notes\n\nOlder commit", remote: "origin",
            expected: try await handle.captureState())
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                session.operations.records.contains { $0.title == "Push tag release/v1" && $0.state.isFinished }
            })
        let tag = try await handle.tagDetails(named: "release/v1")
        #expect(tag.targetOID == first && tag.tagger == "Tag QA <tag@jit.invalid>")
        #expect(try await repo.git("ls-remote", "--refs", "origin", "refs/tags/release/v1").contains(tag.objectOID))
        let preview = try await handle.remoteTagDeletionPreview(named: tag.name, remote: "origin", context: .anonymous)
        let request = RemoteTagDeleteSheet.request(preview, context: "tags · main")
        #expect(request.isHighRisk && request.recoveryValue == tag.objectOID)
        try await session.deleteRemoteTag(preview, token: request.confirm(), context: .anonymous).get()
        #expect(try await repo.git("ls-remote", "--refs", "origin", "refs/tags/release/v1").isEmpty)
        controller.refs = try await handle.refs()
        let ref = try #require(controller.refs?.tags.first)
        controller.deleteLocalTag(ref)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                if case .confirm = controller.sheet { return true }; return false
            })
        guard case .confirm(let deletion) = controller.sheet else { return }
        #expect(deletion.recoveryValue == tag.objectOID)
        controller.confirmed(deletion)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                session.operations.records.contains { $0.title == "Delete tag release/v1" && $0.state.isFinished }
            })
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                session.savedRecoveryPoints.contains {
                    $0.oldOID == tag.objectOID && $0.refName == "refs/tags/release/v1"
                }
            })
        session.close()
    }

    @Test func tagDetailsModelHandlesChangedTagAndRefresh() async throws {
        let (_, repo, handle, _, _) = try await TagTestFixture.make()
        try await repo.git("tag", "v1")
        let ref = try #require(try await handle.refs().tags.first)
        try await repo.git("tag", "-f", "v1", "HEAD~1")
        let model = TagDetailsModel()
        await model.load(repository: handle, ref: ref, format: .sha1)
        #expect(model.tag == nil && model.error?.contains("changed") == true)
        let fresh = try #require(try await handle.refs().tags.first)
        await model.load(repository: handle, ref: ref, format: .sha1, refresh: true)
        #expect(model.tag?.objectOID == fresh.object.hex() && model.error == nil)
    }

    @Test func tagRowsAndSharedMenusExposeManagement() async throws {
        let (sandbox, repo, handle, first, _) = try await TagTestFixture.make()
        try await handle.createTag(
            "v1", at: first, message: "Notes",
            context: ExecContext(
                identity: IdentitySnapshot(
                    author: GitIdentity(name: "QA", email: "qa@jit.invalid"),
                    committer: GitIdentity(name: "QA", email: "qa@jit.invalid"))), expected: nil)
        let ref = try #require(try await handle.refs().tags.first)
        let cell = NavigatorCellView()
        cell.configure(NavigatorNode(kind: .ref(ref), title: "v1", id: ref.fullName), pinned: false)
        #expect(cell.accessibilityLabel()?.contains("Annotated tag") == true)
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        let operations = OperationsController(session: session, model: ClosedTabDeallocatesTests.makeModel(sandbox))
        let items = NavigatorViewController.branchWriteItems(ref, operations: operations)
        #expect(items.contains { $0.title == "Tag Details and Actions…" })
        #expect(items.contains { $0.title == "Delete Local Tag…" })
        #expect(CommandRegistry.all.contains { $0.id == "branch.createAnnotatedTag" && $0.inPalette })
        #expect(CommandRegistry.all.contains { $0.id == "branch.manageTag" && $0.inPalette })
        session.close()
    }
}

enum TagTestFixture {
    static func make() async throws -> (GitSandbox, TestRepo, RepositoryHandle, String, String) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("tag-management")
        try repo.write("README.md", "initial\n")
        let first = try await repo.commit("Create project")
        try repo.write("README.md", "later\n")
        let head = try await repo.commit("Later development")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return (sandbox, repo, handle, first, head)
    }
}

extension TagFeatureTests {
    @Test func createAndPushRefusalKeepsLocalTagAndExplainsPartialSuccess() async throws {
        let (sandbox, repo, handle, first, _) = try await TagTestFixture.make()
        let bare = try await repo.bareClone("remote.git")
        try await repo.git("remote", "add", "origin", bare)
        let hook = bare + "/hooks/pre-receive"
        try "#!/bin/sh\necho 'Tag policy refused this push' >&2\nexit 1\n".write(
            toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook)
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        let app = ClosedTabDeallocatesTests.makeModel(sandbox)
        let controller = OperationsController(session: session, model: app)
        controller.createTag("v1", at: first, message: nil, remote: "origin", expected: try await handle.captureState())
        #expect(await ClosedTabDeallocatesTests.waitUntil { app.toast?.title.contains("Push Failed") == true })
        #expect(app.toast?.failed == true)
        #expect(try await handle.tagDetails(named: "v1").targetOID == first)
        #expect(try await repo.git("ls-remote", "--refs", "origin", "refs/tags/v1").isEmpty)
        session.close()
    }
}
