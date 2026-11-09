import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// P4.8 — branch create / switch / rename / delete / upstream.
@Suite struct BranchOperationTests {
    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(action: action, title: "", context: "", changes: "", recoverability: "", verb: "OK")
            .confirm()
    }

    @Test func branchNameValidatedByGit() async throws {
        let (_, repo, handle) = try await Ops.single()
        for bad in ["a..b", "has space", "-dash", "end.lock", "x~1", ""] {
            await #expect(throws: GitCoreError.self, "\(bad)") { _ = try await handle.validateBranchName(bad) }
        }
        #expect(try await handle.validateBranchName("feature/login") == "feature/login")
        try await repo.branch("taken")
        await #expect(throws: GitCoreError.self) { _ = try await handle.validateBranchName("taken") }
    }

    @Test func createBranchAndSwitch() async throws {
        let (_, repo, handle) = try await Ops.single()
        let head = try await repo.git("rev-parse", "HEAD")
        #expect(try await handle.createBranch("topic", startPoint: head, switchTo: true, expected: nil) == .switched)
        #expect(try await repo.git("symbolic-ref", "--short", "HEAD") == "topic")
        #expect(try await handle.createBranch("other", startPoint: "HEAD", switchTo: false, expected: nil) == .switched)
        #expect(try await repo.git("symbolic-ref", "--short", "HEAD") == "topic")
    }

    @Test func switchCarriesNonConflictingChanges() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n", "b.txt": "b\n"])
        try await repo.branch("other")
        try repo.write("b.txt", "edited\n")
        try repo.write("new.txt", "untracked\n")
        #expect(try await handle.switchTo(.branch("other"), expected: nil) == .switched)
        #expect(try Ops.read(repo, "b.txt") == "edited\n")
        #expect(try Ops.read(repo, "new.txt") == "untracked\n")
    }

    @Test func switchBlockedListsPathsAndChangesNothing() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n", "b c.txt": "b\n"])
        try await repo.git("switch", "-q", "-c", "other")
        try repo.write("b c.txt", "other\n")
        try await repo.commit("Other")
        try await repo.git("switch", "-q", "main")
        try repo.write("b c.txt", "dirty\n")
        let before = try await RepoFingerprint.capture(repo)
        #expect(
            try await handle.switchTo(.branch("other"), expected: nil)
                == .wouldOverwrite(paths: ["b c.txt"], untracked: false))
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func checkoutRemoteCreatesTracking() async throws {
        let world = try await Ops.world()
        try await world.b.git("push", "-q", "origin", "HEAD:refs/heads/feature/x")
        try await world.a.git("fetch", "-q")
        _ = try await world.handleA.switchTo(
            .trackRemote(remote: "origin", branch: "feature/x", localName: "feature/x"), expected: nil)
        #expect(try await world.a.git("symbolic-ref", "--short", "HEAD") == "feature/x")
        #expect(try await world.a.git("rev-parse", "--abbrev-ref", "feature/x@{upstream}") == "origin/feature/x")
    }

    @Test func detachAtCommit() async throws {
        let (_, repo, handle) = try await Ops.single()
        let first = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("Second")
        _ = try await handle.switchTo(.detach(first), expected: nil)
        #expect((try? await repo.git("symbolic-ref", "-q", "HEAD")) == nil)
        #expect(try await repo.git("rev-parse", "HEAD") == first)
    }

    @Test func renameKeepsUpstream() async throws {
        let world = try await Ops.world()
        try await world.a.git("switch", "-q", "-c", "old")
        try await world.a.git("push", "-q", "-u", "origin", "old")
        try await world.handleA.renameBranch("old", to: "new", expected: nil)
        #expect(try await world.a.git("rev-parse", "--abbrev-ref", "new@{upstream}") == "origin/old")
        #expect(try await world.a.git("symbolic-ref", "--short", "HEAD") == "new")
    }

    @Test func deleteUnmergedRequiresForceToken() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.git("switch", "-q", "-c", "unmerged")
        try await repo.commit("Only here")
        try await repo.git("switch", "-q", "main")
        let before = try await RepoFingerprint.capture(repo)
        do {
            try await handle.deleteBranch(
                "unmerged", token: confirm(.deleteBranch(name: "unmerged", force: false)),
                expected: try await handle.captureState())
            Issue.record("-d must refuse an unmerged branch")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3's SILGen crashes on `catch .failed(let …)` here.
            guard case .failed(let failure) = error else { throw error }
            #expect(failure.kind == .branchNotFullyMerged)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        let unmerged = try await handle.commits(in: "refs/heads/unmerged", notIn: "HEAD")
        #expect(unmerged.map(\.subject) == ["Only here"])
        try await handle.deleteBranch(
            "unmerged", token: confirm(.deleteBranch(name: "unmerged", force: true)),
            expected: try await handle.captureState())
        #expect(try await repo.git("branch", "--list", "unmerged") == "")
    }

    @Test func deleteRemoteBranch() async throws {
        let world = try await Ops.world()
        try await world.a.git("push", "-q", "origin", "HEAD:refs/heads/gone")
        let outcome = try await world.handleA.deleteRemoteBranch(
            remote: "origin", branch: "gone",
            expectedTip: try #require(try await world.handleA.remoteTrackingOID(remote: "origin", branch: "gone")),
            token: confirm(.deleteRemoteBranch(remote: "origin", branch: "gone")))
        #expect(outcome.refs.first?.status == .deleted)
        #expect(try await world.sandbox.git(["branch", "--list", "gone"], in: world.origin) == "")
    }

    @Test func setUnsetUpstream() async throws {
        let world = try await Ops.world()
        try await world.a.git("switch", "-q", "-c", "local")
        try await world.handleA.setUpstream(of: "local", to: "origin/main")
        #expect(try await world.a.git("rev-parse", "--abbrev-ref", "local@{upstream}") == "origin/main")
        try await world.handleA.setUpstream(of: "local", to: nil)
        #expect((try? await world.a.git("rev-parse", "--abbrev-ref", "local@{upstream}")) == nil)
    }

    @Test func branchOpsStaleRevisionRejected() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.branch("x")
        let token = try await handle.captureState()
        try await repo.branch("made-in-terminal")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { try await handle.renameBranch("x", to: "y", expected: token) }
        await #expect(throws: GitCoreError.self) { _ = try await handle.switchTo(.branch("x"), expected: token) }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func switchToBranchInOtherWorktreeRefused() async throws {
        let (_, repo, handle) = try await Ops.single()
        _ = try await repo.addWorktree("wt", branch: "busy")
        let before = try await RepoFingerprint.capture(repo)
        do {
            _ = try await handle.switchTo(.branch("busy"), expected: nil)
            Issue.record("switch to a branch checked out elsewhere must fail")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3's SILGen crashes on `catch .failed(let …)` here.
            guard case .failed(let failure) = error else { throw error }
            #expect(failure.kind == .branchCheckedOutElsewhere)
            #expect(failure.detail.contains("wt"))
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func lockedIndexRefusesMutations() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.branch("other")
        FileManager.default.createFile(atPath: repo.path + "/.git/index.lock", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: repo.path + "/.git/index.lock") }
        let before = try await RepoFingerprint.capture(repo)
        do {
            _ = try await handle.switchTo(.branch("other"), expected: nil)
            Issue.record("switch with index.lock must fail")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3 SILGen crashes on non-exhaustive typed catches (CI, Xcode 26).
            guard case .indexLocked = error else { throw error }
        }
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.merge(MergeRequest(source: "other"), context: Ops.context, expected: nil)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }
}
