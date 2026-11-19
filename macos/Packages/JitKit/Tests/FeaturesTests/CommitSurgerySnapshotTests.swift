import AppKit
import GitCore
import SwiftUI
import Testing

@testable import Features

@MainActor
@Suite(
    .serialized,
    .enabled(
        if: Snapshot.isComparable(versionFile: "commit-surgery-os-version.txt"),
        "snapshot references are pinned to another macOS version"))
struct CommitSurgerySnapshotTests {
    @Test(arguments: [Snapshot.Variant.light, .dark], [CommitSurgeryAction.editMessage, .drop])
    func sheets(_ variant: Snapshot.Variant, _ action: CommitSurgeryAction) async throws {
        let (sandbox, repo, handle, session, operations, oid) = try await CommitSurgeryFeatureTests.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        try await repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        var plan = try await handle.commitSurgeryPlan(for: oid, action: action)
        if action == .editMessage { plan.message = "Handle empty input safely\n\nKeep the original author." }
        let view = CommitSurgerySheet(controller: operations, plan: plan)
        let image = Snapshot.render(
            Snapshot.host(view, variant: variant), size: NSSize(width: 560, height: 600), variant: variant)
        if let failure = Snapshot.verify(
            image, name: "commit-surgery-" + action.rawValue, variant: variant,
            versionFile: "commit-surgery-os-version.txt")
        {
            Issue.record(Comment(rawValue: failure))
        }
    }
}
