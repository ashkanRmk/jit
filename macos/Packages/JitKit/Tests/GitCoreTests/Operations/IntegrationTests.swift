import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// P4.9–P4.10 — merge, rebase, cherry-pick, revert, continue / skip / abort.
@Suite struct IntegrationTests {
    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(action: action, title: "", context: "", changes: "", recoverability: "", verb: "OK")
            .confirm()
    }

    /// `main` plus `feature` with one non-conflicting commit.
    func diverged() async throws -> (GitSandbox, TestRepo, RepositoryHandle) {
        let (sandbox, repo, handle) = try await Ops.single()
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "feature\n")
        try await repo.commit("Feature")
        try await repo.git("switch", "-q", "main")
        try repo.write("m.txt", "main\n")
        try await repo.commit("Main")
        return (sandbox, repo, handle)
    }

    @Test func mergeFF() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.git("switch", "-q", "-c", "feature")
        let tip = try await repo.commit("Ahead")
        try await repo.git("switch", "-q", "main")
        let outcome = try await handle.merge(MergeRequest(source: "feature"), context: Ops.context, expected: nil)
        guard case .fastForwarded(_, let to) = outcome else {
            Issue.record("expected fast-forward, got \(outcome)")
            return
        }
        #expect(to == tip)
    }

    @Test func mergeNoFFIdentityFromProfile() async throws {
        let (_, repo, handle) = try await diverged()
        let outcome = try await handle.merge(
            MergeRequest(source: "feature", strategy: .noFastForward), context: Ops.context, expected: nil)
        guard case .merged(let commit) = outcome else {
            Issue.record("expected merge commit, got \(outcome)")
            return
        }
        #expect(
            try await repo.git("log", "-1", "--format=%an <%ae>|%cn <%ce>", commit)
                == "Ada Lovelace <ada@profile.example>|Ada Lovelace <ada@profile.example>")
        #expect(try await repo.git("log", "-1", "--format=%s", commit) == "Merge branch 'feature'")
    }

    @Test func mergeCustomMessage() async throws {
        let (_, repo, handle) = try await diverged()
        _ = try await handle.merge(
            MergeRequest(source: "feature", strategy: .noFastForward, message: "Bring in feature"),
            context: Ops.context,
            expected: nil)
        #expect(try await repo.git("log", "-1", "--format=%s") == "Bring in feature")
    }

    @Test func mergeFFOnlyRefuses() async throws {
        let (_, repo, handle) = try await diverged()
        let before = try await RepoFingerprint.capture(repo)
        let outcome = try await handle.merge(
            MergeRequest(source: "feature", strategy: .fastForwardOnly), context: Ops.context, expected: nil)
        #expect(outcome == .notFastForward(ahead: 1, behind: 1))
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func mergeConflictState() async throws {
        let (sandbox, _, handle) = try await Ops.conflicting()
        defer { withExtendedLifetime(sandbox) {} }
        let outcome = try await handle.merge(MergeRequest(source: "feature"), context: Ops.context, expected: nil)
        #expect(outcome == .stoppedWithConflicts(paths: ["a.txt"]))
        #expect(try await handle.operationState() == .merging(source: "feature", conflicted: 1))
        // Continue is refused while unmerged paths remain.
        await #expect(throws: GitCoreError.self) { _ = try await handle.continueOperation(context: Ops.context) }
    }

    @Test func mergeAbortRestoresFingerprint() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        let before = try await RepoFingerprint.capture(repo)
        _ = try await handle.merge(MergeRequest(source: "feature"), context: Ops.context, expected: nil)
        #expect(try await RepoFingerprint.capture(repo) != before)
        try await handle.abortOperation(token: confirm(.abortOperation))
        let after = try await RepoFingerprint.capture(repo)
        #expect(after == before, "\(after.difference(from: before))")
    }

    @Test func mergeContinueCreatesCommitWithProfile() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        _ = try await handle.merge(MergeRequest(source: "feature"), context: Ops.context, expected: nil)
        try repo.write("a.txt", "one\nresolved\nthree\n")
        try await repo.git("add", "a.txt")
        let outcome = try await handle.continueOperation(context: Ops.context)
        #expect(outcome == .finished)
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%P").split(separator: "|")[0] == "Ada Lovelace")
        #expect(try await repo.git("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ").count == 3)
    }

    @Test func mergeWithUnrelatedDirtyChangesPreserved() async throws {
        let (_, repo, handle) = try await diverged()
        try repo.write("dirty.txt", "mine\n")
        try repo.write("a.txt", "one\ntwo\nthree\nlocal edit\n")
        _ = try await handle.merge(
            MergeRequest(source: "feature", strategy: .noFastForward), context: Ops.context, expected: nil)
        #expect(try Ops.read(repo, "dirty.txt") == "mine\n")
        #expect(try Ops.read(repo, "a.txt") == "one\ntwo\nthree\nlocal edit\n")
    }

    @Test func predictMergeConflictsWithMergeTree() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        let before = try await RepoFingerprint.capture(repo)
        #expect(try await handle.predictMergeConflicts(source: "feature") == ["a.txt"])
        #expect(try await RepoFingerprint.capture(repo) == before)
        let (cleanSandbox, _, clean) = try await diverged()
        defer { withExtendedLifetime(cleanSandbox) {} }
        #expect(try await clean.predictMergeConflicts(source: "feature") == [])
    }

    @Test func rebaseCleanReplaysWithProfileCommitterAndOriginalAuthor() async throws {
        let (_, repo, handle) = try await diverged()
        try await repo.git("switch", "-q", "feature")
        let plan = try await handle.rebasePlan(onto: "main")
        #expect(plan.commits.map(\.subject) == ["Feature"])
        let outcome = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
        #expect(outcome == .rebased(count: 1))
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%s") == "Jit Tests|Ada Lovelace|Feature")
        #expect(try await repo.git("rev-parse", "HEAD~1") == (try await repo.git("rev-parse", "main")))
    }

    @Test func rebaseConflictStateStepCounts() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        try repo.write("z.txt", "z\n")
        try await repo.commit("Second feature commit")
        let outcome = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
        #expect(outcome == .stoppedWithConflicts(paths: ["a.txt"]))
        guard case let .rebasing(headName, _, step, total, stopped, _) = try await handle.operationState() else {
            Issue.record("not rebasing")
            return
        }
        #expect(headName == "feature")
        #expect(step == 1 && total == 2)
        #expect(stopped?.subject == "Feature edit")
        let labels = ConflictLabels.make(for: try await handle.operationState(), currentBranch: nil)
        #expect(labels.theirs.contains("Your commit"))
        #expect(labels.explanation != nil)
    }

    @Test func rebaseContinueAfterResolution() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        _ = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
        try repo.write("a.txt", "one\nmerged\nthree\n")
        try await repo.git("add", "a.txt")
        let outcome = try await handle.continueOperation(context: Ops.context)
        #expect(outcome == .finished)
        #expect(try await handle.operationState() == .clean)
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%s") == "Jit Tests|Ada Lovelace|Feature edit")
    }

    @Test func rebaseSkipDropsCommit() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        let main = try await repo.git("rev-parse", "main")
        _ = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.skipCurrent(context: Ops.context, token: confirm(.abortOperation))
        }
        let outcome = try await handle.skipCurrent(context: Ops.context, token: confirm(.skipCurrent))
        #expect(outcome == .finished)
        #expect(try await repo.git("rev-parse", "HEAD") == main)
    }

    @Test func rebaseAbortRestoresFingerprint() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        let before = try await RepoFingerprint.capture(repo)
        _ = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
        try await handle.abortOperation(token: confirm(.abortOperation))
        let after = try await RepoFingerprint.capture(repo)
        #expect(after == before, "\(after.difference(from: before))")
    }

    @Test func rebaseRequiresCleanTree() async throws {
        let (_, repo, handle) = try await diverged()
        try await repo.git("switch", "-q", "feature")
        try repo.write("a.txt", "dirty\n")
        let before = try await RepoFingerprint.capture(repo)
        do {
            _ = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
            Issue.record("rebase with a dirty tree must be refused")
        } catch .failed(let failure) {
            #expect(failure.kind == .dirtyWorkingTree)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func rebaseIgnoresAutostashConfig() async throws {
        let (_, repo, handle) = try await diverged()
        try await repo.git("switch", "-q", "feature")
        try await repo.git("config", "rebase.autoStash", "true")
        try repo.write("a.txt", "dirty\n")
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.rebase(onto: "main", context: Ops.context, expected: nil)
        }
        #expect(try await repo.git("stash", "list") == "")
        #expect(try Ops.read(repo, "a.txt") == "dirty\n")
    }

    @Test func cherryPickPreservesAuthorSetsCommitter() async throws {
        let (_, repo, handle) = try await diverged()
        let pick = try await repo.git("rev-parse", "feature")
        let outcome = try await handle.cherryPick([pick], context: Ops.context, expected: nil)
        guard case .committed = outcome else {
            Issue.record("expected commit, got \(outcome)")
            return
        }
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%s") == "Jit Tests|Ada Lovelace|Feature")
    }

    @Test func cherryPickMultiOrder() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("1.txt", "1\n")
        let first = try await repo.commit("First")
        try repo.write("2.txt", "2\n")
        let second = try await repo.commit("Second")
        try await repo.git("switch", "-q", "main")
        // Selected newest first: applied oldest → newest anyway.
        _ = try await handle.cherryPick([second, first], context: Ops.context, expected: nil)
        #expect(try await repo.git("log", "-2", "--format=%s") == "Second\nFirst")
    }

    @Test func cherryPickConflictContinue() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        let pick = try await repo.git("rev-parse", "feature")
        #expect(
            try await handle.cherryPick([pick], context: Ops.context, expected: nil)
                == .stoppedWithConflicts(paths: ["a.txt"]))
        try repo.write("a.txt", "one\nboth\nthree\n")
        try await repo.git("add", "a.txt")
        #expect(try await handle.continueOperation(context: Ops.context) == .finished)
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%s") == "Jit Tests|Ada Lovelace|Feature edit")
    }

    @Test func cherryPickAbortRestoresFingerprint() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        let before = try await RepoFingerprint.capture(repo)
        let pick = try await repo.git("rev-parse", "feature")
        _ = try await handle.cherryPick([pick], context: Ops.context, expected: nil)
        try await handle.abortOperation(token: confirm(.abortOperation))
        let after = try await RepoFingerprint.capture(repo)
        #expect(after == before, "\(after.difference(from: before))")
    }

    @Test func cherryPickMergeCommitRequiresMainline() async throws {
        let (_, repo, handle) = try await diverged()
        try await repo.git("merge", "--no-ff", "-q", "-m", "Merge feature", "feature")
        let merge = try await repo.git("rev-parse", "HEAD")
        try await repo.git("switch", "-q", "-c", "target", "HEAD~1")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.cherryPick([merge], context: Ops.context, expected: nil)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(try await handle.parents(of: merge).count == 2)
        let outcome = try await handle.cherryPick([merge], mainline: 1, context: Ops.context, expected: nil)
        guard case .committed = outcome else {
            Issue.record("expected commit, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: repo.path + "/f.txt"))
    }

    @Test func revertCreatesCommitWithProfileIdentity() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("b.txt", "b\n")
        let target = try await repo.commit("Add b")
        let outcome = try await handle.revert(target, context: Ops.context, expected: nil)
        guard case .committed = outcome else {
            Issue.record("expected commit, got \(outcome)")
            return
        }
        #expect(try await repo.git("log", "-1", "--format=%an|%cn|%s") == "Ada Lovelace|Ada Lovelace|Revert \"Add b\"")
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/b.txt"))
    }

    @Test func revertConflictAbort() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("a.txt", "one\nX\nthree\n")
        let target = try await repo.commit("X")
        try repo.write("a.txt", "one\nY\nthree\n")
        try await repo.commit("Y")
        let before = try await RepoFingerprint.capture(repo)
        #expect(
            try await handle.revert(target, context: Ops.context, expected: nil)
                == .stoppedWithConflicts(paths: ["a.txt"]))
        guard case .reverting = try await handle.operationState() else {
            Issue.record("not reverting")
            return
        }
        try await handle.abortOperation(token: confirm(.abortOperation))
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test(arguments: ["merge", "rebase", "cherry-pick", "pull"])
    func dirtyTreeMatrixNeverLosesChanges(operation: String) async throws {
        let world = try await Ops.world()
        let repo = world.a
        let handle = world.handleA
        try repo.write("a.txt", "one\nupstream\nthree\n")
        try await repo.git("switch", "-q", "-c", "feature")
        try await repo.commit("Feature edits a")
        try await repo.git("push", "-q", "origin", "feature:main", "--force")
        try await repo.git("switch", "-q", "main")
        try await repo.git("fetch", "-q")
        // staged, unstaged, untracked and partially staged changes touching the incoming file.
        try repo.write("a.txt", "one\nmine\nthree\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "one\nmine\nthree\nmore\n")
        try repo.write("u.txt", "untracked\n")
        let before = try await RepoFingerprint.capture(repo)
        let pick = try await repo.git("rev-parse", "feature")
        do {
            switch operation {
            case "merge":
                _ = try await handle.merge(MergeRequest(source: "feature"), context: Ops.context, expected: nil)
            case "rebase": _ = try await handle.rebase(onto: "feature", context: Ops.context, expected: nil)
            case "cherry-pick": _ = try await handle.cherryPick([pick], context: Ops.context, expected: nil)
            default: _ = try await handle.pull(.merge, context: Ops.context)
            }
        } catch {
            // Git refused: nothing may have changed except fetched remote-tracking refs.
        }
        let after = try await RepoFingerprint.capture(repo)
        #expect(after.workingTree == before.workingTree, "\(after.difference(from: before))")
        #expect(after.index == before.index)
        #expect(after.head == before.head)
    }
}
