import Foundation

/// How a remote operation authenticates. `.nonInteractive` (no profile auth): ssh-agent keys and public
/// HTTPS work, everything else fails fast (ADR-0032). `.profile`: credentials, SSH key, CA and proxy are
/// resolved per remote URL from the profile snapshot captured at enqueue (Phase 5, ADR-0016/0036).
public enum AuthPlan: Sendable, Hashable {
    case nonInteractive
    case profile(RemoteAccessProviderRef)
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
    public static func remoteVariables(_ access: RemoteAccess?) -> [String: String] {
        // `GIT_PROTOCOL_FROM_USER=0` is deliberately not set: it also blocks top-level `file://` remotes (Git's
        // default `file` policy is "user"), and Jit never recurses into submodules in V1 (ADR-0032).
        var variables: [String: String] = [
            "GCM_INTERACTIVE": "never",
            "SSH_ASKPASS_REQUIRE": "never",
        ]
        guard let access else {
            variables["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
            return variables
        }
        if let broker = access.broker {
            variables["JIT_BROKER_SOCKET"] = broker.socketPath
            variables["JIT_BROKER_NONCE"] = broker.nonce
        }
        if let ssh = access.ssh {
            // GIT_SSH_COMMAND (not GIT_SSH) because it outranks a user's `core.sshCommand`; the only shell word
            // is Jit's own quoted helper path. Keys and hosts travel in JIT_SSH_* variables, never through a shell.
            variables["GIT_SSH_COMMAND"] = shellQuote(access.helperPath)
            variables["GIT_SSH_VARIANT"] = "ssh"
            variables["JIT_HELPER_MODE"] = "ssh"
            if let key = ssh.keyPath { variables["JIT_SSH_KEY"] = key }
            variables["JIT_SSH_AGENT"] = ssh.useAgent ? "1" : "0"
            variables["JIT_SSH_KNOWN_HOSTS"] = ssh.knownHostsFiles.joined(separator: "\n")
            variables["JIT_SSH_STRICT"] = ssh.strictConfig ? "1" : "0"
            if let proxy = ssh.proxy {
                variables["JIT_SSH_PROXY"] = "\(proxy.kind.rawValue) \(proxy.host):\(proxy.port)"
            }
            // Passphrase prompts: the helper sets SSH_ASKPASS to itself for ssh only (Git's own environment keeps
            // askpass disabled — ProcessEnvironment.nonInteractive is applied last).
        } else {
            variables["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
        }
        return variables
    }

    /// `-c` options for remote commands: inherited credential helpers are always cleared (an `osxkeychain` or
    /// GCM helper from system/global config would answer with whatever account it last stored — a silent
    /// wrong-account success, ADR-0016); the Jit helper is installed only when the plan asks for it.
    public static func remoteConfiguration(_ access: RemoteAccess?) -> [String] {
        var options = ["-c", "credential.helper="]
        if let access {
            if access.httpsCredentials {
                options += [
                    // `!` = a shell snippet (a quoted path would otherwise be read as `git credential-<name>`).
                    "-c", "credential.helper=!\(shellQuote(access.helperPath)) credential",
                    "-c", "credential.useHttpPath=false",
                    "-c", "credential.interactive=false",
                ]
            }
            for scope in access.network {
                if let caInfo = scope.caInfo { options += ["-c", "http.\(scope.urlPrefix).sslCAInfo=\(caInfo)"] }
                switch scope.proxy {
                case .unchanged: break
                case .direct: options += ["-c", "http.\(scope.urlPrefix).proxy="]
                case .url(let url): options += ["-c", "http.\(scope.urlPrefix).proxy=\(url)"]
                }
            }
        }
        return options
    }

    /// Single-quotes a word for `sh` (Git runs credential helpers and `GIT_SSH_COMMAND` through a shell). Only
    /// used for Jit's own helper path.
    static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    /// `access` comes from `ExecContext.prepareAccess` (nil: no profile auth).
    public static func remoteCommand(
        _ arguments: [String], in directory: String, context: ExecContext, access: RemoteAccess? = nil,
        stdoutLimit: Int = 16 * 1024 * 1024, acceptedExitCodes: Set<Int32> = [0]
    ) -> GitCommand {
        var command = GitCommand(
            protocolPolicy + remoteConfiguration(access) + arguments, in: directory, kind: .write, timeout: nil,
            stdoutLimit: stdoutLimit, acceptedExitCodes: acceptedExitCodes)
        command.environment = remoteVariables(access)
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
