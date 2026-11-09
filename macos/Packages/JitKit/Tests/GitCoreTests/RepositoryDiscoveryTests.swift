import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Integration tests against real repositories created by `GitTestKit`.
@Suite struct RepositoryDiscoveryTests {
    func discover(_ path: String, in sandbox: GitSandbox, extra: [String: String] = [:]) async throws(GitCoreError)
        -> RepositoryInfo
    {
        let engine = GitEngine(configuration: sandbox.engineConfiguration(extra: extra))
        return try await engine.discoverRepository(at: URL(fileURLWithPath: path))
    }

    @Test func discoversRegularRepo() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("project")
        try repo.write("README.md", "hello\n")
        let sha = try await repo.commit("Initial commit")

        let info = try await discover(repo.path, in: sandbox)
        #expect(info.kind == .regular)
        #expect(info.topLevel == repo.path)
        #expect(info.gitDirectory == repo.path + "/.git")
        #expect(info.commonDirectory == repo.path + "/.git")
        #expect(info.head == .branch(name: "main", commit: sha))
        #expect(info.displayName == "project")
    }

    @Test func discoversFromSubdirectory() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a/b/file.txt", "x")
        try await repo.commit("Add file")
        let info = try await discover(repo.path + "/a/b", in: sandbox)
        #expect(info.topLevel == repo.path)
        #expect(info.kind == .regular)
    }

    @Test func discoversGitDirectoryItself() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try await repo.commit("Initial")
        let info = try await discover(repo.path + "/.git", in: sandbox)
        #expect(info.kind == .regular)
        #expect(info.topLevel == repo.path)
    }

    @Test func discoversBareRepo() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let sha = try await repo.commit("Initial")
        let bare = try await repo.bareClone("mirror.git")

        let info = try await discover(bare, in: sandbox)
        #expect(info.kind == .bare)
        #expect(info.topLevel == nil)
        #expect(info.gitDirectory == bare)
        #expect(info.head == .branch(name: "main", commit: sha))
        #expect(info.displayName == "mirror")
    }

    @Test func discoversLinkedWorktree() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let sha = try await repo.commit("Initial")
        let worktree = try await repo.addWorktree("feature-tree", branch: "feature/x")

        let info = try await discover(worktree, in: sandbox)
        #expect(info.kind == .linkedWorktree)
        #expect(info.topLevel == worktree)
        #expect(info.commonDirectory == repo.path + "/.git")
        #expect(info.gitDirectory != info.commonDirectory)
        #expect(info.head == .branch(name: "feature/x", commit: sha))
    }

    @Test func reportsUnbornBranch() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let info = try await discover(repo.path, in: sandbox)
        #expect(info.head == .unborn(branch: "main"))
    }

    @Test func reportsDetachedHead() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let first = try await repo.commit("One")
        try await repo.commit("Two")
        try await repo.git("checkout", "-q", "--detach", first)
        let info = try await discover(repo.path, in: sandbox)
        #expect(info.head == .detached(commit: first))
    }

    @Test func notARepository() async throws {
        let sandbox = try GitSandbox()
        let folder = try sandbox.makeDirectory("plain")
        // Stop discovery from walking above the sandbox, whatever the machine's temp dir is inside.
        await #expect(throws: GitCoreError.notARepository(path: folder)) {
            try await discover(folder, in: sandbox, extra: ["GIT_CEILING_DIRECTORIES": sandbox.root])
        }
    }

    @Test func pathWithSpacesAndUnicode() async throws {
        let sandbox = try GitSandbox()
        let name = "My Repo — café ünïcødé"
        let repo = try await sandbox.makeRepository(name)
        try await repo.commit("Initial")
        let info = try await discover(repo.path, in: sandbox)
        #expect(info.topLevel == repo.path)
        #expect(info.displayName == name)

        // Finder may hand over decomposed (NFD) paths; APFS resolves them to the same folder.
        let decomposed = repo.path.decomposedStringWithCanonicalMapping
        let fromNFD = try await discover(decomposed, in: sandbox)
        #expect(
            fromNFD.topLevel?.precomposedStringWithCanonicalMapping == repo.path.precomposedStringWithCanonicalMapping)
    }

    @Test func permissionDeniedDirectory() async throws {
        let sandbox = try GitSandbox()
        let folder = try sandbox.makeDirectory("locked")
        #expect(chmod(folder, 0o000) == 0)
        await #expect(throws: GitCoreError.permissionDenied(path: folder)) {
            try await discover(folder, in: sandbox)
        }
    }

    @Test func dubiousOwnershipMapsToUnsafeRepository() async throws {
        // GIT_TEST_ASSUME_DIFFERENT_OWNER is Git's own knob for exercising the safe.directory check.
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        await #expect(throws: GitCoreError.unsafeRepository(path: repo.path)) {
            try await discover(repo.path, in: sandbox, extra: ["GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"])
        }
        // Jit must never add a safe.directory exception on its own.
        let config = try String(contentsOfFile: sandbox.root + "/gitconfig", encoding: .utf8)
        #expect(!config.contains("safe"))
    }

    @Test func discoveryHonorsCancellation() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let engine = GitEngine(configuration: sandbox.engineConfiguration())
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await engine.discoverRepository(at: URL(fileURLWithPath: repo.path))
        }
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
    }
}
