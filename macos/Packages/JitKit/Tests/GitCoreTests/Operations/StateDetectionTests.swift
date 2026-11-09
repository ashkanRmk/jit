import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// P4.3 — operation states created by Git itself (as if from Terminal).
@Suite struct StateDetectionTests {
    @Test func stateDetectsMerge() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        _ = try? await repo.git("merge", "feature")
        let state = try await handle.operationState()
        #expect(state == .merging(source: "feature", conflicted: 1))
    }

    @Test func stateDetectsRebaseMerge() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        _ = try? await repo.git("rebase", "main")
        guard case let .rebasing(headName, onto, step, total, stopped, conflicted) = try await handle.operationState()
        else {
            Issue.record("not rebasing")
            return
        }
        #expect(headName == "feature")
        #expect(onto == (try await repo.git("rev-parse", "main")))
        #expect(step == 1 && total == 1)
        #expect(stopped?.subject == "Feature edit")
        #expect(conflicted == 1)
    }

    @Test func stateDetectsRebaseApply() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        _ = try? await repo.git("rebase", "--apply", "main")
        guard case .rebasing(let headName, _, _, _, _, _) = try await handle.operationState() else {
            Issue.record("not rebasing (apply backend)")
            return
        }
        #expect(headName == "feature")
    }

    @Test func stateDetectsAm() async throws {
        let (sandbox, repo, handle) = try await Ops.conflicting()
        let patch = try await repo.git("format-patch", "-1", "feature", "--stdout")
        let patchPath = sandbox.root + "/p.patch"
        try (patch + "\n").write(toFile: patchPath, atomically: true, encoding: .utf8)
        _ = try? await repo.git("am", patchPath)
        #expect(try await handle.operationState() == .applyingMailbox)
    }

    @Test func stateDetectsCherryPick() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        let oid = try await repo.git("rev-parse", "feature")
        _ = try? await repo.git("cherry-pick", oid)
        guard case .cherryPicking(let commit, _, let conflicted) = try await handle.operationState() else {
            Issue.record("not cherry-picking")
            return
        }
        #expect(commit?.oid == oid)
        #expect(conflicted == 1)
    }

    @Test func stateDetectsRevert() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("a.txt", "one\nchanged\nthree\n")
        let first = try await repo.commit("Change")
        try repo.write("a.txt", "one\nchanged again\nthree\n")
        try await repo.commit("Change again")
        _ = try? await repo.git("revert", "--no-edit", first)
        guard case .reverting(let commit, _, _) = try await handle.operationState() else {
            Issue.record("not reverting")
            return
        }
        #expect(commit?.oid == first)
    }

    @Test func stateDetectsSequencer() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        try await repo.git("switch", "-q", "feature")
        try repo.write("b.txt", "b\n")
        try await repo.commit("Second feature commit")
        try await repo.git("switch", "-q", "main")
        _ = try? await repo.git("cherry-pick", "main..feature")
        // Stopped at the first commit with more to go.
        guard case .cherryPicking(_, let remaining, _) = try await handle.operationState() else {
            Issue.record("not cherry-picking")
            return
        }
        #expect(remaining >= 1)
    }

    @Test func stateDetectsBisect() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.commit("Two")
        try await repo.git("bisect", "start")
        #expect(try await handle.operationState() == .bisecting)
    }

    @Test func stateInLinkedWorktree() async throws {
        let (_, repo, _) = try await Ops.conflicting()
        try await repo.git("branch", "other", "main")
        let worktree = try await repo.addWorktree("wt", branch: "wt-branch")
        let wtRepo = TestRepo(sandbox: repo.sandbox, path: worktree)
        _ = try? await wtRepo.git("merge", "feature")
        let wtHandle = try await Ops.open(wtRepo)
        guard case .merging = try await wtHandle.operationState() else {
            Issue.record("linked worktree merge not detected")
            return
        }
        // The main worktree is unaffected.
        #expect(try await Ops.open(repo).operationState() == .clean)
    }
}
