import Foundation

/// Filesystem questions the locator asks. Injected so tests can model machines without Git/CLT.
public protocol FileProbe: Sendable {
    func isExecutableFile(_ path: String) -> Bool
    func symbolicLinkDestination(_ path: String) -> String?
}

public struct SystemFileProbe: FileProbe {
    public init() {}

    public func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    public func symbolicLinkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}

/// Where a Git executable came from, in locator priority order.
public enum GitSource: String, Sendable {
    case environmentOverride = "JIT_GIT_PATH"
    case bundled = "Bundled"
    case userOverride = "User setting"
    case homebrew = "Homebrew"
    case usrLocal = "/usr/local"
    /// Apple's Git inside the selected Xcode or the Command Line Tools.
    case system = "Apple developer tools"
}

public struct GitLocation: Sendable, Equatable {
    public let path: String
    public let source: GitSource
}

/// Finds a Git binary by **file existence only**. It never executes anything: running `/usr/bin/git`
/// (or `xcrun`) on a Mac without the Command Line Tools pops the "install developer tools" dialog.
public struct GitLocator: Sendable {
    public struct Configuration: Sendable {
        /// `JIT_GIT_PATH` is honored only when this is true (debug builds).
        public var allowsEnvironmentOverride: Bool
        public var environment: [String: String]
        /// `Contents/Resources/git/bin/git` inside the app bundle — wired in Phase 7.
        public var bundledGitPath: String?
        /// User-chosen Git — a Phase 6 preference.
        public var userOverridePath: String?

        public init(
            allowsEnvironmentOverride: Bool,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            bundledGitPath: String? = nil,
            userOverridePath: String? = nil
        ) {
            self.allowsEnvironmentOverride = allowsEnvironmentOverride
            self.environment = environment
            self.bundledGitPath = bundledGitPath
            self.userOverridePath = userOverridePath
        }
    }

    public static let commandLineToolsGit = "/Library/Developer/CommandLineTools/usr/bin/git"
    public static let xcodeSelectLink = "/var/db/xcode_select_link"

    public let configuration: Configuration
    public let probe: any FileProbe

    public init(configuration: Configuration, probe: any FileProbe = SystemFileProbe()) {
        self.configuration = configuration
        self.probe = probe
    }

    public func locate() throws(GitCoreError) -> GitLocation {
        if configuration.allowsEnvironmentOverride, let path = configuration.environment["JIT_GIT_PATH"],
            probe.isExecutableFile(path)
        {
            return GitLocation(path: path, source: .environmentOverride)
        }
        if let path = configuration.bundledGitPath, probe.isExecutableFile(path) {
            return GitLocation(path: path, source: .bundled)
        }
        if let path = configuration.userOverridePath, probe.isExecutableFile(path) {
            return GitLocation(path: path, source: .userOverride)
        }
        if probe.isExecutableFile("/opt/homebrew/bin/git") {
            return GitLocation(path: "/opt/homebrew/bin/git", source: .homebrew)
        }
        if probe.isExecutableFile("/usr/local/bin/git") {
            return GitLocation(path: "/usr/local/bin/git", source: .usrLocal)
        }
        if let path = developerToolsGit() {
            return GitLocation(path: path, source: .system)
        }
        throw .gitNotFound
    }

    /// Apple's real Git binary — never the `/usr/bin/git` shim, which would consult `xcode-select`
    /// (and could pop the install dialog) at run time. Prefers the developer directory the shim would
    /// use (`DEVELOPER_DIR`, else the `xcode-select` link), then the Command Line Tools.
    func developerToolsGit() -> String? {
        let developerDirectory =
            configuration.environment["DEVELOPER_DIR"]
            ?? probe.symbolicLinkDestination(Self.xcodeSelectLink)
        if let developerDirectory, !developerDirectory.isEmpty {
            // DEVELOPER_DIR may name either `…/Contents/Developer` or the `Xcode.app` bundle itself.
            for candidate in [
                developerDirectory + "/usr/bin/git", developerDirectory + "/Contents/Developer/usr/bin/git",
            ]
            where probe.isExecutableFile(candidate) {
                return candidate
            }
        }
        return probe.isExecutableFile(Self.commandLineToolsGit) ? Self.commandLineToolsGit : nil
    }
}
