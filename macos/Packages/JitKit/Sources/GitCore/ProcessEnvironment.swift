import Foundation

/// Whether a Git command only reads repository state. Reads set `GIT_OPTIONAL_LOCKS=0` so they never
/// take the index lock that a concurrent write might need.
public enum CommandKind: Sendable {
    case read
    case write
}

/// Builds child environments from scratch (never by copying the parent's environment wholesale).
public enum ProcessEnvironment {
    /// The only variables taken from the parent process.
    public static let inheritedKeys: [String] = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"]

    /// Variables that make every Git invocation non-interactive and parse-stable. Applied last, so
    /// overrides can never re-enable prompts or editors.
    public static let nonInteractive: [String: String] = [
        "LC_ALL": "C",
        "LANG": "C",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS_REQUIRE": "never",
        "GIT_EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
        "GIT_MERGE_AUTOEDIT": "no",
        "GCM_INTERACTIVE": "never",
        "GIT_PAGER": "cat",
        "PAGER": "cat",
    ]

    /// - Parameters:
    ///   - executableDirectory: directory of the Git binary, put first on a minimal `PATH`.
    ///   - overrides: invocation-scoped variables set by Jit itself (test isolation, later identity).
    ///   - parent: the parent environment to take `inheritedKeys` from.
    public static func make(
        executableDirectory: String?,
        kind: CommandKind,
        overrides: [String: String] = [:],
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in inheritedKeys {
            if let value = parent[key] { environment[key] = value }
        }
        let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = executableDirectory.map { "\($0):\(systemPath)" } ?? systemPath
        environment.merge(overrides) { _, override in override }
        environment.merge(nonInteractive) { _, fixed in fixed }
        if kind == .read { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        return environment
    }
}
