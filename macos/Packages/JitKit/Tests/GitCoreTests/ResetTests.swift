import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct ResetTests {
    let identity = GitIdentity(name: "Reset Tester", email: "reset@jit.invalid")
    var context: ExecContext { ExecContext(identity: IdentitySnapshot(author: identity, committer: identity)) }

    func setup() async throws -> (GitSandbox, TestRepo, RepositoryHandle, String, String) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "original\n")
        try repo.write("unchanged.txt", "keep\n")
        let first = try await repo.commit("Initial")
        try repo.write("a.txt", "committed change\n")
        let head = try await repo.commit("Second")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return (sandbox, repo, handle, first, head)
    }

    func confirm(_ preview: ResetPreview, stashFirst: Bool = false) -> ConfirmationToken {
        ConfirmationRequest(
            action: preview.confirmationAction(stashFirst: stashFirst), title: "Reset", context: "test",
            changes: "Reset to selected commit", recoverability: "Reflog and optional stash", verb: "Reset"
        ).confirm()
    }

    @Test func resetSoftKeepsIndexAndWorktree() async throws {
        let (_, repo, handle, first, head) = try await setup()
        try repo.write("a.txt", "staged\n"); try await repo.git("add", "a.txt")
        try repo.write("a.txt", "unstaged\n"); try repo.write("notes.txt", "untracked\n")
        let before = try await RepoFingerprint.capture(repo)
        let preview = try await handle.resetPreview(to: first, mode: .soft)
        #expect(try await RepoFingerprint.capture(repo) == before)
        let outcome = try await handle.reset(preview, token: confirm(preview))
        let after = try await RepoFingerprint.capture(repo)
        #expect(after.index == before.index && after.workingTree == before.workingTree)
        #expect(try await repo.git("rev-parse", "HEAD") == first)
        #expect(outcome.previousHead == head && outcome.stashOID == nil)
        #expect(await handle.recoveryPoints.first?.oldOID == head)
    }

    @Test func resetMixedUnstagesWithoutChangingFiles() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try repo.write("a.txt", "staged\n"); try await repo.git("add", "a.txt")
        try repo.write("a.txt", "unstaged\n")
        let before = try await RepoFingerprint.capture(repo)
        let preview = try await handle.resetPreview(to: first, mode: .mixed)
        _ = try await handle.reset(preview, token: confirm(preview))
        #expect(try await RepoFingerprint.capture(repo).workingTree == before.workingTree)
        #expect(try await repo.git("diff", "--cached", "--name-only").isEmpty)
    }

    @Test func resetKeepPreservesDisjointLocalChanges() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try repo.write("unchanged.txt", "local change\n")
        let preview = try await handle.resetPreview(to: first, mode: .keep)
        _ = try await handle.reset(preview, token: confirm(preview))
        #expect(try String(contentsOfFile: repo.path + "/unchanged.txt", encoding: .utf8) == "local change\n")
        #expect(try String(contentsOfFile: repo.path + "/a.txt", encoding: .utf8) == "original\n")
    }

    @Test func resetKeepAbortsOnConflictingChanges() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try repo.write("a.txt", "local changes\n")
        let preview = try await handle.resetPreview(to: first, mode: .keep)
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) { try await handle.reset(preview, token: confirm(preview)) }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func resetHardPreviewListsLocalFilesAndReachability() async throws {
        let (_, repo, handle, first, head) = try await setup()
        try repo.write("a.txt", "local\n"); try await repo.git("add", "a.txt")
        try repo.write("a.txt", "partially staged\n"); try repo.write("notes.txt", "untracked\n")
        let before = try await RepoFingerprint.capture(repo)
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        #expect(preview.discardedPaths == ["a.txt"])
        #expect(preview.localChanges.first { $0.path == "a.txt" }?.staged == true)
        #expect(preview.localChanges.first { $0.path == "a.txt" }?.unstaged == true)
        #expect(preview.unreachableCount == 1 && preview.unreachableCommits.first?.oid == head)
        #expect(try await RepoFingerprint.capture(repo) == before)
        try await repo.branch("preserved")
        #expect(try await handle.resetPreview(to: first, mode: .hard).unreachableCount == 0)
        try await repo.git("update-ref", "refs/remotes/origin/main", head)
        #expect(try await handle.resetPreview(to: first, mode: .hard).publishedCount == 1)
    }

    @Test func resetHardLeavesUntrackedFiles() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try repo.write("a.txt", "discard\n"); try repo.write("notes.txt", "keep notes\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        _ = try await handle.reset(preview, token: confirm(preview))
        #expect(try String(contentsOfFile: repo.path + "/notes.txt", encoding: .utf8) == "keep notes\n")
        #expect(try String(contentsOfFile: repo.path + "/a.txt", encoding: .utf8) == "original\n")
    }

    @Test(arguments: ["refs", "index", "worktree", "new-untracked"])
    func resetRejectsStalePreview(_ changed: String) async throws {
        let (_, repo, handle, first, _) = try await setup()
        try repo.write("a.txt", "before\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        switch changed {
        case "refs": try await repo.branch("external")
        case "index": try await repo.git("add", "a.txt")
        case "worktree": try repo.write("a.txt", "after!\n")
        default: try repo.write("new.txt", "external\n")
        }
        let before = try await RepoFingerprint.capture(repo)
        do {
            _ = try await handle.reset(
                preview, stashFirst: true, token: confirm(preview, stashFirst: true), context: context)
            Issue.record("Expected stale-state refusal")
        } catch { guard case .staleSnapshot = error else { throw error } }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func resetConfirmationBindsPreviewAndStashChoice() async throws {
        let (_, repo, handle, first, _) = try await setup()
        let firstPreview = try await handle.resetPreview(to: first, mode: .hard)
        let second = try await handle.resetPreview(to: first, mode: .hard)
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) { try await handle.reset(second, token: confirm(firstPreview)) }
        await #expect(throws: (any Error).self) {
            try await handle.reset(firstPreview, stashFirst: true, token: confirm(firstPreview), context: context)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test func resetStashFirstPreservesStagedUnstagedAndUntracked() async throws {
        let (_, repo, handle, first, head) = try await setup()
        try repo.write("a.txt", "staged\n"); try await repo.git("add", "a.txt")
        try repo.write("a.txt", "working\n"); try repo.write("notes.txt", "notes\n")
        let before = try await RepoFingerprint.capture(repo)
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        let revision = await handle.repoRevision
        let outcome = try await handle.reset(
            preview, stashFirst: true, token: confirm(preview, stashFirst: true), context: context)
        let stash = try #require(outcome.stashOID)
        #expect(await handle.repoRevision.value == revision.value + 1)
        #expect(outcome.previousHead == head)
        #expect(try await repo.git("show", "\(stash):a.txt") == "working")
        #expect(try await repo.git("show", "\(stash)^2:a.txt") == "staged")
        #expect(try await repo.git("show", "\(stash)^3:notes.txt") == "notes")
        #expect(try await repo.git("show", "-s", "--format=%an <%ae>", stash) == "Reset Tester <reset@jit.invalid>")
        #expect(try await repo.git("status", "--porcelain").isEmpty)
        // Recover committed history as a branch, then restore the saved index/worktree on that base.
        _ = try await handle.createBranch(
            "recovered", startPoint: head, switchTo: true, expected: handle.captureState())
        try await repo.git("stash", "apply", "--index", stash)
        let restored = try await RepoFingerprint.capture(repo)
        #expect(restored.index == before.index && restored.workingTree == before.workingTree)
    }

    @Test(arguments: [false, true])
    func hardResetRefusesUntrackedAndIgnoredObstructions(_ ignored: Bool) async throws {
        let (_, repo, handle, first, _) = try await setup()
        try await repo.git("rm", "a.txt"); try await repo.commit("Remove a")
        try repo.write("a.txt", "precious local file\n")
        if ignored { try repo.write(".git/info/exclude", "a.txt\n") }
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        #expect(preview.obstructingPaths.contains("a.txt"))
        let before = try await RepoFingerprint.capture(repo)
        for stashFirst in [false, true] {
            await #expect(throws: (any Error).self) {
                try await handle.reset(
                    preview, stashFirst: stashFirst,
                    token: confirm(preview, stashFirst: stashFirst), context: context)
            }
            #expect(try await RepoFingerprint.capture(repo) == before)
        }
    }

    @Test func hardResetRefusesDirectoryObstructionAndHiddenIndexFlags() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try await repo.git("rm", "a.txt"); try await repo.commit("Remove a")
        try repo.write("a.txt/ignored.dat", "keep\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        #expect(preview.obstructingPaths.contains("a.txt"))
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) { try await handle.reset(preview, token: confirm(preview)) }
        #expect(try await RepoFingerprint.capture(repo) == before)
        try await repo.git("update-index", "--assume-unchanged", "unchanged.txt")
        await #expect(throws: (any Error).self) { try await handle.resetPreview(to: first, mode: .hard) }
    }
}

extension ResetTests {
    @Test func previewCannotBeReusedInAnIdenticalRepository() async throws {
        let (_, firstRepo, firstHandle, target, _) = try await setup()
        defer { withExtendedLifetime(firstRepo) {} }
        let (_, otherRepo, otherHandle, sameTarget, _) = try await setup()
        #expect(target == sameTarget)
        let preview = try await firstHandle.resetPreview(to: target, mode: .soft)
        let before = try await RepoFingerprint.capture(otherRepo)
        await #expect(throws: (any Error).self) { try await otherHandle.reset(preview, token: confirm(preview)) }
        #expect(try await RepoFingerprint.capture(otherRepo) == before)
    }

    @Test func dirtySubmoduleIsVisibleDespiteIgnoreConfigAndNeverResetRecursively() async throws {
        let (sandbox, repo, handle, first, _) = try await setup()
        let child = try await sandbox.makeRepository("child")
        try child.write("child.txt", "original\n"); try await child.commit("Child")
        try await repo.git("-c", "protocol.file.allow=always", "submodule", "add", child.path, "module")
        try await repo.commit("Add submodule")
        try await repo.git("config", "submodule.module.ignore", "all")
        try await repo.git("config", "submodule.recurse", "true")
        try repo.write("module/child.txt", "precious local child change\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        #expect(preview.unsupportedStashPaths == ["module"])
        #expect(!preview.discardedPaths.contains("module"))
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) {
            try await handle.reset(
                preview, stashFirst: true, token: confirm(preview, stashFirst: true), context: context)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        _ = try await handle.reset(preview, token: confirm(preview))
        #expect(
            try String(contentsOfFile: repo.path + "/module/child.txt", encoding: .utf8)
                == "precious local child change\n")
    }

    @Test func previewRejectsOperationAndStashRejectsNestedRepository() async throws {
        let (sandbox, repo, handle, first, _) = try await setup()
        try repo.write(".git/MERGE_HEAD", first + "\n")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) { try await handle.resetPreview(to: first, mode: .hard) }
        #expect(try await RepoFingerprint.capture(repo) == before)
        try FileManager.default.removeItem(atPath: repo.path + "/.git/MERGE_HEAD")
        let nested = repo.path + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await sandbox.git(["init", "-q"], in: nested)
        try repo.write("nested/precious.txt", "not saved by an outer stash\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        #expect(preview.unsupportedStashPaths == ["nested"])
        let dirty = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) {
            try await handle.reset(
                preview, stashFirst: true, token: confirm(preview, stashFirst: true), context: context)
        }
        #expect(try await RepoFingerprint.capture(repo) == dirty)
    }

    @Test func sha256AndDetachedHeadPreview() async throws {
        let sandbox = try GitSandbox()
        let path = try sandbox.makeDirectory("sha256")
        try await sandbox.git(["init", "-q", "--object-format=sha256"], in: path)
        let repo = TestRepo(sandbox: sandbox, path: path)
        let first = try await repo.commit("Initial")
        let head = try await repo.commit("Later")
        try await repo.git("switch", "--detach", head)
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: path))
        let preview = try await handle.resetPreview(to: first, mode: .keep)
        #expect(preview.branch == nil && preview.target.count == 64 && preview.removedCount == 1)
        #expect(preview.unreachableCount == 0)
        _ = try await handle.reset(preview, token: confirm(preview))
        #expect(try await repo.git("rev-parse", "HEAD") == first)
        #expect(try await repo.git("rev-parse", "main") == head)
    }

    func wrapped(_ sandbox: GitSandbox, repo: TestRepo, behavior: String) async throws -> RepositoryHandle {
        let git = try await sandbox.engine.gitInfo().path
        let script = """
            #!/bin/sh
            for arg in "$@"; do
                if [ "$arg" = stash ]; then
                    if [ '\(behavior)' = stash-fail ]; then echo 'Stash failed for test' >&2; exit 1; fi
                    if [ '\(behavior)' = ref-change ]; then
                        '\(git)' "$@" || exit $?
                        '\(git)' update-ref refs/heads/external HEAD
                        exit 0
                    fi
                    if [ '\(behavior)' = pause ]; then
                        touch '\(sandbox.root)/started'
                        until [ -f '\(sandbox.root)/release' ]; do sleep 0.01; done
                    fi
                fi
                if [ "$arg" = reset ] && [ '\(behavior)' = reset-fail ]; then echo 'Reset failed for test' >&2; exit 1; fi
            done
            exec '\(git)' "$@"
            """
        let path = sandbox.root + "/controlled-git"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        var configuration = sandbox.engineConfiguration()
        configuration.locator.userOverridePath = path
        configuration.locator.allowsEnvironmentOverride = false
        return try await GitEngine(configuration: configuration).openRepository(at: URL(fileURLWithPath: repo.path))
    }

    @Test(arguments: ["stash-fail", "reset-fail", "ref-change"])
    func failedChainDoesNotLoseChanges(_ behavior: String) async throws {
        let (sandbox, repo, _, first, head) = try await setup()
        let handle = try await wrapped(sandbox, repo: repo, behavior: behavior)
        try repo.write("a.txt", "local\n"); try repo.write("new.txt", "untracked\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        let before = try await RepoFingerprint.capture(repo)
        do {
            _ = try await handle.reset(
                preview, stashFirst: true, token: confirm(preview, stashFirst: true), context: context)
            Issue.record("Expected test failure")
        } catch {
            #expect(try await repo.git("rev-parse", "HEAD") == head)
            if behavior == "stash-fail" {
                #expect(try await RepoFingerprint.capture(repo) == before)
            } else {
                let stash = try await repo.git("rev-parse", "refs/stash")
                #expect(error.summary.contains(stash))
                try await repo.git("stash", "apply", "--index", stash)
                let restored = try await RepoFingerprint.capture(repo)
                #expect(restored.index == before.index && restored.workingTree == before.workingTree)
            }
        }
    }

    @Test func stashResetChainIgnoresCancellationAndKeepsWriterUntilComplete() async throws {
        let (sandbox, repo, _, first, _) = try await setup()
        let handle = try await wrapped(sandbox, repo: repo, behavior: "pause")
        try repo.write("a.txt", "local\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        let token = confirm(preview, stashFirst: true)
        let task = Task { try await handle.reset(preview, stashFirst: true, token: token, context: context) }
        defer { try? Data().write(to: URL(fileURLWithPath: sandbox.root + "/release")) }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: sandbox.root + "/started") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: sandbox.root + "/started"))
        let observer = Task {
            try await handle.performExclusive("Observe after reset", invalidating: []) {
                () throws(GitCoreError) -> String? in
                try await handle.captureState().head
            }
        }
        for _ in 0..<500 {
            if await handle.writeGateState().pending.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await handle.writeGateState().pending == ["Observe after reset"])
        let queued = Task { try await handle.reset(preview, token: confirm(preview)) }
        queued.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await queued.value }
        task.cancel()
        try Data().write(to: URL(fileURLWithPath: sandbox.root + "/release"))
        #expect(try await task.value.stashOID != nil)
        #expect(try await observer.value == first)
    }

    @Test func profileIsRequiredOnlyWhenSavingChanges() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try repo.write("a.txt", "local\n")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.noActiveProfile) {
            try await handle.reset(preview, stashFirst: true, token: confirm(preview, stashFirst: true))
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        _ = try await handle.reset(preview, token: confirm(preview))
    }

    @Test func renameBinaryAndSymlinkAreSavedWithoutFollowingLink() async throws {
        let (_, repo, handle, first, _) = try await setup()
        try await repo.git("mv", "a.txt", "renamed\nfile.txt")
        let binary = Data([0, 255, 1, 2, 0, 128])
        try binary.write(to: URL(fileURLWithPath: repo.path + "/binary.dat"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.path + "/external-link", withDestinationPath: "/etc/hosts")
        let preview = try await handle.resetPreview(to: first, mode: .hard)
        #expect(preview.localChanges.contains { $0.path == "renamed\nfile.txt" && $0.staged })
        let outcome = try await handle.reset(
            preview, stashFirst: true, token: confirm(preview, stashFirst: true), context: context)
        let stash = try #require(outcome.stashOID)
        let bytes = try await repo.sandbox.engine.run(GitCommand(["show", "\(stash)^3:binary.dat"], in: repo.path))
        #expect(Data(bytes.stdout) == binary)
        #expect(try await repo.git("show", "\(stash)^3:external-link") == "/etc/hosts")
    }
}
