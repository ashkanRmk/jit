import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Commit (P3.10, ADR-0014, ADR-0028) on real repositories. The sandbox's own `GIT_AUTHOR_*` /
/// `GIT_COMMITTER_*` ("Jit Tests") stand in for whatever the user's environment says; the profile must win.
@Suite struct CommitTests {
    static let work = IdentitySnapshot(
        author: GitIdentity(name: "Ana Ruiz", email: "ana@work.example"),
        committer: GitIdentity(name: "Ana Ruiz", email: "ana@work.example"))
    static let other = IdentitySnapshot(
        author: GitIdentity(name: "Kenji Sato", email: "kenji@home.example"),
        committer: GitIdentity(name: "Kenji Sato", email: "kenji@home.example"))

    func setup(_ files: [String: String] = ["a.txt": "a\n"]) async throws -> (GitSandbox, TestRepo, RepositoryHandle) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        let handle = try await GitEngine(configuration: sandbox.engineConfiguration()).openRepository(
            at: URL(fileURLWithPath: repo.path))
        return (sandbox, repo, handle)
    }

    func log(_ repo: TestRepo, _ format: String) async throws -> String {
        try await repo.git("log", "-1", "--format=\(format)")
    }

    func hook(_ repo: TestRepo, _ name: String, _ script: String) throws {
        let path = repo.path + "/.git/hooks/" + name
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test func commitUsesProfileIdentityEnv() async throws {
        let (_, repo, handle) = try await setup()
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        let outcome = try await handle.commit(CommitRequest(message: "Add b\n\nBody line.", identity: Self.work))
        #expect(
            try await log(repo, "%an <%ae> | %cn <%ce>") == "Ana Ruiz <ana@work.example> | Ana Ruiz <ana@work.example>")
        #expect(try await log(repo, "%B") == "Add b\n\nBody line.")
        #expect(outcome.commitID == (try await repo.git("rev-parse", "HEAD")))
    }

    @Test func commitDoesNotModifyAnyConfig() async throws {
        let (sandbox, repo, handle) = try await setup()
        let global = try #require(sandbox.environment["GIT_CONFIG_GLOBAL"])
        try "[core]\n\tautocrlf = false\n".write(toFile: global, atomically: true, encoding: .utf8)
        let globalBefore = try Data(contentsOf: URL(fileURLWithPath: global))
        let localBefore = try Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/config"))
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        _ = try await handle.commit(CommitRequest(message: "Add b", identity: Self.work))
        _ = try await handle.commit(
            CommitRequest(message: "Amended", amend: true, resetAuthor: true, identity: Self.other))
        #expect(try Data(contentsOf: URL(fileURLWithPath: global)) == globalBefore)
        #expect(try Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/config")) == localBefore)
    }

    @Test func commitRespectsRepoConfigButProfileOverridesIdentity() async throws {
        let (_, repo, handle) = try await setup()
        try await repo.git("config", "user.name", "Repo Config")
        try await repo.git("config", "user.email", "repo@config.example")
        try await repo.git("config", "commit.cleanup", "strip")  // repository behaviour still applies
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        _ = try await handle.commit(CommitRequest(message: "Subject\n\n# a comment line\nbody", identity: Self.work))
        #expect(try await log(repo, "%ae %ce") == "ana@work.example ana@work.example")
        #expect(try await log(repo, "%B") == "Subject\n\nbody")
        #expect(try await handle.configuredEmail() == "repo@config.example")
    }

    @Test func amendKeepsAuthorSetsCommitter() async throws {
        let (_, repo, handle) = try await setup()
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        _ = try await handle.commit(CommitRequest(message: "By Ana", identity: Self.work))
        try repo.write("b.txt", "b2\n")
        try await repo.git("add", "b.txt")
        _ = try await handle.commit(CommitRequest(message: "By Ana, amended", amend: true, identity: Self.other))
        #expect(try await log(repo, "%an|%cn|%s") == "Ana Ruiz|Kenji Sato|By Ana, amended")
        #expect(try await repo.git("rev-list", "--count", "HEAD") == "2")
    }

    @Test func amendResetAuthor() async throws {
        let (_, repo, handle) = try await setup()
        _ = try await handle.commit(
            CommitRequest(message: "Reset", amend: true, resetAuthor: true, identity: Self.other))
        #expect(try await log(repo, "%an|%cn") == "Kenji Sato|Kenji Sato")
    }

    @Test func amendMessageOnly() async throws {
        let (_, repo, handle) = try await setup()
        let tree = try await repo.git("rev-parse", "HEAD^{tree}")
        _ = try await handle.commit(CommitRequest(message: "Better message", amend: true, identity: Self.work))
        #expect(try await log(repo, "%s") == "Better message")
        #expect(try await repo.git("rev-parse", "HEAD^{tree}") == tree)
        #expect(try await handle.headMessage() == "Better message")
        #expect(try await handle.headAuthor()?.name == "Jit Tests")
    }

    @Test func commitOnUnbornBranch() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("first.txt", "1\n")
        try await repo.git("add", "first.txt")
        let handle = try await GitEngine(configuration: sandbox.engineConfiguration()).openRepository(
            at: URL(fileURLWithPath: repo.path))
        _ = try await handle.commit(CommitRequest(message: "Root", identity: Self.work))
        #expect(try await repo.git("rev-list", "--count", "HEAD") == "1")
        #expect(try await handle.headIsInUpstream() == false)
    }

    @Test func commitHookFailureReportsOutput() async throws {
        let (_, repo, handle) = try await setup()
        try hook(repo, "pre-commit", "#!/bin/sh\necho 'lint: 2 problems' >&2\nexit 1\n")
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        do {
            _ = try await handle.commit(CommitRequest(message: "Blocked", identity: Self.work))
            Issue.record("expected the hook to fail")
        } catch {
            #expect(error.detail?.contains("lint: 2 problems") == true)
        }
        #expect(try await repo.git("rev-list", "--count", "HEAD") == "1")
        // Nothing staged at all → "Nothing to commit."
        try await repo.git("reset", "-q")
        do {
            _ = try await handle.commit(CommitRequest(message: "Empty", noVerify: true, identity: Self.work))
            Issue.record("expected nothing to commit")
        } catch {
            #expect(error.summary == "Nothing to commit.")
        }
    }

    @Test func commitNoVerifyOnlyWhenRequested() async throws {
        let (_, repo, handle) = try await setup()
        let marker = repo.sandbox.root + "/hook-ran"
        try hook(repo, "pre-commit", "#!/bin/sh\ntouch '\(marker)'\nexit 0\n")
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        _ = try await handle.commit(CommitRequest(message: "With hooks", identity: Self.work))
        #expect(FileManager.default.fileExists(atPath: marker))
        try FileManager.default.removeItem(atPath: marker)
        try repo.write("c.txt", "c\n")
        try await repo.git("add", "c.txt")
        _ = try await handle.commit(CommitRequest(message: "Without hooks", noVerify: true, identity: Self.work))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func commitCancelKillsHook() async throws {
        let (_, repo, handle) = try await setup()
        let marker = repo.sandbox.root + "/hook-finished"
        try hook(repo, "pre-commit", "#!/bin/sh\nsleep 5\ntouch '\(marker)'\n")
        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { try await handle.commit(CommitRequest(message: "Slow", identity: Self.work)) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        _ = await task.result
        #expect(clock.now - started < .seconds(3))
        try await Task.sleep(for: .seconds(5))
        #expect(!FileManager.default.fileExists(atPath: marker), "the hook's process group was killed")
        #expect(try await repo.git("rev-list", "--count", "HEAD") == "1")
    }

    @Test func commitBlockedWithConflicts() async throws {
        let (_, repo, handle) = try await setup(["c.txt": "base\n"])
        try await repo.git("switch", "-q", "-c", "other")
        try repo.write("c.txt", "theirs\n")
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try repo.write("c.txt", "ours\n")
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "-q", "other")
        do {
            _ = try await handle.commit(CommitRequest(message: "Merge", identity: Self.work))
            Issue.record("expected refusal")
        } catch {
            #expect(error.summary == "Resolve the conflicts before committing.")
        }
    }
}
