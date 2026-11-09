import Foundation

/// How a remote operation authenticates. Phase 4 never authenticates interactively: ssh-agent keys and
/// public HTTPS work, everything else fails fast (ADR-0032). Phase 5 adds credentialed plans here without
/// touching call sites.
public enum AuthPlan: Sendable, Hashable {
    case nonInteractive
}

/// Network policy for a remote operation. Phase 5 adds scoped CA and proxy settings.
public enum NetworkPlan: Sendable, Hashable {
    case systemDefault
}

/// Everything a Git invocation needs beyond its argv (design §4.3): who commits, how to authenticate and
/// which network policy applies. Captured once when an operation is enqueued (profile snapshot), immutable.
public struct ExecContext: Sendable, Hashable {
    /// Author/committer for commit-creating operations; `nil` when no profile is active.
    public var identity: IdentitySnapshot?
    public var auth: AuthPlan
    public var network: NetworkPlan

    public init(identity: IdentitySnapshot?, auth: AuthPlan = .nonInteractive, network: NetworkPlan = .systemDefault) {
        self.identity = identity
        self.auth = auth
        self.network = network
    }

    /// No identity: only for operations that create no commits (fetch, push, clone, branch ops).
    public static let anonymous = ExecContext(identity: nil)

    /// The identity, or `.noActiveProfile` (commit-creating operations are blocked without one).
    public func requireIdentity() throws(GitCoreError) -> IdentitySnapshot {
        guard let identity else { throw .noActiveProfile }
        return identity
    }
}

/// How a commit-creating operation applies the profile identity (ADR-0028): the committer is always the
/// profile; the author only for commits Jit creates itself (merge commits, reverts). Cherry-pick and rebase
/// keep the original authors, as Git does.
public enum IdentityUse: Sendable {
    case none
    case committerOnly
    case authorAndCommitter
}

/// Builds the invocation-scoped environment and options for commands that may touch the network or create
/// commits (design §4.3, ADR-0032). Every value is a fixed literal or comes from the identity snapshot —
/// nothing user-derived reaches `-c` options.
public enum GitEnvironment {
    /// Disables transports that run arbitrary commands. Hooks are not overridden (ADR-0014).
    public static let protocolPolicy = ["-c", "protocol.ext.allow=never", "-c", "protocol.fd.allow=never"]

    /// Variables for remote commands under `.nonInteractive` (step 2 and 3 of design §4.3). The base
    /// non-interactive variables (`GIT_TERMINAL_PROMPT=0`, failing askpass, no editors, C locale) come from
    /// `ProcessEnvironment` for every command.
    static func remoteVariables(_ context: ExecContext) -> [String: String] {
        // `GIT_PROTOCOL_FROM_USER=0` is deliberately not set: it also blocks top-level `file://` remotes (Git's
        // default `file` policy is "user"), and Jit never recurses into submodules in V1 (ADR-0032).
        var variables: [String: String] = [
            "GCM_INTERACTIVE": "never",
            "SSH_ASKPASS_REQUIRE": "never",
        ]
        switch context.auth {
        case .nonInteractive:
            variables["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
        }
        switch context.network {
        case .systemDefault: break
        }
        return variables
    }

    static func identityVariables(_ identity: IdentitySnapshot, use: IdentityUse) -> [String: String] {
        switch use {
        case .none:
            return [:]
        case .committerOnly:
            return ["GIT_COMMITTER_NAME": identity.committer.name, "GIT_COMMITTER_EMAIL": identity.committer.email]
        case .authorAndCommitter:
            return [
                "GIT_COMMITTER_NAME": identity.committer.name, "GIT_COMMITTER_EMAIL": identity.committer.email,
                "GIT_AUTHOR_NAME": identity.author.name, "GIT_AUTHOR_EMAIL": identity.author.email,
            ]
        }
    }

    /// A command that may contact a remote: protocol policy, non-interactive auth, no timeout (a progressing
    /// transfer is never killed; cancellation is the user's).
    public static func remoteCommand(
        _ arguments: [String], in directory: String, context: ExecContext, stdoutLimit: Int = 16 * 1024 * 1024,
        acceptedExitCodes: Set<Int32> = [0]
    ) -> GitCommand {
        var command = GitCommand(
            protocolPolicy + arguments, in: directory, kind: .write, timeout: nil, stdoutLimit: stdoutLimit,
            acceptedExitCodes: acceptedExitCodes)
        command.environment = remoteVariables(context)
        return command
    }

    /// A local command that may create commits with the snapshot's identity.
    static func integrationCommand(
        _ arguments: [String], in directory: String, identity: IdentitySnapshot?, use: IdentityUse,
        acceptedExitCodes: Set<Int32> = [0], stdin: [UInt8]? = nil
    ) -> GitCommand {
        var command = GitCommand(
            arguments, in: directory, kind: .write, timeout: nil, stdoutLimit: 16 * 1024 * 1024,
            acceptedExitCodes: acceptedExitCodes, stdin: stdin)
        if let identity { command.environment = identityVariables(identity, use: use) }
        return command
    }
}
