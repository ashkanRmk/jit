import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Shared Phase 4 fixtures: real repositories, local bare remotes (`file://`), two clones.
enum Ops {
    static let ada = IdentitySnapshot(
        author: GitIdentity(name: "Ada Lovelace", email: "ada@profile.example"),
        committer: GitIdentity(name: "Ada Lovelace", email: "ada@profile.example"))
    static let context = ExecContext(identity: ada)

    struct World {
        let sandbox: GitSandbox
        let origin: String
        let a: TestRepo
        let b: TestRepo
        let handleA: RepositoryHandle
        let handleB: RepositoryHandle
    }

    static func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        try await GitEngine(configuration: repo.sandbox.engineConfiguration()).openRepository(
            at: URL(fileURLWithPath: repo.path))
    }

    /// One repository with an initial commit (`a.txt`).
    static func single(_ files: [String: String] = ["a.txt": "one\ntwo\nthree\n"]) async throws
        -> (GitSandbox, TestRepo, RepositoryHandle)
    {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        return (sandbox, repo, try await open(repo))
    }

    /// `origin` (bare) with `main`, cloned twice (`a`, `b`).
    static func world() async throws -> World {
        let sandbox = try GitSandbox()
        let seed = try await sandbox.makeRepository("seed")
        try seed.write("a.txt", "one\ntwo\nthree\n")
        try await seed.commit("Initial")
        let origin = try await seed.bareClone("origin.git")
        try await sandbox.git(["clone", "-q", "--", origin, sandbox.root + "/a"], in: sandbox.root)
        try await sandbox.git(["clone", "-q", "--", origin, sandbox.root + "/b"], in: sandbox.root)
        let a = TestRepo(sandbox: sandbox, path: sandbox.root + "/a")
        let b = TestRepo(sandbox: sandbox, path: sandbox.root + "/b")
        return World(
            sandbox: sandbox, origin: origin, a: a, b: b, handleA: try await open(a), handleB: try await open(b))
    }

    /// `main` and `feature` both edit line two of `a.txt`; HEAD on `main`.
    static func conflicting() async throws -> (GitSandbox, TestRepo, RepositoryHandle) {
        let (sandbox, repo, handle) = try await single()
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("a.txt", "one\nTWO (feature)\nthree\n")
        try await repo.commit("Feature edit")
        try await repo.git("switch", "-q", "main")
        try repo.write("a.txt", "one\nTWO (main)\nthree\n")
        try await repo.commit("Main edit")
        return (sandbox, repo, handle)
    }

    static func read(_ repo: TestRepo, _ path: String) throws -> String {
        try String(contentsOfFile: repo.path + "/" + path, encoding: .utf8)
    }
}
