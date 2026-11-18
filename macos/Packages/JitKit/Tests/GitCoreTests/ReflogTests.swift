import Darwin
import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct ReflogTests {
    func setup() async throws -> (GitSandbox, TestRepo, RepositoryHandle) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "original\n")
        try await repo.commit("Initial")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return (sandbox, repo, handle)
    }

    @Test func reflogPageClassifiesActionsAndUsesEventTime() async throws {
        let (sandbox, repo, handle) = try await setup()
        try await repo.git("commit", "--amend", "-m", "Amended")
        let old = try await repo.git("rev-parse", "HEAD@{1}")
        let eventDate = "2026-02-01T12:00:00Z"
        let engine = GitEngine(configuration: sandbox.engineConfiguration(extra: ["GIT_COMMITTER_DATE": eventDate]))
        _ = try await engine.run(GitCommand(["reset", "--soft", old], in: repo.path, kind: .write))
        let page = try await handle.reflogPage()
        #expect(page.entries.map(\.action) == [.reset, .amend, .commit])
        #expect(page.entries.first?.timestamp == 1_769_947_200)
        #expect(page.entries.first?.selector == "HEAD@{0}")
    }

    @Test func reflogMarksUnreachableAfterResetAndRecoveryPreservesFiles() async throws {
        let (_, repo, handle) = try await setup()
        let initial = try await repo.git("rev-parse", "HEAD")
        try repo.write("a.txt", "second\n")
        let lost = try await repo.commit("Lost commit")
        try await repo.git("reset", "--hard", initial)
        try repo.write("untracked.txt", "keep\n")
        try repo.write("a.txt", "local changes\n")
        let before = try await RepoFingerprint.capture(repo)
        let page = try await handle.reflogPage()
        let entry = try #require(page.entries.first { $0.oid.hex() == lost })
        #expect(entry.isUnreachable)
        #expect(!page.entries[0].isUnreachable)
        let state = try await handle.captureState()
        _ = try await handle.createBranch("recovered", startPoint: entry.oid.hex(), switchTo: false, expected: state)
        let after = try await RepoFingerprint.capture(repo)
        #expect(before.head == after.head)
        #expect(before.index == after.index)
        #expect(before.workingTree == after.workingTree)
        #expect(try await repo.git("rev-parse", "recovered") == lost)
        #expect(try await handle.reflogPage().entries.first { $0.oid == entry.oid }?.isUnreachable == false)
    }

    @Test func pagesAndRejectsChangedCursor() async throws {
        let (_, repo, handle) = try await setup()
        for n in 0..<4 { try await repo.commit("Commit \(n)") }
        let first = try await handle.reflogPage(limit: 2)
        let cursor = try #require(first.next)
        let second = try await handle.reflogPage(cursor: cursor, limit: 2)
        #expect(first.entries.count == 2 && second.entries.count == 2)
        #expect(second.entries.first?.selector == "HEAD@{2}")
        #expect(Set(first.entries.map(\.oid)).isDisjoint(with: second.entries.map(\.oid)))
        try await repo.commit("Concurrent commit")
        await #expect(throws: (any Error).self) { try await handle.reflogPage(cursor: cursor) }
    }

    @Test func detachedHeadAncestryRemainsReachable() async throws {
        let (_, repo, handle) = try await setup()
        try await repo.git("switch", "--detach")
        let ancestor = try await repo.commit("Detached ancestor")
        try await repo.commit("Detached tip")
        let page = try await handle.reflogPage()
        #expect(page.entries.first { $0.oid.hex() == ancestor }?.isUnreachable == false)
    }

    @Test func emptyUnbornAndDisabledReflogs() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        #expect(try await handle.reflogPage().entries.isEmpty)
        try await repo.git("config", "core.logAllRefUpdates", "false")
        try await repo.commit("No log")
        #expect(try await handle.reflogPage().entries.isEmpty)
    }

    @Test func rejectsRevisionExpressionsAndUnknownBranches() async throws {
        let (_, _, handle) = try await setup()
        for ref in ["--all", "HEAD@{1}", "main~1", "refs/tags/example", "refs/heads/missing"] {
            await #expect(throws: (any Error).self) { try await handle.reflogPage(ref: ref) }
        }
    }

    @Test func findUnreachableListsDroppedStashWithoutWriting() async throws {
        let (_, repo, handle) = try await setup()
        try repo.write("a.txt", "stashed change\n")
        try await repo.git("stash", "push", "-m", "Recover me")
        let stash = try await repo.git("rev-parse", "refs/stash")
        try await repo.git("stash", "drop")
        let before = try await RepoFingerprint.capture(repo)
        let result = try await handle.findUnreachable()
        #expect(result.commits.first { $0.oid.hex() == stash }?.looksLikeStash == true)
        #expect(!result.truncated)
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/.git/lost-found"))
    }

    @Test func recoveryPointRecordedForAmendAndReset() async throws {
        let (_, repo, handle) = try await setup()
        let initial = try await repo.git("rev-parse", "HEAD")
        let identity = GitIdentity(name: "Recovery Tester", email: "recovery@jit.invalid")
        let outcome = try await handle.commit(
            CommitRequest(
                message: "Amended", amend: true, identity: IdentitySnapshot(author: identity, committer: identity)))
        let point = try #require(await handle.recoveryPoints.first { $0.refName == "refs/heads/main" })
        #expect(point.oldOID == initial)
        #expect(point.newOID == outcome.commitID)
        let preview = try await handle.resetPreview(to: initial, mode: .soft)
        let token = ConfirmationRequest(
            action: preview.confirmationAction(stashFirst: false), title: "Reset", context: "test",
            changes: "Move HEAD", recoverability: "Reflog", verb: "Reset"
        ).confirm()
        _ = try await handle.reset(preview, token: token)
        #expect(await handle.recoveryPoints.first?.oldOID == outcome.commitID)
    }

    @Test func deletedRefsAndPartialFailureKeepRecoveryPoints() async throws {
        let (_, repo, handle) = try await setup()
        let oid = try await repo.git("rev-parse", "HEAD")
        try await repo.branch("deleted")
        do {
            try await handle.performExclusive("Partially failed mutation", invalidating: [.refs]) {
                () throws(GitCoreError) in
                _ = try await repo.sandbox.engine.run(
                    GitCommand(["branch", "-d", "deleted"], in: repo.path, kind: .write))
                throw .refused(summary: "Failure after changing a ref")
            }
        } catch {}
        let point = try #require(await handle.recoveryPoints.first { $0.refName == "refs/heads/deleted" })
        #expect(point.oldOID == oid && point.newOID == nil)
    }

    @Test func unchangedFailureDoesNotRecordRecovery() async throws {
        let (_, _, handle) = try await setup()
        do {
            try await handle.performExclusive("Refused", invalidating: [.refs]) { () throws(GitCoreError) in
                throw .refused(summary: "No mutation")
            }
        } catch {}
        #expect(await handle.recoveryPoints.isEmpty)
    }
}

extension ReflogTests {
    @Test func recoveryPointsAreBoundedAndExcludeFileOnlyOperations() async throws {
        let (_, repo, handle) = try await setup()
        for n in 0..<55 { try await repo.branch("saved-\(n)") }
        try await handle.performExclusive("Remove saved refs", invalidating: [.refs]) { () throws(GitCoreError) in
            let lines = (0..<55).map { "delete refs/heads/saved-\($0)" }.joined(separator: "\n") + "\n"
            _ = try await repo.sandbox.engine.run(
                GitCommand(
                    ["update-ref", "--stdin"], in: repo.path,
                    kind: .write, stdin: Array(lines.utf8)))
        }
        #expect(await handle.recoveryPoints.count == 50)
        try repo.write("a.txt", "stage this\n")
        try await handle.stage(["a.txt"])
        #expect(await handle.recoveryPoints.count == 50)
    }

    @Test func branchReflogAndLogExpirationInvalidateCursor() async throws {
        let (_, repo, handle) = try await setup()
        try await repo.commit("Second")
        let page = try await handle.reflogPage(ref: "refs/heads/main", limit: 1)
        #expect(page.entries.first?.selector == "refs/heads/main@{0}")
        let cursor = try #require(page.next)
        try await repo.git("reflog", "expire", "--expire=all", "--all")
        do {
            _ = try await handle.reflogPage(ref: "refs/heads/main", cursor: cursor)
            Issue.record("Expired cursor should be refused")
        } catch {
            guard case .staleSnapshot = error else { throw error }
        }
    }

    @Test func sha256ReflogAndLostCommits() async throws {
        let sandbox = try GitSandbox()
        let path = try sandbox.makeDirectory("sha256")
        try await sandbox.git(["init", "--object-format=sha256", "-q"], in: path)
        let repo = TestRepo(sandbox: sandbox, path: path)
        let first = try await repo.commit("Initial")
        let lost = try await repo.commit("Lost SHA256 commit")
        try await repo.git("reset", "--hard", first)
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: path))
        let page = try await handle.reflogPage()
        #expect(page.entries.contains { $0.oid.hex(.sha256) == lost && $0.isUnreachable })
        #expect(try await handle.findUnreachable().commits.contains { $0.oid.hex(.sha256) == lost })
    }

    @Test func lostCommitLimitIsExplicit() async throws {
        let (_, repo, handle) = try await setup()
        let first = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("Lost one")
        try await repo.commit("Lost two")
        try await repo.git("reset", "--hard", first)
        let result = try await handle.findUnreachable(limit: 1)
        #expect(result.commits.count == 1)
        #expect(result.truncated)
    }

    @Test func findUnreachableCancelsAndKillsProcess() async throws {
        let (sandbox, repo, _) = try await setup()
        let git = try await sandbox.engine.gitInfo().path
        let wrapper = sandbox.root + "/slow-git"
        let parentFile = sandbox.root + "/fsck.pid"
        let childFile = sandbox.root + "/child.pid"
        // Delay the real fsck, without fabricating its output. The process tree makes cancellation
        // deterministic even on tiny fixtures where a real fsck normally finishes in milliseconds.
        let script = """
            #!/bin/sh
            for arg in "$@"; do
                if [ "$arg" = fsck ]; then
                    echo $$ > '\(parentFile)'
                    sleep 30 &
                    child=$!
                    echo "$child" > '\(childFile)'
                    trap 'kill "$child" 2>/dev/null; wait "$child"; exit 0' TERM
                    wait "$child"
                fi
            done
            exec '\(git)' "$@"
            """
        try script.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper)
        var configuration = sandbox.engineConfiguration()
        configuration.locator.userOverridePath = wrapper
        // Delay the selected Git even in bundled-runtime test runs.
        configuration.locator.allowsEnvironmentOverride = false
        configuration.terminationGrace = .milliseconds(300)
        let engine = GitEngine(configuration: configuration)
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let before = try await RepoFingerprint.capture(repo)
        let task = Task { try await handle.findUnreachable() }
        defer { task.cancel() }
        let helper = ProcessRunnerTests()
        let parent = try await helper.readPID(parentFile)
        let child = try await helper.readPID(childFile)
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
        #expect(await helper.waitUntilGone(parent))
        #expect(await helper.waitUntilGone(child))
        #expect(try await RepoFingerprint.capture(repo) == before)
    }
}

extension ReflogTests {
    @Test func relatedLostCommitsAreNotMistakenForHeadAncestors() async throws {
        let (_, repo, handle) = try await setup()
        let initial = try await repo.git("rev-parse", "HEAD")
        let older = try await repo.commit("Older lost commit")
        let newer = try await repo.commit("Newer lost commit")
        try await repo.git("reset", "--hard", initial)
        let page = try await handle.reflogPage()
        #expect(page.entries.first { $0.oid.hex() == older }?.isUnreachable == true)
        #expect(page.entries.first { $0.oid.hex() == newer }?.isUnreachable == true)
        #expect(page.entries.filter { $0.oid.hex() == initial }.allSatisfy { !$0.isUnreachable })
        try await repo.branch("preserved")
        try await repo.git("branch", "-f", "preserved", newer)
        let preserved = try await handle.reflogPage()
        #expect(preserved.entries.allSatisfy { !$0.isUnreachable })
    }
}

extension ReflogTests {
    @Test func droppingOlderStashRecordsItEvenWhenTipDoesNotChange() async throws {
        let (_, repo, handle) = try await setup()
        try repo.write("a.txt", "first stash\n")
        try await repo.git("stash", "push", "-m", "First")
        let older = try await repo.git("rev-parse", "refs/stash")
        try repo.write("a.txt", "second stash\n")
        try await repo.git("stash", "push", "-m", "Second")
        let tip = try await repo.git("rev-parse", "refs/stash")
        let token = ConfirmationRequest(
            action: .dropStash(index: 1, oid: older), title: "Drop stash", context: "test",
            changes: "Drop older stash", recoverability: "Recorded SHA", verb: "Drop Stash"
        ).confirm()
        try await handle.dropStash(index: 1, oid: older, token: token)
        #expect(try await repo.git("rev-parse", "refs/stash") == tip)
        #expect(await handle.recoveryPoints.contains { $0.refName == "refs/stash" && $0.oldOID == older })
        let clear = ConfirmationRequest(
            action: .clearStashes, title: "Clear", context: "test",
            changes: "Clear stashes", recoverability: "Recorded SHA", verb: "Clear Stashes"
        ).confirm()
        try await handle.clearStashes(token: clear)
        #expect(await handle.recoveryPoints.contains { $0.refName == "refs/stash" && $0.oldOID == tip })
    }
}
