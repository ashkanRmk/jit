import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing

@testable import Features

@MainActor
@Suite(.serialized, .enabled(if: Snapshot.isComparable, "snapshot references are pinned to another macOS version"))
struct ResetSnapshotTests {
    @Test(arguments: [Snapshot.Variant.lightOpaque, .darkOpaque])
    func opaquePreview(_ variant: Snapshot.Variant) async throws {
        try await preview(variant, scenario: "stash")
    }

    @Test(arguments: [Snapshot.Variant.light, .dark], ["stash", "discard", "keep", "blocked"])
    func preview(_ variant: Snapshot.Variant, scenario: String) async throws {
        let (_, repo, handle, first, _) = try await ResetTestsFixture.make()
        try repo.write("README.md", "staged\n"); try await repo.git("add", "README.md")
        try repo.write("README.md", "working\n"); try repo.write("notes.txt", "untracked\n")
        if scenario == "blocked" {
            try await repo.git("rm", "-f", "README.md"); try await repo.commit("Remove documentation")
            try repo.write("README.md", "precious untracked notes\n")
        }
        let mode: ResetMode = scenario == "keep" ? .keep : .hard
        let preview = try await handle.resetPreview(to: first, mode: mode)
        let saving = scenario == "stash"
        let request = ResetModel.request(preview, stashFirst: saving, context: "reset-preview · main")
        let root = ConfirmationSheet(
            request: request, cancel: {}, confirm: {},
            extra: AnyView(
                ResetPreviewDetails(
                    preview: preview, stashFirst: .constant(saving),
                    identity: "Commits as Reset QA <reset@jit.invalid> · Personal profile")),
            isConfirmDisabled: ResetModel.isBlocked(preview, stashFirst: saving, hasProfile: true))
        let image = Snapshot.render(
            Snapshot.host(root, variant: variant), size: NSSize(width: 564, height: 740), variant: variant)
        if let failure = Snapshot.verify(image, name: "reset-\(scenario)", variant: variant) {
            Issue.record(Comment(rawValue: failure))
        }
    }
}
