import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct BranchCleanupTests {
    func confirm(_ names: [String]) -> ConfirmationToken {
        ConfirmationRequest(
            action: .deleteLocalBranches(names: names), title: "", context: "", changes: "",
            recoverability: "", verb: "Delete"
        ).confirm()
    }

    @Test func pruningRemovesStaleRemoteRefsAndCleanupDeletesOnlySafeLocals() async throws {
        let world = try await Ops.world()
        try await world.a.branch("removed")
        try await world.a.git("push", "-u", "origin", "removed")
        try await world.b.git("push", "origin", "--delete", "removed")
        #expect(try await world.handleA.refs().refs.contains { $0.shortName == "origin/removed" })
        _ = try await world.handleA.fetch(FetchRequest(remote: nil, prune: true), context: .anonymous)
        #expect(try await world.handleA.refs().refs.contains { $0.shortName == "origin/removed" } == false)
        try await world.a.branch("unpublished")
        try await world.a.git("switch", "-c", "unmerged")
        try await world.a.commit("Unique commit")
        try await world.a.git("switch", "main")
        try await world.a.branch("worktree")
        try await world.a.git("worktree", "add", world.sandbox.root + "/linked", "worktree")
        let plan = try await world.handleA.prepareBranchCleanup(context: .anonymous)
        #expect(plan.branches == ["removed", "unpublished"])
        #expect(Set(plan.kept) == ["unmerged", "worktree"])
        try await world.handleA.deleteLocalBranches(plan, token: confirm(plan.branches), context: .anonymous)
        #expect(try await world.a.git("branch", "--list", "removed", "unpublished") == "")
        #expect(try await world.a.git("show-ref", "--verify", "refs/heads/unmerged").isEmpty == false)
        #expect(try await world.b.git("ls-remote", "--heads", "origin").contains("refs/heads/main"))
    }

    @Test func cloudCheckProtectsBranchesOutsideFetchRefspecAndRenamedUpstreams() async throws {
        let world = try await Ops.world()
        try await world.b.git("push", "origin", "HEAD:refs/heads/topic")
        try await world.a.branch("topic")
        try await world.a.branch("renamed")
        try await world.a.git("config", "branch.renamed.remote", "origin")
        try await world.a.git("config", "branch.renamed.merge", "refs/heads/topic")
        try await world.a.git("config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main")
        #expect(try await world.handleA.prepareBranchCleanup(context: .anonymous).branches.isEmpty)
    }

    @Test func anotherRemoteProtectsSameNamedBranch() async throws {
        let world = try await Ops.world()
        let other = try await world.b.bareClone("other.git")
        try await world.a.git("remote", "add", "other", other)
        try await world.a.branch("topic")
        try await world.a.git("push", "other", "topic")
        #expect(try await world.handleA.prepareBranchCleanup(context: .anonymous).branches.isEmpty)
    }

    @Test func wrongConfirmationAndChangedRepositoryDeleteNothing() async throws {
        let world = try await Ops.world()
        try await world.a.branch("topic")
        let plan = try await world.handleA.prepareBranchCleanup(context: .anonymous)
        let before = try await RepoFingerprint.capture(world.a)
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.deleteLocalBranches(plan, token: confirm(["other"]), context: .anonymous)
        }
        #expect(try await RepoFingerprint.capture(world.a) == before)
        try await world.a.commit("Changed while confirming")
        let changed = try await RepoFingerprint.capture(world.a)
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.deleteLocalBranches(plan, token: confirm(plan.branches), context: .anonymous)
        }
        #expect(try await RepoFingerprint.capture(world.a) == changed)
    }

    @Test func newlyPublishedBranchIsKeptEvenWithoutFetch() async throws {
        let world = try await Ops.world()
        try await world.a.branch("topic")
        let plan = try await world.handleA.prepareBranchCleanup(context: .anonymous)
        try await world.b.git("push", "origin", "HEAD:refs/heads/topic")
        let before = try await RepoFingerprint.capture(world.a)
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.deleteLocalBranches(plan, token: confirm(plan.branches), context: .anonymous)
        }
        #expect(try await RepoFingerprint.capture(world.a) == before)
    }

    @Test func unbornHeadKeepsLocalBranches() async throws {
        let world = try await Ops.world()
        try await world.a.branch("local-only")
        try await world.a.git("switch", "--orphan", "unborn")
        let plan = try await world.handleA.prepareBranchCleanup(context: .anonymous)
        #expect(plan.branches.isEmpty)
        #expect(plan.kept == ["local-only"])
        #expect(plan.expected.head == nil)
    }

    @Test func unreachableRemoteAndNoRemotesNeverOfferDeletion() async throws {
        let world = try await Ops.world()
        try await world.a.branch("topic")
        try await world.a.git("remote", "set-url", "origin", world.sandbox.root + "/missing.git")
        await #expect(throws: GitCoreError.self) {
            _ = try await world.handleA.prepareBranchCleanup(context: .anonymous)
        }
        try await world.a.git("remote", "remove", "origin")
        await #expect(throws: GitCoreError.self) {
            _ = try await world.handleA.prepareBranchCleanup(context: .anonymous)
        }
        #expect(try await world.a.git("branch", "--list", "topic").contains("topic"))
    }
}
