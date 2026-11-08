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
        let probe = FakeProbe(executables: ["/custom/git", "/opt/homebrew/bin/git"])
        let location = try locate(probe, debug: false, environment: ["JIT_GIT_PATH": "/custom/git"])
        #expect(location.source == .homebrew)
    }

    @Test func prefersHomebrewOverUsrBin() throws {
        let probe = FakeProbe(executables: [
            "/opt/homebrew/bin/git", "/usr/bin/git", GitLocator.commandLineToolsGit,
        ])
        #expect(try locate(probe) == GitLocation(path: "/opt/homebrew/bin/git", source: .homebrew))
    }

    @Test func usesUsrBinWhenCLTPresent() throws {
        let probe = FakeProbe(executables: ["/usr/bin/git", GitLocator.commandLineToolsGit])
        #expect(try locate(probe) == GitLocation(path: "/usr/bin/git", source: .system))
    }

    @Test func usesUsrBinWhenSelectedXcodeHasGit() throws {
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let probe = FakeProbe(
            executables: ["/usr/bin/git", developer + "/usr/bin/git"],
            links: [GitLocator.xcodeSelectLink: developer])
        #expect(try locate(probe).source == .system)
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
