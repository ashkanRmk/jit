import Foundation

/// Who a commit is by, captured from the active profile when the user presses Commit (§6.2): a profile
/// switch while Git runs never changes it. Applied only through the child's environment (ADR-0028).
public struct IdentitySnapshot: Sendable, Hashable {
    public let author: GitIdentity
    public let committer: GitIdentity

    public init(author: GitIdentity, committer: GitIdentity) {
        self.author = author
        self.committer = committer
    }
}

public struct CommitRequest: Sendable, Hashable {
    public var message: String
    public var amend: Bool
    /// With `amend`: the author becomes the profile (otherwise the original author is kept).
    public var resetAuthor: Bool
    /// `--no-verify`: only from the explicit "Commit Without Running Hooks…" (ADR-0014). Never sticky.
    public var noVerify: Bool
    public var identity: IdentitySnapshot

    public init(
        message: String, amend: Bool = false, resetAuthor: Bool = false, noVerify: Bool = false,
        identity: IdentitySnapshot
    ) {
        self.message = message
        self.amend = amend
        self.resetAuthor = resetAuthor
        self.noVerify = noVerify
        self.identity = identity
    }
}

public struct CommitOutcome: Sendable, Equatable {
    public let revision: RepoRevision
    public let commitID: String
    /// What Git and the hooks printed (sanitized of nothing: Git output is not secret-bearing here).
    public let output: String
}

extension RepositoryHandle {
    /// The environment for one commit invocation. Amend without "reset author" leaves the author to Git
    /// (it keeps the original); the committer is always the profile.
    static func identityEnvironment(_ request: CommitRequest) -> [String: String] {
        var environment = [
            "GIT_COMMITTER_NAME": request.identity.committer.name,
            "GIT_COMMITTER_EMAIL": request.identity.committer.email,
        ]
        if !request.amend || request.resetAuthor {
            environment["GIT_AUTHOR_NAME"] = request.identity.author.name
            environment["GIT_AUTHOR_EMAIL"] = request.identity.author.email
        }
        return environment
    }

    /// `git commit -F -` inside the write gate (P3.10): message on stdin, identity from the snapshot via
    /// environment only (no config is written), hooks run as Git runs them, `--no-verify` only when asked.
    /// Cancellation kills the process group (hooks included).
    public func commit(_ request: CommitRequest) async throws(GitCoreError) -> CommitOutcome {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let result = try await performExclusive(
            request.amend ? "Amend commit" : "Commit", invalidating: Set(InvalidationKind.allCases)
        ) { () throws(GitCoreError) -> (String, String) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            let unmerged = try await engine.run(
                GitCommand(["ls-files", "-u", "-z"], in: topLevel, kind: .read, stdoutLimit: 1024 * 1024))
            guard unmerged.stdout.isEmpty else { throw .refused(summary: "Resolve the conflicts before committing.") }
            if !request.amend {
                // Exit 1 = something staged (works on an unborn branch too: compared with the empty tree).
                let staged = try await engine.run(
                    GitCommand(["diff", "--cached", "--quiet"], in: topLevel, kind: .read, acceptedExitCodes: [0, 1]))
                if staged.exitCode == 0 { throw .refused(summary: "Nothing to commit.") }
            }
            var arguments = ["commit", "-F", "-"]
            if request.amend { arguments.append("--amend") }
            if request.amend && request.resetAuthor { arguments.append("--reset-author") }
            if request.noVerify { arguments.append("--no-verify") }
            var command = GitCommand(
                arguments, in: topLevel, kind: .write, timeout: nil, stdoutLimit: 16 * 1024 * 1024,
                stdin: Array(request.message.utf8))
            command.environment = Self.identityEnvironment(request)
            let output: ProcessOutput
            do throws(GitCoreError) {
                output = try await engine.run(command)
            } catch {
                if case let .processFailed(_, _, detail) = error,
                    detail.contains("nothing to commit") || detail.contains("no changes added to commit")
                {
                    throw .refused(summary: "Nothing to commit.")
                }
                throw Self.mapWriteError(error, gitDirectory: gitDirectory)
            }
            let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
            let text = (output.stdoutText + String(decoding: output.stderr, as: UTF8.self))
            return (head, text)
        }
        return CommitOutcome(revision: repoRevision, commitID: result.0, output: result.1)
    }

    /// The full message of HEAD (amend loads it into the composer).
    public func headMessage() async throws(GitCoreError) -> String {
        let topLevel = try requireWorkingTree()
        _ = topLevel
        return String(
            decoding: try await runRead(["log", "-1", "--format=%B", "--end-of-options", "HEAD"], limit: 1024 * 1024),
            as: UTF8.self
        )
        .trimmingCharacters(in: .newlines)
    }

    /// HEAD's author (amend: offer "Reset author" when it differs from the profile).
    public func headAuthor() async throws(GitCoreError) -> GitIdentity? {
        let output = String(
            decoding: try await runRead(
                ["log", "-1", "--format=%an%x00%ae", "--end-of-options", "HEAD"], limit: 64 * 1024), as: UTF8.self)
        let parts = output.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return GitIdentity(name: String(parts[0]), email: String(parts[1]))
    }

    /// HEAD is already in its upstream (amending rewrites published history).
    public func headIsInUpstream() async throws(GitCoreError) -> Bool {
        let topLevel = try requireWorkingTree()
        do {
            let output = try await gitEngine.run(
                GitCommand(
                    ["merge-base", "--is-ancestor", "HEAD", "@{upstream}"], in: topLevel, kind: .read,
                    acceptedExitCodes: [0, 1, 128]))
            return output.exitCode == 0
        } catch {
            throw RepositoryDiscovery.classify(error, path: topLevel)
        }
    }

    /// `user.email` as the repository's configuration resolves it (for the "repository config says…" note).
    public func configuredEmail() async throws(GitCoreError) -> String? {
        let topLevel = try requireWorkingTree()
        let output = try await gitEngine.run(
            GitCommand(["config", "--get", "user.email"], in: topLevel, kind: .read, acceptedExitCodes: [0, 1]))
        let value = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
