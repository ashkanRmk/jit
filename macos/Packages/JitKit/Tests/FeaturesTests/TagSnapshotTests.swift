import AppKit
import Foundation
import GitCore
import Services
import SwiftUI
import Testing

@testable import Features

@MainActor
@Suite(.serialized, .enabled(if: Snapshot.isComparable, "snapshot references are pinned to another macOS version"))
struct TagSnapshotTests {
    @Test(arguments: [Snapshot.Variant.light, .dark, .lightOpaque, .darkOpaque], [false, true])
    func details(_ variant: Snapshot.Variant, annotated: Bool) async throws {
        let (sandbox, repo, handle, first, _) = try await TagTestFixture.make()
        let identity = GitIdentity(name: "Release QA", email: "release@jit.invalid")
        let context = ExecContext(identity: IdentitySnapshot(author: identity, committer: identity))
        try await handle.createTag(
            "release/v1", at: first,
            message: annotated ? "First stable release\n\nIncludes recovery workflows and release documentation." : nil,
            context: context, expected: nil)
        let bare = try await repo.bareClone("origin.git")
        try await repo.git("remote", "add", "origin", bare)
        let ref = try #require(try await handle.refs().tags.first)
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        let controller = OperationsController(session: session, model: ClosedTabDeallocatesTests.makeModel(sandbox))
        controller.refs = try await handle.refs()
        let model = TagDetailsModel()
        await model.load(repository: handle, ref: ref, format: .sha1)
        #expect(model.tag != nil)
        let root = TagManagementView(controller: controller, ref: ref, dismiss: {}, model: model)
        verify(
            root, name: annotated ? "tag-annotated" : "tag-lightweight", variant: variant,
            size: NSSize(width: 500, height: annotated ? 650 : 440))
        session.close()
    }

    @Test(arguments: [Snapshot.Variant.light, .dark])
    func createAndRemoteDelete(_ variant: Snapshot.Variant) async throws {
        let (sandbox, repo, handle, first, _) = try await TagTestFixture.make()
        let app = ClosedTabDeallocatesTests.makeModel(sandbox)
        let identity = GitIdentity(name: "Release QA", email: "release@jit.invalid")
        app.profiles.create(GitProfile(displayName: "Release", colorIndex: 1, author: identity), activate: true)
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        let controller = OperationsController(session: session, model: app)
        let state = try await handle.captureState()
        verify(
            NewTagSheet(
                controller: controller, commit: first, label: "Create project", annotated: true, remotes: ["origin"],
                expected: state),
            name: "tag-create", variant: variant, size: NSSize(width: 520, height: 480))
        let context = ExecContext(identity: IdentitySnapshot(author: identity, committer: identity))
        try await handle.createTag(
            "release/v1", at: first, message: "First stable release", context: context, expected: nil)
        let bare = try await repo.bareClone("origin.git")
        try await repo.git("remote", "add", "origin", bare)
        let preview = try await handle.remoteTagDeletionPreview(named: "release/v1", remote: "origin", context: context)
        var request = RemoteTagDeleteSheet.request(preview, context: "tag-management · main")
        // Only the displayed temporary path is normalized; the plan and tag are from real Git.
        request.changes = request.changes.replacingOccurrences(
            of: preview.maskedDestination, with: "/Repositories/releases.git")
        verify(
            ConfirmationSheet(request: request, cancel: {}, confirm: {}), name: "tag-delete-remote", variant: variant,
            size: NSSize(width: 564, height: 440))
        session.close()
    }

    private func verify<V: View>(_ view: V, name: String, variant: Snapshot.Variant, size: NSSize) {
        let image = Snapshot.render(Snapshot.host(view, variant: variant), size: size, variant: variant)
        if let failure = Snapshot.verify(image, name: name, variant: variant) {
            Issue.record(Comment(rawValue: failure))
        }
    }
}
