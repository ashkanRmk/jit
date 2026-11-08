import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Status and operation state against real repositories (`GitTestKit`).
@Suite struct StatusIntegrationTests {
    func open(_ repo: TestRepo, extra: [String: String] = [:]) async throws -> RepositoryHandle {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration(extra: extra))
        return try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    func cleanRepo(_ sandbox: GitSandbox) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try repo.write("b.txt", "b\n")
        try repo.write("c.txt", "c\n")
        try await repo.commit("Initial")
        return repo
    }

    @Test func statusCleanRepo() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let status = try await open(repo).status()
        #expect(status.summary == StatusSummary())
        #expect(status.branch.head == "main")
        #expect(status.operation == .none)
    }

    @Test func statusMixedChangesCounts() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        try repo.write("a.txt", "changed\n")  // unstaged
        try repo.write("b.txt", "staged\n")
        try await repo.git("add", "b.txt")  // staged
        try repo.write("new 1.txt", "x")  // untracked
        try repo.write("new 2.txt", "y")
        try await repo.git("rm", "-q", "c.txt")  // staged deletion
        let status = try await open(repo).status()
        #expect(status.summary == StatusSummary(staged: 2, unstaged: 1, untracked: 2))
        // Cross-check against git itself.
        let porcelain = try await repo.git("status", "--porcelain=v1")
        #expect(porcelain.split(separator: "\n").count == 5)
    }

    @Test func statusPartiallyStagedFileCountsBoth() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        try repo.write("a.txt", "one\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "two\n")
        let status = try await open(repo).status()
        #expect(status.summary == StatusSummary(staged: 1, unstaged: 1))
    }

    @Test func statusReportsUpstreamAheadBehind() async throws {
        let sandbox = try GitSandbox()
        let upstream = try await cleanRepo(sandbox)
        try await sandbox.git(["clone", "-q", "--", upstream.path, sandbox.root + "/clone"], in: sandbox.root)
        let clone = TestRepo(sandbox: sandbox, path: sandbox.root + "/clone")
        try upstream.write("u.txt", "u")
        try await upstream.commit("Upstream 1")
        try await clone.git("fetch", "-q")
        try await clone.commit("Local 1")
        try await clone.commit("Local 2")
        let status = try await open(clone).status()
        #expect(status.branch.upstream == "origin/main")
        #expect(status.branch.ahead == 2)
        #expect(status.branch.behind == 1)
    }

    @Test func statusDoesNotTouchIndexMtime() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let index = repo.path + "/.git/index"
        // Make the index racy-clean-dirty: rewrite a tracked file with the same size after the index
        // was written, which normally makes `git status` refresh (rewrite) the index.
        try await Task.sleep(for: .milliseconds(1100))
        try repo.write("a.txt", "a\n")
        let before = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
        let handle = try await open(repo)
        _ = try await handle.status()
        await handle.invalidate([.worktree])
        _ = try await handle.status()
        let after = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
        #expect(before == after)
        #expect(!FileManager.default.fileExists(atPath: index + ".lock"))

        // Control: plain `git status` (optional locks allowed) does rewrite it in the same situation,
        // proving the test can detect the feedback loop.
        try await Task.sleep(for: .milliseconds(1100))
        try repo.write("b.txt", "b\n")
        _ = try await repo.sandbox.engine.run(GitCommand(["status"], in: repo.path, kind: .write))
        let control = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
        #expect(control != after)
    }

    @Test func operationStateMerge() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        try await repo.git("checkout", "-q", "-b", "other")
        try repo.write("a.txt", "other\n")
        try await repo.commit("Other")
        try await repo.git("checkout", "-q", "main")
        try repo.write("a.txt", "main\n")
        try await repo.commit("Main")
        _ = try? await repo.git("merge", "other")
        let status = try await open(repo).status()
        #expect(status.operation == .merging)
        #expect(status.summary?.conflicted == 1)
    }

    @Test func operationStateRebaseWithProgress() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        try await repo.git("checkout", "-q", "-b", "topic")
        try repo.write("t1.txt", "1")
        try await repo.commit("T1")
        try repo.write("a.txt", "topic\n")
        try await repo.commit("T2")
        try repo.write("t3.txt", "3")
        try await repo.commit("T3")
        try await repo.git("checkout", "-q", "main")
        try repo.write("a.txt", "main\n")
        try await repo.commit("Main")
        try await repo.git("checkout", "-q", "topic")
        _ = try? await repo.git("rebase", "main")
        let status = try await open(repo).status()
        #expect(status.operation == .rebasing(step: 2, total: 3))
        #expect(status.branch.isDetached)
    }

    @Test func operationStateCherryPick() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        try await repo.git("checkout", "-q", "-b", "other")
        try repo.write("a.txt", "other\n")
        let pick = try await repo.commit("Other")
        try await repo.git("checkout", "-q", "main")
        try repo.write("a.txt", "main\n")
        try await repo.commit("Main")
        _ = try? await repo.git("cherry-pick", pick)
        #expect(try await open(repo).status().operation == .cherryPicking)
    }

    @Test func operationStateRevert() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        try repo.write("a.txt", "v2\n")
        let target = try await repo.commit("V2")
        try repo.write("a.txt", "v3\n")
        try await repo.commit("V3")
        _ = try? await repo.git("revert", "--no-edit", target)
        #expect(try await open(repo).status().operation == .reverting)
    }

    @Test func bareRepositoryHasNoSummary() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let bare = try await repo.bareClone("bare.git")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: bare))
        let status = try await handle.status()
        #expect(status.summary == nil)
        #expect(status.branch.head == "main")
    }

    @Test func linkedWorktreeStatus() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let worktree = try await repo.addWorktree("wt", branch: "feature")
        try TestRepo(sandbox: sandbox, path: worktree).write("w.txt", "w")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: worktree))
        let status = try await handle.status()
        #expect(status.branch.head == "feature")
        #expect(status.summary?.untracked == 1)
    }

    @Test func refreshCoalescesConcurrentRequests() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let handle = try await open(repo)
        let results = try await withThrowingTaskGroup(of: RepositoryStatus.self) { group in
            for _ in 0..<20 { group.addTask { try await handle.status() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 20)
        #expect(await handle.computations == 1)
        // Cached until invalidated.
        _ = try await handle.status()
        #expect(await handle.computations == 1)
        await handle.invalidate([.index])
        _ = try await handle.status()
        #expect(await handle.computations == 2)
    }

    @Test func staleResultDiscardedAfterInvalidate() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let wrapper = try slowGitWrapper(in: sandbox, delay: "0.5")
        let handle = try await open(repo, extra: [:]).reopened(with: wrapper, sandbox: sandbox)
        async let first = handle.status()
        try await Task.sleep(for: .milliseconds(150))
        // The repository changes while the first status is running.
        try repo.write("late.txt", "late")
        await handle.invalidate([.worktree])
        let result = try await first
        // The caller never sees the pre-change result.
        #expect(result.summary?.untracked == 1)
        #expect(await handle.computations == 2)
    }

    @Test func cancellingRefreshKillsGitProcess() async throws {
        let sandbox = try GitSandbox()
        let repo = try await cleanRepo(sandbox)
        let marker = sandbox.root + "/still-running"
        let wrapper = try slowGitWrapper(in: sandbox, delay: "3", marker: marker)
        let handle = try await open(repo).reopened(with: wrapper, sandbox: sandbox)
        let task = Task { try await handle.status() }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
        // The wrapper writes the marker only if it survives its sleep.
        try await Task.sleep(for: .seconds(3.5))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// A `git` wrapper (via `JIT_GIT_PATH`, debug builds) that sleeps before `status` runs.
    func slowGitWrapper(in sandbox: GitSandbox, delay: String, marker: String? = nil) throws -> String {
        let real = try GitLocator(configuration: .init(allowsEnvironmentOverride: false)).locate().path
        let path = sandbox.root + "/slow-git"
        let touch = marker.map { "touch '\($0)'" } ?? ":"
        let script = """
            #!/bin/sh
            for a in "$@"; do if [ "$a" = status ]; then sleep \(delay); \(touch); fi; done
            exec '\(real)' "$@"
            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }
}

extension RepositoryHandle {
    /// The same repository through an engine that uses `gitPath`.
    fileprivate func reopened(with gitPath: String, sandbox: GitSandbox) async throws -> RepositoryHandle {
        var configuration = sandbox.engineConfiguration()
        configuration.locator = .init(allowsEnvironmentOverride: true, environment: ["JIT_GIT_PATH": gitPath])
        return RepositoryHandle(info: info, engine: GitEngine(configuration: configuration))
    }
}
