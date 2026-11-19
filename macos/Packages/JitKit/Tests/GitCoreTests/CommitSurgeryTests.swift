import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct CommitSurgeryTests {
    func run(_ plan: CommitSurgeryPlan, _ handle: RepositoryHandle) async throws -> IntegrationOutcome {
        try await handle.applyCommitSurgery(
            plan, token: plan.confirmation(context: "test").confirm(),
            helperPath: InteractiveRebaseTests.helper, context: Ops.context)
    }

    @Test(arguments: [false, true]) func rewordPreservesTreeAuthorAndOtherRefs(head: Bool) async throws {
        let (_, repo, handle, _) = try await InteractiveRebaseTests().fixture()
        let oid = try await repo.git("rev-parse", head ? "HEAD" : "HEAD~1")
        try await repo.git("branch", "unchanged", "HEAD")
        let old = try await repo.git("rev-parse", "HEAD")
        let tree = try await repo.git("rev-parse", "HEAD^{tree}")
        var plan = try await handle.commitSurgeryPlan(for: oid, action: .editMessage)
        #expect(plan.usesAmend == head)
        plan.message = "Literal '$()' `touch nope`\n\nسلام 👋\n# keep this line"
        plan.message += "\n\n"
        _ = try await run(plan, handle)
        let raw = try await repo.sandbox.engine.run(
            GitCommand(["cat-file", "commit", head ? "HEAD" : "HEAD~1"], in: repo.path))
        let separator = try #require(
            raw.stdout.indices.dropLast().first {
                raw.stdout[$0] == 10 && raw.stdout[$0 + 1] == 10
            })
        #expect(Array(raw.stdout[(separator + 2)...]) == Array(plan.message.utf8))
        #expect(try await repo.git("rev-parse", "HEAD^{tree}") == tree)
        #expect(try await repo.git("rev-parse", "unchanged") == old)
        #expect(try await repo.git("log", "-1", "--format=%an|%cn") == "Jit Tests|Ada Lovelace")
        #expect(await handle.recoveryPoints.contains { $0.oldOID == old && $0.operation == plan.action.title })
    }

    @Test(arguments: [false, true]) func dropRemovesOnlySelectedChangeAndRetainsRecovery(head: Bool) async throws {
        let (_, repo, handle, base) = try await InteractiveRebaseTests().fixture()
        let old = try await repo.git("rev-parse", "HEAD")
        let oid = try await repo.git("rev-parse", head ? "HEAD" : "HEAD~1")
        let plan = try await handle.commitSurgeryPlan(for: oid, action: .drop)
        _ = try await run(plan, handle)
        #expect(try await repo.git("rev-list", "--count", base + "..HEAD") == "2")
        #expect(!FileManager.default.fileExists(atPath: repo.path + (head ? "/C.txt" : "/B.txt")))
        #expect(try await repo.git("reflog", "show", "--format=%H").contains(old))
        #expect(await handle.recoveryPoints.contains { $0.oldOID == old && $0.operation == plan.action.title })
        try await repo.git("branch", "recovered", old)
        #expect(try await repo.git("show", "recovered:B.txt") == "B")
        #expect(try await repo.git("show", "recovered:C.txt") == "C")
    }

    @Test func rootHeadCanBeRewordedButNotDropped() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let root = try await repo.commit("Empty root")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        var plan = try await handle.commitSurgeryPlan(for: root, action: .editMessage)
        plan.message = "New empty root"
        _ = try await run(plan, handle)
        #expect(try await repo.git("rev-list", "--count", "HEAD") == "1")
        #expect(try await repo.git("log", "-1", "--format=%P").isEmpty)
        await #expect(throws: GitCoreError.self) { try await handle.commitSurgeryPlan(for: root, action: .drop) }
    }

    @Test func mergeHeadAmendPreservesParentsButOlderMergeRangeRefused() async throws {
        let (_, repo, handle, base) = try await InteractiveRebaseTests().fixture()
        try await repo.git("checkout", "-b", "side", base)
        try repo.write("side.txt", "side\n")
        try await repo.commit("Side")
        try await repo.git("checkout", "main")
        try await repo.git("merge", "--no-ff", "side", "-m", "Merge")
        let parents = try await repo.git("log", "-1", "--format=%P")
        var plan = try await handle.commitSurgeryPlan(
            for: try await repo.git("rev-parse", "HEAD"), action: .editMessage)
        plan.message = "Merge with clearer message"
        _ = try await run(plan, handle)
        #expect(try await repo.git("log", "-1", "--format=%P") == parents)
        await #expect(throws: GitCoreError.self) {
            try await handle.commitSurgeryPlan(for: try await repo.git("rev-parse", "HEAD~2"), action: .drop)
        }
    }

    @Test(arguments: [false, true]) func staleDirtyAndChangedConfirmationRefuseWithoutMutation(head: Bool) async throws
    {
        let (_, repo, handle, _) = try await InteractiveRebaseTests().fixture()
        var plan = try await handle.commitSurgeryPlan(
            for: try await repo.git("rev-parse", "HEAD"), action: .editMessage)
        if !head {
            plan = try await handle.commitSurgeryPlan(
                for: try await repo.git("rev-parse", "HEAD~1"), action: .editMessage)
        }
        let token = plan.confirmation(context: "test").confirm()
        plan.message = "Changed after confirmation"
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            try await handle.applyCommitSurgery(plan, token: token, helperPath: "", context: Ops.context)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        try repo.write("C.txt", "dirty\n")
        let dirty = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { try await run(plan, handle) }
        #expect(try await RepoFingerprint.capture(repo) == dirty)
        try await repo.git("restore", "C.txt")
        try await repo.git("branch", "new-ref")
        let stale = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { try await run(plan, handle) }
        #expect(try await RepoFingerprint.capture(repo) == stale)
    }

    @Test func offBranchDetachedPublishedAndInvalidMessages() async throws {
        let (_, repo, handle, base) = try await InteractiveRebaseTests().fixture()
        let head = try await repo.git("rev-parse", "HEAD")
        try await repo.git("update-ref", "refs/remotes/origin/main", head)
        var plan = try await handle.commitSurgeryPlan(for: head, action: .editMessage)
        #expect(plan.publishedCount == 1)
        #expect(!plan.confirmation(context: "test").losses.isEmpty)
        for message in [" \n", "bad\0message", String(repeating: "x", count: 1024 * 1024 + 1)] {
            plan.message = message
            await #expect(throws: GitCoreError.self) { try await run(plan, handle) }
        }
        try await repo.git("switch", "-c", "other", base)
        let other = try await repo.commit("Other")
        try await repo.git("switch", "main")
        await #expect(throws: GitCoreError.self) { try await handle.commitSurgeryPlan(for: other, action: .drop) }
        try await repo.git("checkout", "--detach", head)
        await #expect(throws: GitCoreError.self) { try await handle.commitSurgeryPlan(for: head, action: .editMessage) }
    }

    @Test func stagedChangesAreRefusedAndUntrackedFilesSurviveHeadEdit() async throws {
        let (_, repo, handle, _) = try await InteractiveRebaseTests().fixture()
        var plan = try await handle.commitSurgeryPlan(
            for: try await repo.git("rev-parse", "HEAD"), action: .editMessage)
        plan.message = "Only the message changes"
        try repo.write("C.txt", "staged\n")
        try await repo.git("add", "C.txt")
        let staged = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { try await run(plan, handle) }
        #expect(try await RepoFingerprint.capture(repo) == staged)
        try await repo.git("restore", "--staged", "C.txt")
        try await repo.git("restore", "C.txt")
        try repo.write("untracked.txt", "keep me\n")
        _ = try await run(plan, handle)
        #expect(try Ops.read(repo, "untracked.txt") == "keep me\n")
        #expect(try Ops.read(repo, "C.txt") == "C\n")
    }

    @Test func amendRunsCommitMessageHooksAndRefusalKeepsHead() async throws {
        let (_, repo, handle, _) = try await InteractiveRebaseTests().fixture()
        var plan = try await handle.commitSurgeryPlan(
            for: try await repo.git("rev-parse", "HEAD"), action: .editMessage)
        plan.message = "Rejected by hook"
        let hook = repo.path + "/.git/hooks/commit-msg"
        try "#!/bin/sh\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { try await run(plan, handle) }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func dropConflictAbortRestoresOriginalHistoryAndTree() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("shared.txt", "base\n")
        try await repo.commit("Base")
        try repo.write("shared.txt", "first\n")
        let dropped = try await repo.commit("First edit")
        try repo.write("shared.txt", "second\n")
        try await repo.commit("Dependent edit")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let plan = try await handle.commitSurgeryPlan(for: dropped, action: .drop)
        let before = try await RepoFingerprint.capture(repo)
        #expect(try await run(plan, handle) == .stoppedWithConflicts(paths: ["shared.txt"]))
        try await handle.abortOperation(
            token: InteractiveRebaseTests().confirm(.abortOperation), expected: try await handle.captureState())
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(!FileManager.default.fileExists(atPath: handle.info.gitDirectory + "/jit-interactive-rebase"))
    }

    @Test func fiftyCommitDirectPlanPreparation() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("Base")
        let first = try await repo.commit("Selected")
        for index in 1..<50 { try await repo.commit("Later \(index)") }
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        for action in [CommitSurgeryAction.editMessage, .drop] {
            let start = ContinuousClock.now
            let plan = try await handle.commitSurgeryPlan(for: first, action: action)
            print("Direct \(action.title) plan, 50 commits: \(ContinuousClock.now - start)")
            #expect(plan.affectedCount == 50 && plan.descendantCount == 49)
            #expect(plan.generatedRebase?.steps.first?.action == (action == .drop ? .drop : .reword))
            #expect(plan.generatedRebase?.steps.dropFirst().allSatisfy { $0.action == .pick } == true)
        }
    }

    @Test(arguments: [false, true]) func planCannotMutateAnotherRepositoryWithIdenticalRefs(head: Bool) async throws {
        let (sandbox, repo, handle, _) = try await InteractiveRebaseTests().fixture()
        let copyPath = sandbox.root + "/same-history"
        try FileManager.default.copyItem(atPath: repo.path, toPath: copyPath)
        let copy = TestRepo(sandbox: sandbox, path: copyPath)
        let other = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: copyPath))
        var plan = try await handle.commitSurgeryPlan(
            for: try await repo.git("rev-parse", head ? "HEAD" : "HEAD~1"), action: .editMessage)
        plan.message = "Must stay in the originating worktree"
        #expect(try await other.captureState() == plan.expected)
        let before = try await RepoFingerprint.capture(copy)
        await #expect(throws: GitCoreError.self) { try await run(plan, other) }
        #expect(try await RepoFingerprint.capture(copy) == before)
    }
}
