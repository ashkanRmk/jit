import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Regressions for the Phase 4 safety review: partial manual edits are detected, the resolver only writes
/// conflicted paths inside the work tree, fallback choices must fit the conflict, abort/remote-delete are bound
/// to what the user saw.
@Suite struct SafetyRegressionTests {
    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(action: action, title: "", context: "", changes: "", recoverability: "", verb: "OK")
            .confirm()
    }

    /// Two separate conflict blocks in `a.txt`.
    func twoBlockConflict() async throws -> (TestRepo, RepositoryHandle) {
        let (_, repo, _) = try await Ops.single(["a.txt": (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"])
        func edit(_ tag: String) throws {
            var lines = (1...20).map { "line \($0)" }
            lines[1] = "two \(tag)"
            lines[17] = "eighteen \(tag)"
            try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
        }
        try await repo.git("switch", "-q", "-c", "theirs")
        try edit("theirs")
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try edit("ours")
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "theirs")
        return (repo, try await Ops.open(repo))
    }

    @Test func untouchedConflictFileMatchesGit() async throws {
        let (repo, handle) = try await twoBlockConflict()
        defer { withExtendedLifetime(repo) {} }
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        #expect(document.workingTreeMatchesGit)
    }

    @Test func untouchedConflictMatchesGitInDiff3Style() async throws {
        let (repo, _) = try await twoBlockConflict()
        try await repo.git("merge", "--abort")
        try await repo.git("config", "merge.conflictStyle", "diff3")
        _ = try? await repo.git("merge", "theirs")
        let handle = try await Ops.open(repo)
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        #expect(document.workingTreeMatchesGit)
    }

    @Test func partialManualEditIsNotTreatedAsUnedited() async throws {
        let (repo, handle) = try await twoBlockConflict()
        // Resolve the first block by hand in "another editor", leave the second with markers.
        var text = try Ops.read(repo, "a.txt")
        let start = try #require(text.range(of: "<<<<<<< "))
        let end = try #require(text.range(of: ">>>>>>> theirs\n", range: start.upperBound..<text.endIndex))
        text.replaceSubrange(start.lowerBound..<end.upperBound, with: "two (resolved by hand)\n")
        try repo.write("a.txt", text)
        #expect(text.contains("<<<<<<< "))
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        #expect(!document.workingTreeMatchesGit)
    }

    @Test func missingFileHashDiffersFromEmptyFile() {
        #expect(FileHash.missing != FileHash([UInt8]()))
        #expect(FileHash([UInt8]()).exists)
        #expect(!FileHash.missing.exists)
    }

    @Test func resolverWritesOnlyConflictedPathsInsideTheWorkTree() async throws {
        let (repo, handle) = try await twoBlockConflict()
        let config = try FileHash(Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/config")))
        for path in [".git/config", "x/../.git/config", "./a.txt", "/etc/hosts", ""] {
            await #expect(throws: GitCoreError.self, "\(path)") {
                _ = try await handle.saveResolution(path, content: Array("x".utf8), expected: config)
            }
        }
        try repo.write("clean.txt", "clean\n")
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.saveResolution(
                "clean.txt", content: Array("x".utf8), expected: FileHash(Array("clean\n".utf8)))
        }
        #expect(try Ops.read(repo, "clean.txt") == "clean\n")
        #expect(try FileHash(Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/config"))) == config)
    }

    @Test func resolverRefusesWritesThroughSymlinkedFolders() async throws {
        let (repo, handle) = try await twoBlockConflict()
        let outside = try repo.sandbox.makeDirectory("outside")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: outside)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.saveResolution("link/evil.txt", content: Array("x".utf8), expected: .missing)
        }
        #expect(!FileManager.default.fileExists(atPath: outside + "/evil.txt"))
    }

    @Test func fallbackChoiceMustFitTheConflict() async throws {
        let (repo, handle) = try await twoBlockConflict()
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            try await handle.resolveWithSide(
                "a.txt", choice: .deleteFile, token: confirm(.resolveConflict(path: "a.txt", choice: "deleteFile")))
        }
        await #expect(throws: GitCoreError.self) {
            try await handle.resolveWithSide(
                "a.txt", choice: .keepFile, token: confirm(.resolveConflict(path: "a.txt", choice: "keepFile")))
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func abortRefusedWhenTheOperationChanged() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        _ = try await handle.merge(MergeRequest(source: "feature"), context: Ops.context, expected: nil)
        let shown = try await handle.captureState()
        // Terminal: abort the merge, then start a cherry-pick that conflicts.
        try await repo.git("merge", "--abort")
        _ = try? await repo.git("cherry-pick", try await repo.git("rev-parse", "feature"))
        let before = try await RepoFingerprint.capture(repo)
        do {
            try await handle.abortOperation(token: confirm(.abortOperation), expected: shown)
            Issue.record("abort of a different operation must be refused")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3 SILGen crashes on non-exhaustive typed catches (CI, Xcode 26).
            guard case .staleSnapshot = error else { throw error }
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func remoteDeleteLeasedToTheShownTip() async throws {
        let world = try await Ops.world()
        try await world.a.git("push", "-q", "origin", "HEAD:refs/heads/shared")
        let shown = try #require(try await world.handleA.remoteTrackingOID(remote: "origin", branch: "shared"))
        // Someone else pushes to it.
        try await world.b.git("fetch", "-q")
        try await world.b.git("switch", "-q", "-c", "shared", "origin/shared")
        try world.b.write("new.txt", "new\n")
        let theirs = try await world.b.commit("Their work")
        try await world.b.git("push", "-q", "origin", "shared")
        let outcome = try await world.handleA.deleteRemoteBranch(
            remote: "origin", branch: "shared", expectedTip: shown,
            token: confirm(.deleteRemoteBranch(remote: "origin", branch: "shared")))
        #expect(outcome.rejection == .staleLease)
        #expect(try await world.sandbox.git(["rev-parse", "shared"], in: world.origin) == theirs)
    }

    @Test func pushRejectsRefspecInjection() async throws {
        let world = try await Ops.world()
        for name in ["main:refs/heads/other", "has space", "a..b"] {
            await #expect(throws: GitCoreError.self, "\(name)") {
                _ = try await world.handleA.push(PushRequest(remote: "origin", localBranch: "main", remoteBranch: name))
            }
        }
    }
}
