import Foundation
import GitCore

/// A temporary directory with an isolated Git configuration. The developer's `~/.gitconfig`, system
/// config and identity never leak into tests. Removed on `deinit`.
public final class GitSandbox: Sendable {
    /// Real path (symlinks resolved, e.g. `/private/var/...`) so it compares equal to Git's output.
    public let root: String
    public let environment: [String: String]
    public let engine: GitEngine

    public init(extraEnvironment: [String: String] = [:]) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("jit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath(3), not URL.resolvingSymlinksInPath (which maps /private/var back to /var).
        guard let resolved = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        root = String(cString: resolved)
        free(resolved)
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let globalConfig = root + "/gitconfig"
        // Only what makes fixtures deterministic; nothing from the developer's machine.
        try "[init]\n\tdefaultBranch = main\n".write(toFile: globalConfig, atomically: true, encoding: .utf8)

        let fixedDate = "2026-01-01T12:00:00Z"
        var environment: [String: String] = [
            "HOME": home,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": globalConfig,
            "GIT_AUTHOR_NAME": "Jit Tests",
            "GIT_AUTHOR_EMAIL": "tests@jit.invalid",
            "GIT_AUTHOR_DATE": fixedDate,
            "GIT_COMMITTER_NAME": "Jit Tests",
            "GIT_COMMITTER_EMAIL": "tests@jit.invalid",
            "GIT_COMMITTER_DATE": fixedDate,
        ]
        // Release check (P7.3): trace every Git child into one file to catch helpers missing from the
        // pruned bundled Git (`scripts/build/test-bundled-git.sh --suite`).
        if let trace = ProcessInfo.processInfo.environment["JIT_TEST_GIT_TRACE"], trace.hasPrefix("/") {
            environment["GIT_TRACE"] = trace
        }
        environment.merge(extraEnvironment) { _, extra in extra }
        self.environment = environment
        engine = GitEngine(configuration: .init(environmentOverrides: environment))
    }

    deinit {
        // Restore permissions changed by tests (e.g. permission-denied fixtures) so removal succeeds.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                chmod(root + "/" + relative, 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// An engine configuration with this sandbox's isolation plus `extra` variables.
    public func engineConfiguration(extra: [String: String] = [:]) -> GitEngine.Configuration {
        GitEngine.Configuration(environmentOverrides: environment.merging(extra) { _, new in new })
    }

    /// Runs Git in `directory` with the sandbox environment.
    @discardableResult
    public func git(_ arguments: [String], in directory: String) async throws -> String {
        let output = try await engine.run(GitCommand(arguments, in: directory, kind: .write))
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func makeDirectory(_ relativePath: String) throws -> String {
        let path = root + "/" + relativePath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `git init` a new repository at `relativePath`.
    public func makeRepository(_ relativePath: String = "repo") async throws -> TestRepo {
        let path = try makeDirectory(relativePath)
        try await git(["init", "-q"], in: path)
        return TestRepo(sandbox: self, path: path)
    }
}

/// A real repository inside a `GitSandbox`.
public struct TestRepo: Sendable {
    public let sandbox: GitSandbox
    public let path: String

    public init(sandbox: GitSandbox, path: String) {
        self.sandbox = sandbox
        self.path = path
    }

    public func write(_ relativePath: String, _ contents: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    public func git(_ arguments: String...) async throws -> String {
        try await sandbox.git(arguments, in: path)
    }

    /// Stages everything and commits; returns the new commit SHA.
    @discardableResult
    public func commit(_ message: String) async throws -> String {
        try await git("add", "-A")
        try await git("commit", "-q", "--allow-empty", "-m", message)
        return try await git("rev-parse", "HEAD")
    }

    public func branch(_ name: String) async throws {
        try await git("branch", "--", name)
    }

    /// Adds a linked worktree on a new branch; returns its path.
    public func addWorktree(_ name: String, branch: String) async throws -> String {
        let worktree = sandbox.root + "/" + name
        try await git("worktree", "add", "-q", "-b", branch, "--", worktree)
        return worktree
    }

    /// `git clone --bare` into the sandbox; returns the bare repository's path.
    public func bareClone(_ name: String) async throws -> String {
        let destination = sandbox.root + "/" + name
        try await sandbox.git(["clone", "-q", "--bare", "--", path, destination], in: sandbox.root)
        return destination
    }
}
