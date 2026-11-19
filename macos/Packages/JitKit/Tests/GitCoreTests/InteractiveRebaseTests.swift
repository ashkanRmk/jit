import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct InteractiveRebaseTests {
    final class Marker {}
    static var helper: String {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("jit-git-helper").path
    }

    func fixture() async throws -> (GitSandbox, TestRepo, RepositoryHandle, String) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("base.txt", "base\n")
        let base = try await repo.commit("Base")
        for name in ["A", "B", "C"] {
            try repo.write(name + ".txt", name + "\n")
            try await repo.commit(name)
        }
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return (sandbox, repo, handle, base)
    }

    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(
            action: action, title: "test", context: "test", changes: "", recoverability: "", verb: "Run"
        ).confirm()
    }

    func run(_ plan: InteractiveRebasePlan, _ handle: RepositoryHandle) async throws -> IntegrationOutcome {
        try await handle.startInteractiveRebase(
            plan, token: plan.confirmation(context: "test").confirm(), helperPath: Self.helper, context: Ops.context)
    }

    @Test func reorderAndRewordPreservesTreeAuthorsAndOtherRefs() async throws {
        let (_, repo, handle, base) = try await fixture()
        try await repo.git("branch", "stacked", "HEAD~1")
        let stacked = try await repo.git("rev-parse", "stacked")
        let tree = try await repo.git("rev-parse", "HEAD^{tree}")
        var plan = try await handle.interactiveRebasePlan(after: base)
        #expect(plan.commits.map(\.subject) == ["A", "B", "C"])
        plan.steps.swapAt(0, 1)
        plan.steps[0].action = .reword
        plan.steps[0].message = "B's \"new\" message $() `touch nope`\n\nسلام 👋\n# literal line"
        _ = try await run(plan, handle)
        #expect(try await repo.git("log", "--reverse", "--format=%s", base + "..HEAD").hasPrefix("B's"))
        #expect(try await repo.git("show", "-s", "--format=%B", "HEAD~2") == plan.steps[0].message)
        #expect(try await repo.git("rev-parse", "HEAD^{tree}") == tree)
        #expect(try await repo.git("rev-parse", "stacked") == stacked)
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%ce") == "Jit Tests|Ada Lovelace|ada@profile.example")
        #expect(try await handle.operationState() == .clean)
        #expect(!FileManager.default.fileExists(atPath: handle.info.gitDirectory + "/jit-interactive-rebase"))
        #expect(await handle.recoveryPoints.contains { $0.operation == "Interactive rebase" })
    }

    @Test(arguments: [false, true]) func squashAndFixupMessages(fixupLast: Bool) async throws {
        let (_, repo, handle, base) = try await fixture()
        var plan = try await handle.interactiveRebasePlan(after: base)
        plan.steps[1].action = .squash
        plan.steps[1].message = "Combined A and B\n\nCustom message"
        plan.steps[2].action = fixupLast ? .fixup : .squash
        plan.steps[2].message = "All three combined"
        _ = try await run(plan, handle)
        #expect(try await repo.git("rev-list", "--count", base + "..HEAD") == "1")
        #expect(
            try await repo.git("log", "-1", "--format=%B")
                == (fixupLast ? plan.steps[1].message : plan.steps[2].message))
        #expect(try Ops.read(repo, "C.txt") == "C\n")
    }

    @Test func fixupDiscardsMessageAndDropRemovesChanges() async throws {
        let (_, repo, handle, base) = try await fixture()
        var plan = try await handle.interactiveRebasePlan(after: base)
        plan.steps[1].action = .fixup
        plan.steps[2].action = .drop
        _ = try await run(plan, handle)
        #expect(try await repo.git("log", "-1", "--format=%B") == "A")
        #expect(try await repo.git("rev-list", "--count", base + "..HEAD") == "1")
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/C.txt"))
        #expect(try Ops.read(repo, "B.txt") == "B\n")
    }

    @Test func allDropMovesBranchToBase() async throws {
        let (_, repo, handle, base) = try await fixture()
        var plan = try await handle.interactiveRebasePlan(after: base)
        for index in plan.steps.indices { plan.steps[index].action = .drop }
        _ = try await run(plan, handle)
        #expect(try await repo.git("rev-parse", "HEAD") == base)
    }

    @Test func editStopRelaunchAndContinueAfterAmend() async throws {
        let (sandbox, repo, handle, base) = try await fixture()
        var plan = try await handle.interactiveRebasePlan(after: base)
        plan.steps[0].action = .edit
        plan.steps[2].action = .reword
        plan.steps[2].message = "C after restart"
        guard case .stoppedInProgress = try await run(plan, handle) else {
            Issue.record("Expected edit stop"); return
        }
        #expect(try await handle.rebaseIsStoppedForEdit())
        try repo.write("amended.txt", "edit\n")
        try await repo.git("add", "amended.txt")
        try await repo.git("commit", "--amend", "--no-edit")
        let reopened = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        #expect(try await reopened.continueOperation(context: .anonymous, helperPath: Self.helper) == .finished)
        #expect(try await repo.git("log", "-1", "--format=%s") == "C after restart")
        #expect(try await repo.git("log", "-1", "--format=%cn") == "Ada Lovelace")
        #expect(try Ops.read(repo, "amended.txt") == "edit\n")
    }

    func conflicting() async throws -> (GitSandbox, TestRepo, RepositoryHandle, InteractiveRebasePlan) {
        let (sandbox, repo, handle, base) = try await fixture()
        try await repo.git("branch", "feature")
        try await repo.git("switch", "-c", "onto", base)
        try repo.write("A.txt", "onto\n")
        let onto = try await repo.commit("Conflicting onto")
        try await repo.git("switch", "feature")
        var plan = try await handle.interactiveRebasePlan(after: base, onto: onto)
        plan.steps[0].action = .reword
        plan.steps[0].message = "A resolved message"
        plan.steps[2].action = .reword
        plan.steps[2].message = "C unaffected by extra editor calls"
        return (sandbox, repo, handle, plan)
    }

    @Test func conflictThenContinueUsesCorrectPreparedMessages() async throws {
        let (_, repo, handle, plan) = try await conflicting()
        #expect(try await run(plan, handle) == .stoppedWithConflicts(paths: ["A.txt"]))
        try repo.write("A.txt", "resolved\n")
        try await repo.git("add", "A.txt")
        _ = try await handle.continueOperation(context: Ops.context, helperPath: Self.helper)
        #expect(try await handle.operationState() == .clean)
        #expect(try await repo.git("log", "-1", "--format=%s") == plan.steps[2].message)
        #expect(try await repo.git("log", "-1", "--format=%s", "HEAD~2") == plan.steps[0].message)
    }

    @Test func conflictAbortRestoresOriginalStateAndPrivateFiles() async throws {
        let (_, repo, handle, plan) = try await conflicting()
        let before = try await RepoFingerprint.capture(repo)
        _ = try await run(plan, handle)
        let folder = handle.info.gitDirectory + "/jit-interactive-rebase"
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        for name in ["manifest.json", "todo"] {
            #expect(
                try FileManager.default.attributesOfItem(atPath: folder + "/" + name)[.posixPermissions] as? Int
                    == 0o600)
        }
        try await handle.abortOperation(token: confirm(.abortOperation), expected: try await handle.captureState())
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    @Test func skipAfterRestartDoesNotConsumeLaterMessage() async throws {
        let (_, repo, handle, plan) = try await conflicting()
        _ = try await run(plan, handle)
        _ = try await handle.skipCurrent(
            context: Ops.context, token: confirm(.skipCurrent), expected: try await handle.captureState(),
            helperPath: Self.helper)
        #expect(try await repo.git("log", "-1", "--format=%s") == plan.steps[2].message)
        #expect(try Ops.read(repo, "A.txt") == "onto\n")
    }

    @Test func rejectsInvalidPlansAndChangedConfirmation() async throws {
        let (sandbox, _, handle, base) = try await fixture()
        defer { withExtendedLifetime(sandbox) {} }
        var plan = try await handle.interactiveRebasePlan(after: base)
        plan.steps[0].action = .squash
        #expect(!plan.validationIssues.isEmpty)
        await #expect(throws: GitCoreError.self) { _ = try await run(plan, handle) }
        plan.steps[0].action = .reword
        plan.steps[0].message = "  \n"
        #expect(!plan.validationIssues.isEmpty)
        plan.steps[0].message = "Valid"
        let token = plan.confirmation(context: "test").confirm()
        plan.steps.swapAt(0, 1)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.startInteractiveRebase(
                plan, token: token, helperPath: Self.helper, context: Ops.context)
        }
        plan.steps[0] = plan.steps[1]
        #expect(!plan.validationIssues.isEmpty)
    }

    @Test func stalePlanAndDirtyTreeRefusedWithoutMutation() async throws {
        let (_, repo, handle, base) = try await fixture()
        let plan = try await handle.interactiveRebasePlan(after: base)
        try repo.write("A.txt", "dirty\n")
        let dirty = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { _ = try await run(plan, handle) }
        #expect(try await RepoFingerprint.capture(repo) == dirty)
        try await repo.commit("New commit")
        let changed = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { _ = try await run(plan, handle) }
        #expect(try await RepoFingerprint.capture(repo) == changed)
    }

    @Test func planRefusesMergesAndNonAncestorAndDetectsPublishedCommits() async throws {
        let (_, repo, handle, base) = try await fixture()
        try await repo.git("update-ref", "refs/remotes/other/published", "HEAD~1")
        #expect(try await handle.interactiveRebasePlan(after: base).publishedCount == 2)
        try await repo.git("switch", "-c", "side", base)
        try repo.write("side.txt", "side\n")
        let side = try await repo.commit("Side")
        try await repo.git("switch", "main")
        await #expect(throws: GitCoreError.self) { _ = try await handle.interactiveRebasePlan(after: side) }
        try await repo.git("merge", "--no-ff", "side", "-m", "Merge")
        await #expect(throws: GitCoreError.self) { _ = try await handle.interactiveRebasePlan(after: base) }
    }

    @Test func helperPathWithQuotesAndShellSyntaxIsLiteral() async throws {
        let (sandbox, repo, handle, base) = try await fixture()
        let helper = sandbox.root + "/jit helper ' $(touch sentinel)"
        try FileManager.default.copyItem(atPath: Self.helper, toPath: helper)
        var plan = try await handle.interactiveRebasePlan(after: base)
        plan.steps[0].action = .reword
        plan.steps[0].message = "literal $(touch sentinel) `touch sentinel`"
        _ = try await handle.startInteractiveRebase(
            plan, token: plan.confirmation(context: "test").confirm(), helperPath: helper, context: Ops.context)
        #expect(try await repo.git("log", "-1", "--format=%s", "HEAD~2") == plan.steps[0].message)
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/sentinel"))
    }

    @Test func missingHelperRefusesContinueButAbortRemainsAvailable() async throws {
        let (_, repo, handle, plan) = try await conflicting()
        _ = try await run(plan, handle)
        try repo.write("A.txt", "resolved\n")
        try await repo.git("add", "A.txt")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) { _ = try await handle.continueOperation(context: Ops.context) }
        #expect(try await RepoFingerprint.capture(repo) == before)
        try await handle.abortOperation(token: confirm(.abortOperation), expected: try await handle.captureState())
        #expect(try await repo.git("rev-parse", "HEAD") == plan.expected.head)
    }

    @Test func emptyCommitsAreKeptAndNewlyEmptyStepStops() async throws {
        let (_, repo, handle, base) = try await fixture()
        try await repo.commit("Initially empty")
        var plan = try await handle.interactiveRebasePlan(after: base)
        _ = try await run(plan, handle)
        #expect(try await repo.git("rev-list", "--count", base + "..HEAD") == "4")
        try await repo.git("branch", "feature")
        try await repo.git("switch", "-c", "equivalent", base)
        try repo.write("A.txt", "A\n")
        let onto = try await repo.commit("Equivalent A")
        try await repo.git("switch", "feature")
        plan = try await handle.interactiveRebasePlan(after: base, onto: onto)
        guard case .stoppedInProgress = try await run(plan, handle) else {
            Issue.record("Expected newly-empty stop"); return
        }
        #expect(try await handle.operationState().isDrivable)
        _ = try await handle.skipCurrent(
            context: .anonymous, token: confirm(.skipCurrent), expected: try await handle.captureState(),
            helperPath: Self.helper)
        #expect(try await handle.operationState() == .clean)
    }

    @Test func tenCommitWorkflowReordersSquashesDropsAndResolvesConflict() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let base = try await repo.commit("Base")
        for index in 1...10 {
            try repo.write("file\(index).txt", "feature \(index)\n")
            try await repo.commit("Commit \(index)")
        }
        try await repo.git("branch", "feature")
        try await repo.git("switch", "-c", "onto", base)
        try repo.write("file1.txt", "onto\n")
        let onto = try await repo.commit("Onto")
        try await repo.git("switch", "feature")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        var plan = try await handle.interactiveRebasePlan(after: base, onto: onto)
        plan.steps.swapAt(1, 2)
        plan.steps[1].action = .reword; plan.steps[1].message = "Reordered three"
        plan.steps[3].action = .squash; plan.steps[3].message = "Two and four combined"
        plan.steps[5].action = .drop
        #expect(try await run(plan, handle) == .stoppedWithConflicts(paths: ["file1.txt"]))
        try repo.write("file1.txt", "resolved\n")
        try await handle.stage(["file1.txt"])
        _ = try await handle.continueOperation(context: .anonymous, helperPath: Self.helper)
        #expect(try await handle.operationState() == .clean)
        #expect(try await repo.git("rev-list", "--count", onto + "..HEAD") == "8")
        #expect(
            try await repo.git("log", "--reverse", "--format=%s", onto + "..HEAD").hasPrefix(
                "Commit 1\nReordered three\nTwo and four combined"))
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/file6.txt"))
    }

    @Test func fiftyCommitPlanPerformanceAndBoundedRange() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let base = try await repo.commit("Base")
        for index in 1...50 {
            try repo.write("file\(index).txt", "\(index)\n")
            try await repo.commit("Commit \(index)")
        }
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let start = ContinuousClock.now
        let plan = try await handle.interactiveRebasePlan(after: base)
        let elapsed = ContinuousClock.now - start
        print("Interactive rebase plan, 50 commits: \(elapsed)")
        #expect(plan.commits.count == 50 && plan.resultCount == 50)
        #expect(plan.commits.allSatisfy { $0.diffstat.contains("1 file") })
    }

    @Test func reorderedChangesToSamePathShowRiskAndDroppedChangesDoNot() async throws {
        let (_, repo, handle, base) = try await fixture()
        try repo.write("A.txt", "later edit\n")
        try await repo.commit("Edit A again")
        var plan = try await handle.interactiveRebasePlan(after: base)
        #expect(plan.reorderConflictPaths.isEmpty)
        plan.steps.swapAt(0, 3)
        #expect(plan.reorderConflictPaths == ["A.txt"])
        plan.steps[0].action = .drop
        #expect(plan.reorderConflictPaths.isEmpty)
    }

}
