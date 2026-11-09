import Foundation
import Synchronization
import Testing

@testable import GitCore

@Suite struct GitVersionTests {
    @Test func parsesPlainVersion() throws {
        let version = try #require(GitVersion(parsing: "git version 2.54.0\n"))
        #expect(version == GitVersion(major: 2, minor: 54, patch: 0))
        #expect(version.vendorSuffix == nil)
        #expect(version.displayString == "2.54.0")
    }

    @Test func parsesAppleGitSuffix() throws {
        let version = try #require(GitVersion(parsing: "git version 2.39.5 (Apple Git-154)"))
        #expect(version == GitVersion(major: 2, minor: 39, patch: 5))
        #expect(version.vendorSuffix == "(Apple Git-154)")
    }

    @Test func parsesWindowsSuffix() throws {
        let version = try #require(GitVersion(parsing: "git version 2.45.1.windows.1"))
        #expect(version == GitVersion(major: 2, minor: 45, patch: 1))
        #expect(version.vendorSuffix == "windows.1")
    }

    @Test(arguments: ["", "git", "version 2.4.0", "git version ", "git version abc", "hub version 2.1.0"])
    func rejectsGarbage(_ input: String) {
        #expect(GitVersion(parsing: input) == nil)
    }

    @Test func comparesAgainstMinimum() throws {
        #expect(GitVersion.minimum == GitVersion(major: 2, minor: 39, patch: 0))
        #expect(try #require(GitVersion(parsing: "git version 2.38.9")) < .minimum)
        #expect(try #require(GitVersion(parsing: "git version 2.39.0")) >= .minimum)
        #expect(try #require(GitVersion(parsing: "git version 3.0.0")) > .minimum)
    }
}

/// A fake filesystem: a set of executable paths and symlinks. Records every path it is asked about.
final class FakeProbe: FileProbe {
    let executables: Set<String>
    let links: [String: String]
    let queries = Mutex<[String]>([])

    init(executables: Set<String>, links: [String: String] = [:]) {
        self.executables = executables
        self.links = links
    }

    func isExecutableFile(_ path: String) -> Bool {
        queries.withLock { $0.append(path) }
        return executables.contains(path)
    }

    func symbolicLinkDestination(_ path: String) -> String? {
        queries.withLock { $0.append(path) }
        return links[path]
    }
}

@Suite struct GitLocatorTests {
    func locate(
        _ probe: FakeProbe, debug: Bool = true, environment: [String: String] = [:]
    ) throws(GitCoreError) -> GitLocation {
        let configuration = GitLocator.Configuration(allowsEnvironmentOverride: debug, environment: environment)
        return try GitLocator(configuration: configuration, probe: probe).locate()
    }

    @Test func prefersEnvOverrideInDebug() throws {
        let probe = FakeProbe(executables: ["/custom/git", "/opt/homebrew/bin/git"])
        let location = try locate(probe, environment: ["JIT_GIT_PATH": "/custom/git"])
        #expect(location == GitLocation(path: "/custom/git", source: .environmentOverride))
    }

    @Test func ignoresEnvOverrideInRelease() throws {
        let probe = FakeProbe(executables: ["/custom/git", "/Jit.app/Contents/Resources/git/bin/git"])
        let configuration = GitLocator.Configuration(
            allowsEnvironmentOverride: false, environment: ["JIT_GIT_PATH": "/custom/git"],
            bundledGitPath: "/Jit.app/Contents/Resources/git/bin/git")
        let location = try GitLocator(configuration: configuration, probe: probe).locate()
        #expect(location.source == .bundled)
    }

    @Test func gitLocatorPrefersCustomThenBundled() throws {
        let bundled = "/Jit.app/Contents/Resources/git/bin/git"
        let probe = FakeProbe(executables: ["/custom/git", bundled, "/opt/homebrew/bin/git"])
        var configuration = GitLocator.Configuration(
            allowsEnvironmentOverride: false, environment: [:], bundledGitPath: bundled, userOverridePath: "/custom/git"
        )
        #expect(try GitLocator(configuration: configuration, probe: probe).locate().source == .userOverride)
        // A custom Git that disappeared falls back to the bundled one.
        configuration.userOverridePath = "/gone/git"
        #expect(
            try GitLocator(configuration: configuration, probe: probe).locate()
                == GitLocation(path: bundled, source: .bundled))
    }

    @Test func releaseIgnoresHomebrewAndUsesInstalledDeveloperTools() throws {
        let probe = FakeProbe(executables: ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"])
        let release = GitLocator.Configuration(allowsEnvironmentOverride: false, environment: [:])
        #expect(throws: GitCoreError.gitNotFound) { try GitLocator(configuration: release, probe: probe).locate() }
        let withCLT = FakeProbe(executables: ["/opt/homebrew/bin/git", "/usr/bin/git", GitLocator.commandLineToolsGit])
        #expect(
            try GitLocator(configuration: release, probe: withCLT).locate()
                == GitLocation(path: GitLocator.commandLineToolsGit, source: .system))
    }

    @Test func gitLocatorSkipsXcrunShimWithoutCLT() {
        // Release configuration, no bundled Git, no CLT: the shim must never be chosen (it would prompt).
        let probe = FakeProbe(executables: ["/usr/bin/git"])
        let release = GitLocator.Configuration(allowsEnvironmentOverride: false, environment: [:])
        #expect(throws: GitCoreError.gitNotFound) { try GitLocator(configuration: release, probe: probe).locate() }
        #expect(!probe.queries.withLock { $0.contains("/usr/bin/git") })
    }

    @Test func prefersHomebrewOverUsrBin() throws {
        let probe = FakeProbe(executables: [
            "/opt/homebrew/bin/git", "/usr/bin/git", GitLocator.commandLineToolsGit,
        ])
        #expect(try locate(probe) == GitLocation(path: "/opt/homebrew/bin/git", source: .homebrew))
    }

    @Test func usesCommandLineToolsGitDirectly() throws {
        let probe = FakeProbe(executables: ["/usr/bin/git", GitLocator.commandLineToolsGit])
        #expect(try locate(probe) == GitLocation(path: GitLocator.commandLineToolsGit, source: .system))
    }

    @Test func usesSelectedXcodeGitDirectly() throws {
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let probe = FakeProbe(
            executables: ["/usr/bin/git", developer + "/usr/bin/git", GitLocator.commandLineToolsGit],
            links: [GitLocator.xcodeSelectLink: developer])
        #expect(try locate(probe) == GitLocation(path: developer + "/usr/bin/git", source: .system))
    }

    @Test func honorsDeveloperDirPointingAtAppBundle() throws {
        let probe = FakeProbe(executables: ["/Apps/Xcode-beta.app/Contents/Developer/usr/bin/git"])
        let location = try locate(probe, environment: ["DEVELOPER_DIR": "/Apps/Xcode-beta.app"])
        #expect(location.path == "/Apps/Xcode-beta.app/Contents/Developer/usr/bin/git")
    }

    @Test func neverReturnsTheShim() {
        let probe = FakeProbe(executables: ["/usr/bin/git"], links: [GitLocator.xcodeSelectLink: "/Removed/Xcode"])
        #expect(throws: GitCoreError.gitNotFound) { try locate(probe) }
    }

    @Test func skipsUsrBinGitWhenCLTMissing() {
        // `/usr/bin/git` is the xcrun shim; without CLT/Xcode, running it would open an install dialog.
        let probe = FakeProbe(executables: ["/usr/bin/git"])
        #expect(throws: GitCoreError.gitNotFound) { try locate(probe) }
    }

    @Test func reportsNotFound() {
        #expect(throws: GitCoreError.gitNotFound) { try locate(FakeProbe(executables: [])) }
    }

    @Test func probesVersionLazily() async throws {
        let probe = FakeProbe(executables: [])
        let engine = GitEngine(configuration: .init(probe: probe))
        // Creating the engine must not touch the filesystem or run anything.
        #expect(probe.queries.withLock { $0.isEmpty })
        await #expect(throws: GitCoreError.gitNotFound) { try await engine.gitInfo() }
        #expect(probe.queries.withLock { !$0.isEmpty })
    }

    @Test func realMachineGitMeetsMinimum() async throws {
        // Documents which Git `swift test` uses on this machine/CI runner.
        let info = try await GitEngine().gitInfo()
        print("GitCore uses \(info.path) (\(info.source.rawValue)), version \(info.version.displayString)")
        #expect(info.version >= .minimum)
    }
}

/// `GitEngine.validateGit(at:)` and `setUserGitPath(_:)` against tiny fake Git scripts.
@Suite struct GitValidationTests {
    func fakeGit(version: String, execPath: String? = nil) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jit-fake-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exec = execPath ?? directory.path
        let script = """
            #!/bin/sh
            case "$1" in
              --version) echo "git version \(version)" ;;
              --exec-path) echo "\(exec)" ;;
              *) exit 1 ;;
            esac
            """
        let path = directory.appendingPathComponent("git").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    @Test func gitLocatorRejectsOldVersion() async throws {
        let engine = GitEngine()
        let old = try fakeGit(version: "2.20.0")
        await #expect(
            throws: GitCoreError.gitTooOld(found: GitVersion(parsing: "git version 2.20.0")!, required: .minimum)
        ) {
            try await engine.validateGit(at: old)
        }
    }

    @Test func validationRejectsMissingExecPathAndMissingFile() async throws {
        let engine = GitEngine()
        let broken = try fakeGit(version: "2.50.0", execPath: "/nonexistent/libexec/git-core")
        await #expect(throws: GitCoreError.self) { try await engine.validateGit(at: broken) }
        await #expect(throws: GitCoreError.pathNotFound(path: "/nonexistent/git")) {
            try await engine.validateGit(at: "/nonexistent/git")
        }
    }

    @Test func setUserGitPathSwitchesTheGitInUse() async throws {
        let first = try fakeGit(version: "2.50.0")
        let second = try fakeGit(version: "2.51.1")
        let engine = GitEngine(
            configuration: .init(
                locator: .init(allowsEnvironmentOverride: false, environment: [:], userOverridePath: first)))
        #expect(try await engine.validateGit(at: second).version.displayString == "2.51.1")
        #expect(try await engine.gitInfo().path == first)
        await engine.setUserGitPath(second)
        let info = try await engine.gitInfo()
        #expect(info.path == second)
        #expect(info.source == .userOverride)
    }
}
