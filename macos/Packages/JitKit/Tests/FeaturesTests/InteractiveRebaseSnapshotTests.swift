import AppKit
import GitCore
import SwiftUI
import Testing

@testable import Features

@MainActor
@Suite(
    .serialized,
    .enabled(
        if: Snapshot.isComparable(versionFile: "interactive-rebase-os-version.txt"),
        "snapshot references are pinned to another macOS version"))
struct InteractiveRebaseSnapshotTests {
    @Test(arguments: [Snapshot.Variant.light, .dark, .lightOpaque, .darkOpaque])
    func editor(_ variant: Snapshot.Variant) async throws {
        let (_, repo, handle, session, operations, editor) = try await InteractiveRebaseFeatureTests.fixture()
        // Real remote-tracking reachability, no fabricated plan data.
        try await repo.git("update-ref", "refs/remotes/origin/main", "HEAD~1")
        editor.plan = try await handle.interactiveRebasePlan(after: editor.plan.base)
        editor.setAction(.reword, at: 0)
        editor.plan.steps[0].message = "Add a streaming parser\n\nPreserve original authors during replay."
        editor.setAction(.fixup, at: 2)
        editor.setAction(.drop, at: 3)
        let view = RebaseEditorView(model: editor, controller: operations)
        let rep = Snapshot.render(
            Snapshot.host(view, variant: variant), size: NSSize(width: 1000, height: 700), variant: variant)
        if let failure = Snapshot.verify(
            rep, name: "interactive-rebase", variant: variant, versionFile: "interactive-rebase-os-version.txt")
        {
            Issue.record(Comment(rawValue: failure))
        }
        session.close()
    }
}
