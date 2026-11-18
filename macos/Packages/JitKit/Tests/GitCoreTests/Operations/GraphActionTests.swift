import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct GraphActionTests {
    private func confirmation(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(
            action: action, title: "Test", context: "Test", changes: "Test",
            recoverability: "Test", verb: "Confirm"
        ).confirm()
    }

    @Test func lightweightAndAnnotatedTagsPointAtTheSelectedCommit() async throws {
        let (_, repo, handle) = try await Ops.single()
        let first = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("Second")
        try await handle.createTag("v1", at: first, message: nil, context: .anonymous, expected: handle.captureState())
        try await handle.createTag(
            "v2", at: first, message: "Release notes\n", context: Ops.context, expected: handle.captureState())
        #expect(try await repo.git("rev-parse", "v1^{commit}") == first)
        #expect(try await repo.git("rev-parse", "v2^{commit}") == first)
        #expect(try await repo.git("cat-file", "-t", "v1") == "commit")
        #expect(try await repo.git("cat-file", "-t", "v2") == "tag")
        #expect(
            try await repo.git("for-each-ref", "--format=%(taggeremail)", "refs/tags/v2") == "<ada@profile.example>")
    }

    @Test func tagRejectsInvalidDuplicateAndStaleRequestsWithoutChangingRefs() async throws {
        let (_, repo, handle) = try await Ops.single()
        let head = try await repo.git("rev-parse", "HEAD")
        let token = try await handle.captureState()
        for name in ["", "-dash", "a..b", "has space", "bad\nname", "x.lock"] {
            await #expect(throws: GitCoreError.self) {
                try await handle.createTag(name, at: head, message: nil, context: .anonymous, expected: token)
            }
        }
        try await handle.createTag("v1", at: head, message: nil, context: .anonymous, expected: token)
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            try await handle.createTag("v1", at: head, message: nil, context: .anonymous, expected: nil)
        }
        await #expect(throws: GitCoreError.self) {
            try await handle.createTag("v2", at: head, message: nil, context: .anonymous, expected: token)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func annotatedTagRequiresTheProfileIdentity() async throws {
        let (_, repo, handle) = try await Ops.single()
        let head = try await repo.git("rev-parse", "HEAD")
        await #expect(throws: GitCoreError.self) {
            try await handle.createTag("v1", at: head, message: "Notes", context: .anonymous, expected: nil)
        }
        #expect((try? await repo.git("rev-parse", "--verify", "refs/tags/v1")) == nil)
    }

    @Test func pushingTagDoesNotPublishOtherTagsOrBranches() async throws {
        let world = try await Ops.world()
        let head = try await world.a.git("rev-parse", "HEAD")
        for name in ["release/v1", "private-tag"] {
            try await world.handleA.createTag(name, at: head, message: nil, context: .anonymous, expected: nil)
        }
        try await world.a.branch("private-branch")
        try await world.handleA.pushTag("release/v1", remote: "origin", context: .anonymous)
        #expect(try await world.a.git("ls-remote", "--tags", "origin", "refs/tags/release/v1").contains(head))
        #expect(
            try await world.a.git("ls-remote", "origin", "refs/tags/private-tag", "refs/heads/private-branch").isEmpty)
        try await world.a.commit("Moved")
        try await world.a.git("tag", "-f", "release/v1")
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.pushTag("release/v1", remote: "origin", context: .anonymous)
        }
        #expect(try await world.a.git("ls-remote", "--tags", "origin", "refs/tags/release/v1").contains(head))
    }

    @Test func pullInactiveBranchKeepsHeadIndexAndWorkingFiles() async throws {
        let world = try await Ops.world()
        try await world.a.git("branch", "--track", "topic", "origin/main")
        let oldHead = try await world.a.git("rev-parse", "HEAD")
        try world.a.write("a.txt", "local dirty content\n")
        try await world.b.commit("Incoming")
        try await world.b.git("push", "-q")
        let incoming = try await world.b.git("rev-parse", "HEAD")
        try await world.handleA.pullBranch("topic", context: .anonymous, expected: world.handleA.captureState())
        #expect(try await world.a.git("rev-parse", "topic") == incoming)
        #expect(try await world.a.git("rev-parse", "HEAD") == oldHead)
        #expect(try await world.a.git("symbolic-ref", "--short", "HEAD") == "main")
        #expect(try Ops.read(world.a, "a.txt") == "local dirty content\n")
    }

    @Test func pullRefusesDivergenceAndCheckedOutBranches() async throws {
        let world = try await Ops.world()
        try await world.a.git("checkout", "-q", "-b", "topic", "--track", "origin/main")
        try await world.a.commit("Local topic")
        let topic = try await world.a.git("rev-parse", "HEAD")
        try await world.a.git("switch", "main")
        let worktree = world.sandbox.root + "/topic-worktree"
        try await world.a.git("worktree", "add", worktree, "topic")
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.pullBranch("topic", context: .anonymous, expected: nil)
        }
        try await world.a.git("worktree", "remove", worktree)
        try await world.b.commit("Incoming")
        try await world.b.git("push", "-q")
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.pullBranch("topic", context: .anonymous, expected: nil)
        }
        #expect(try await world.a.git("rev-parse", "topic") == topic)
    }

    @Test func explicitRemotePullUsesThatRemoteWithoutChangingUpstream() async throws {
        let world = try await Ops.world()
        try await world.b.commit("Only on alternate remote")
        let incoming = try await world.b.git("rev-parse", "HEAD")
        let alternate = try await world.b.bareClone("alternate.git")
        try await world.a.git("remote", "add", "alternate", alternate)
        try await world.handleA.pullBranch(
            "main", remote: "alternate", remoteBranch: "main", context: .anonymous,
            expected: world.handleA.captureState())
        #expect(try await world.a.git("rev-parse", "HEAD") == incoming)
        #expect(try await world.a.git("rev-parse", "--abbrev-ref", "main@{upstream}") == "origin/main")
    }

    @Test func fastForwardRefusesToLoseCommits() async throws {
        let (_, repo, handle) = try await Ops.single()
        let first = try await repo.git("rev-parse", "HEAD")
        try await repo.branch("topic")
        try await repo.commit("Second")
        let head = try await repo.git("rev-parse", "HEAD")
        try await handle.fastForwardBranch("topic", to: head, expected: handle.captureState())
        #expect(try await repo.git("rev-parse", "topic") == head)
        await #expect(throws: GitCoreError.self) {
            try await handle.fastForwardBranch("topic", to: first, expected: nil)
        }
        #expect(try await repo.git("rev-parse", "topic") == head)
    }

    @Test func resetNeedsMatchingConfirmationAndCurrentSnapshot() async throws {
        let (_, repo, handle) = try await Ops.single()
        let first = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("Second")
        let preview = try await handle.resetPreview(to: first, mode: .soft)
        let hard = try await handle.resetPreview(to: first, mode: .hard)
        let wrong = confirmation(preview.confirmationAction(stashFirst: false))
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.reset(hard, token: wrong)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        _ = try await handle.reset(preview, token: wrong)
        #expect(try await repo.git("rev-parse", "HEAD") == first)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.reset(preview, token: wrong)
        }
    }

    @Test func worktreeAndPatchUseTheChosenCommit() async throws {
        let (sandbox, repo, handle) = try await Ops.single()
        try repo.write("added.txt", "new\n")
        try await repo.commit("Patch subject")
        let chosen = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("Later")
        let patch = String(decoding: try await handle.commitPatch(chosen), as: UTF8.self)
        #expect(patch.contains("Patch subject"))
        #expect(patch.contains("added.txt"))
        let path = sandbox.root + "/new worktree"
        try await handle.createWorktree(at: path, commit: chosen, expected: handle.captureState())
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: path) == chosen)
        #expect(FileManager.default.fileExists(atPath: path + "/added.txt"))
    }

    @Test func mergePatchContainsChangesFromTheOtherBranch() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.git("switch", "-c", "topic")
        try repo.write("topic.txt", "Topic\n")
        try await repo.commit("Topic changes")
        try await repo.git("switch", "main")
        try await repo.git("merge", "--no-ff", "topic", "-m", "Merge topic")
        let commit = try await repo.git("rev-parse", "HEAD")
        let patch = String(decoding: try await handle.commitPatch(commit), as: UTF8.self)
        #expect(patch.contains("topic.txt"))
        #expect(patch.contains("+Topic"))
    }

    @Test func emptyCommitPatchDoesNotExportAnEarlierCommit() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.commit("Selected empty commit")
        let commit = try await repo.git("rev-parse", "HEAD")
        let patch = String(decoding: try await handle.commitPatch(commit), as: UTF8.self)
        #expect(patch.contains("Selected empty commit"))
        #expect(!patch.contains("Subject: [PATCH] Initial"))
    }

    @Test func combinedDeleteUsesLeaseAndRejectsActiveLocalBranch() async throws {
        let world = try await Ops.world()
        try await world.a.git("push", "-q", "origin", "HEAD:refs/heads/topic")
        try await world.a.git("fetch", "-q")
        try await world.a.git("branch", "--track", "topic", "origin/topic")
        let tip = try await world.a.git("rev-parse", "topic")
        let token = confirmation(.deleteLocalAndRemoteBranch(branch: "topic", remote: "origin", remoteBranch: "topic"))
        try await world.handleA.deleteLocalAndRemoteBranch(
            "topic", remote: "origin", remoteBranch: "topic", remoteTip: tip,
            token: token, context: .anonymous, expected: world.handleA.captureState())
        #expect((try? await world.a.git("rev-parse", "--verify", "refs/heads/topic")) == nil)
        #expect(try await world.a.git("ls-remote", "origin", "refs/heads/topic").isEmpty)
        let mainToken = confirmation(
            .deleteLocalAndRemoteBranch(branch: "main", remote: "origin", remoteBranch: "main"))
        await #expect(throws: GitCoreError.self) {
            try await world.handleA.deleteLocalAndRemoteBranch(
                "main", remote: "origin", remoteBranch: "main", remoteTip: tip,
                token: mainToken, context: .anonymous, expected: world.handleA.captureState())
        }
        #expect(try await world.a.git("ls-remote", "origin", "refs/heads/main").contains(tip))
    }
}
