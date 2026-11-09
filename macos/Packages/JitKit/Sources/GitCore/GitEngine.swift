import Foundation

/// The Git binary Jit uses, with its probed version.
public struct GitExecutable: Sendable, Equatable {
    public let path: String
    public let version: GitVersion
    public let source: GitSource
}

/// One Git invocation. `arguments` follow the `git` executable and never pass through a shell.
public struct GitCommand: Sendable {
    public var arguments: [String]
    public var workingDirectory: String
    public var kind: CommandKind
    public var timeout: Duration?
    public var stdoutLimit: Int
    public var acceptedExitCodes: Set<Int32>
    /// Written to Git's stdin (`--pathspec-from-file=-`, `commit -F -`); `nil` means `/dev/null`.
    public var stdin: [UInt8]?
    /// Invocation-scoped variables (identity: `GIT_AUTHOR_*` / `GIT_COMMITTER_*`), applied last. Never
    /// secrets (CLAUDE.md), never written anywhere.
    public var environment: [String: String] = [:]
    /// Receives stderr bytes as Git writes them (`--progress` parsing). See `ProcessSpec.stderrObserver`.
    public var stderrObserver: (@Sendable ([UInt8]) -> Void)?

    public init(
        _ arguments: [String],
        in workingDirectory: String,
        kind: CommandKind = .read,
        timeout: Duration? = .seconds(30),
        stdoutLimit: Int = 16 * 1024 * 1024,
        acceptedExitCodes: Set<Int32> = [0],
        stdin: [UInt8]? = nil
    ) {
        self.stdin = stdin
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.kind = kind
        self.timeout = timeout
        self.stdoutLimit = stdoutLimit
        self.acceptedExitCodes = acceptedExitCodes
    }

    /// Options prepended to every invocation: no pager, unquoted UTF-8 paths, no color codes.
    public static let globalOptions = ["--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=false"]
}

/// Entry point to Git for the app. Creating it does no I/O; Git is located and its version probed on
/// first use, off the main actor, and cached for the process lifetime. Failures are not cached, so
/// installing Git while Jit runs works.
public actor GitEngine {
    public struct Configuration: Sendable {
        public var locator: GitLocator.Configuration
        public var probe: any FileProbe
        /// Invocation-scoped variables (test isolation now; per-profile identity in later phases).
        public var environmentOverrides: [String: String]
        public var discoveryTimeout: Duration
        public var terminationGrace: Duration

        public init(
            locator: GitLocator.Configuration = .init(allowsEnvironmentOverride: GitEngine.isDebugBuild),
            probe: any FileProbe = SystemFileProbe(),
            environmentOverrides: [String: String] = [:],
            discoveryTimeout: Duration = .seconds(15),
            terminationGrace: Duration = .seconds(2)
        ) {
            self.locator = locator
            self.probe = probe
            self.environmentOverrides = environmentOverrides
            self.discoveryTimeout = discoveryTimeout
            self.terminationGrace = terminationGrace
        }
    }

    public static let isDebugBuild: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    public nonisolated let configuration: Configuration
    private let runner: ProcessRunner
    /// Where to look for Git; the user's custom Git can change while Jit runs (Settings ▸ Git).
    private var locator: GitLocator.Configuration
    /// Bumped by `setUserGitPath` so a probe that started before the change is not cached.
    private var locatorGeneration = 0
    private var executable: GitExecutable?
    /// One shared probe for concurrent first callers (actor reentrancy would otherwise start several).
    private var probe: Task<Result<GitExecutable, GitCoreError>, Never>?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.runner = ProcessRunner(terminationGrace: configuration.terminationGrace)
        self.locator = configuration.locator
    }

    /// Switches to the user's custom Git (or back to the bundled/default resolution with `nil`). The next
    /// command locates and probes Git again. Validate the path first with `validateGit(at:)`.
    public func setUserGitPath(_ path: String?) {
        locator.userOverridePath = path
        locatorGeneration += 1
        executable = nil
        probe = nil
    }

    /// Checks that `path` is a usable Git without adopting it: it starts, reports a version at least
    /// `GitVersion.minimum`, and its `--exec-path` is an existing directory. Runs Git only at `path`.
    public func validateGit(at path: String) async throws(GitCoreError) -> GitExecutable {
        guard configuration.probe.isExecutableFile(path) else { throw .pathNotFound(path: path) }
        let executable = try await Self.probeVersion(
            GitLocation(path: path, source: .userOverride), configuration, runner)
        let spec = ProcessSpec(
            executable: path,
            arguments: ["--exec-path"],
            workingDirectory: "/",
            environment: Self.environment(for: path, kind: .read, configuration: configuration),
            timeout: .seconds(10),
            stdoutLimit: 4096
        )
        let execPath = try await runner.run(spec).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: execPath, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw .internalError(summary: "The Git at \(path) reports a missing helper directory (\(execPath)).")
        }
        return executable
    }

    /// Locates Git and checks its version against `GitVersion.minimum`.
    public func gitInfo() async throws(GitCoreError) -> GitExecutable {
        if let executable { return executable }
        if Task.isCancelled { throw .cancelled }
        let task =
            probe
            ?? Task { [configuration, locator, runner] in
                await Self.locateAndProbe(locator, configuration, runner)
            }
        probe = task
        let generation = locatorGeneration
        let result = await task.value
        guard generation == locatorGeneration else {
            // The Git choice changed while probing: resolve again with the new choice.
            return try await gitInfo()
        }
        probe = nil
        let found = try result.get()
        executable = found
        return found
    }

    private static func locateAndProbe(
        _ locator: GitLocator.Configuration, _ configuration: Configuration, _ runner: ProcessRunner
    ) async -> Result<GitExecutable, GitCoreError> {
        do throws(GitCoreError) {
            let location = try GitLocator(configuration: locator, probe: configuration.probe).locate()
            return .success(try await probeVersion(location, configuration, runner))
        } catch {
            return .failure(error)
        }
    }

    private static func probeVersion(
        _ location: GitLocation, _ configuration: Configuration, _ runner: ProcessRunner
    ) async throws(GitCoreError) -> GitExecutable {
        let spec = ProcessSpec(
            executable: location.path,
            arguments: ["--version"],
            workingDirectory: "/",
            environment: environment(for: location.path, kind: .read, configuration: configuration),
            timeout: .seconds(10),
            stdoutLimit: 4096
        )
        let output = try await runner.run(spec)
        guard let version = GitVersion(parsing: output.stdoutText) else {
            throw .internalError(summary: "Jit couldn't read the version of the Git at \(location.path).")
        }
        guard version >= GitVersion.minimum else {
            throw .gitTooOld(found: version, required: GitVersion.minimum)
        }
        return GitExecutable(path: location.path, version: version, source: location.source)
    }

    /// Runs one Git command with the located executable.
    public func run(_ command: GitCommand) async throws(GitCoreError) -> ProcessOutput {
        do {
            return try await runOnce(command)
        } catch .launchFailed(let code) where code == ENOENT || code == EACCES {
            // The cached Git vanished (e.g. `brew uninstall git`): locate again once and retry.
            executable = nil
            return try await runOnce(command)
        }
    }

    private func runOnce(_ command: GitCommand) async throws(GitCoreError) -> ProcessOutput {
        let git = try await gitInfo()
        let spec = ProcessSpec(
            executable: git.path,
            arguments: GitCommand.globalOptions + command.arguments,
            workingDirectory: command.workingDirectory,
            environment: Self.environment(for: git.path, kind: command.kind, configuration: configuration)
                .merging(command.environment) { _, invocation in invocation },
            timeout: command.timeout,
            stdoutLimit: command.stdoutLimit,
            acceptedExitCodes: command.acceptedExitCodes,
            stdin: command.stdin,
            stderrObserver: command.stderrObserver
        )
        return try await runner.run(spec)
    }

    /// Starts one long-lived, on-demand-read Git command (history readers). See `ProcessRunner.stream`.
    public func stream(_ command: GitCommand) async throws(GitCoreError) -> ProcessStream {
        let git = try await gitInfo()
        let spec = ProcessSpec(
            executable: git.path,
            arguments: GitCommand.globalOptions + command.arguments,
            workingDirectory: command.workingDirectory,
            environment: Self.environment(for: git.path, kind: command.kind, configuration: configuration),
            acceptedExitCodes: command.acceptedExitCodes
        )
        return runner.stream(spec)
    }

    /// Classifies the folder at `url` (or the repository enclosing it).
    public func discoverRepository(at url: URL) async throws(GitCoreError) -> RepositoryInfo {
        // A missing working directory would otherwise surface as a launch failure.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw .pathNotFound(path: url.path)
        }
        guard isDirectory.boolValue else { throw .notARepository(path: url.path) }
        return try await RepositoryDiscovery(engine: self, timeout: configuration.discoveryTimeout).discover(
            at: url.path)
    }

    private static func environment(
        for gitPath: String, kind: CommandKind, configuration: Configuration
    ) -> [String: String] {
        ProcessEnvironment.make(
            executableDirectory: (gitPath as NSString).deletingLastPathComponent,
            kind: kind,
            overrides: configuration.environmentOverrides
        )
    }
}
