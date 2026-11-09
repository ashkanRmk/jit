import Foundation

/// The §16.4 error taxonomy (design §4.11). `Services` turns each kind into a presentable explanation with
/// recovery actions.
public enum FailureKind: String, Sendable, Hashable, CaseIterable {
    case invalidRepository
    case detachedHead
    case dirtyWorkingTree
    case untrackedWouldBeOverwritten
    case unmergedIndex
    case authenticationFailed
    case expiredToken
    case sshPublicKeyDenied
    case sshHostKeyUnknown
    case sshHostKeyChanged
    case tlsFailure
    case proxyFailure
    case hostNotFound
    case connectionTimedOut
    case connectionRefused
    case remoteRepositoryNotFound
    case pushRejected
    case notFastForward
    case mergeConflicts
    case indexLocked
    case permissionDenied
    case diskFull
    case branchNotFullyMerged
    case branchCheckedOutElsewhere
    case invalidName
    case alreadyExists
    case hookRejected
    case unknown
}

/// A classified Git failure: the kind, a short summary in Jit's words, sanitized technical detail, the
/// paths Git listed (blocked switch, dirty tree) and `remote:` lines (hook rejections).
public struct ClassifiedFailure: Sendable, Equatable {
    public var kind: FailureKind
    public var summary: String
    /// Redacted stderr, last 20 lines.
    public var detail: String
    public var paths: [String]
    public var remoteLines: [String]
    public var exitCode: Int32

    public init(
        kind: FailureKind, summary: String, detail: String = "", paths: [String] = [], remoteLines: [String] = [],
        exitCode: Int32 = 1
    ) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.paths = paths
        self.remoteLines = remoteLines
        self.exitCode = exitCode
    }
}

/// Maps an exit status and C-locale stderr to a `ClassifiedFailure` (design §4.11). Git's messages are
/// stable under `LC_ALL=C`; matching is substring-based and ordered from most to least specific.
public enum GitErrorClassifier {
    public static func classify(exitCode: Int32, stderr: String) -> ClassifiedFailure {
        let text = Redaction.redact(stderr)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let detail = lines.suffix(20).joined(separator: "\n")
        let lower = text.lowercased()
        let remoteLines = lines.filter { $0.hasPrefix("remote:") }.map {
            $0.dropFirst("remote:".count).trimmingCharacters(in: .whitespaces)
        }
        func make(_ kind: FailureKind, _ summary: String, paths: [String] = []) -> ClassifiedFailure {
            ClassifiedFailure(
                kind: kind, summary: summary, detail: detail, paths: paths, remoteLines: remoteLines,
                exitCode: exitCode)
        }

        if lower.contains("index.lock") && lower.contains("file exists") {
            return make(.indexLocked, "Another Git process is using this repository.")
        }
        if lower.contains("remote host identification has changed") {
            return make(.sshHostKeyChanged, "The server's SSH host key has changed.")
        }
        if lower.contains("host key verification failed") || lower.contains("no matching host key")
            || lower.contains("no ecdsa host key is known") || lower.contains("no ed25519 host key is known")
            || lower.contains("no rsa host key is known")
        {
            return make(.sshHostKeyUnknown, "This SSH host isn't trusted on this Mac yet.")
        }
        if lower.contains("permission denied (publickey") || lower.contains("permission denied, please try again") {
            return make(.sshPublicKeyDenied, "The server refused the SSH key.")
        }
        if lower.contains("received http code 407") || lower.contains("failed to connect to proxy")
            || lower.contains("proxy authentication required") || lower.contains("could not resolve proxy")
        {
            return make(.proxyFailure, "The proxy refused or couldn't be reached.")
        }
        if lower.contains("ssl certificate problem") || lower.contains("server certificate verification failed")
            || lower.contains("ssl_connect") || lower.contains("unable to get local issuer certificate")
            || lower.contains("certificate verify failed")
        {
            return make(.tlsFailure, "The server's certificate couldn't be verified.")
        }
        if lower.contains("token") && (lower.contains("expired") || lower.contains("revoked")) {
            return make(.expiredToken, "The access token has expired or was revoked.")
        }
        if lower.contains("authentication failed") || lower.contains("could not read username")
            || lower.contains("could not read password") || lower.contains("terminal prompts disabled")
            || lower.contains("http basic: access denied") || lower.contains("the requested url returned error: 401")
            || lower.contains("the requested url returned error: 403") || lower.contains("invalid username or password")
        {
            return make(.authenticationFailed, "This remote needs credentials.")
        }
        if lower.contains("could not resolve host") || lower.contains("nodename nor servname")
            || lower.contains("name or service not known") || lower.contains("could not resolve hostname")
        {
            return make(.hostNotFound, "The server's name couldn't be resolved.")
        }
        if lower.contains("timed out") || lower.contains("operation timed out") {
            return make(.connectionTimedOut, "The connection to the server timed out.")
        }
        if lower.contains("connection refused") {
            return make(.connectionRefused, "The server refused the connection.")
        }
        if lower.contains("repository not found") || lower.contains("does not appear to be a git repository")
            || (lower.contains("repository '") && lower.contains("' not found"))
            || lower.contains("the requested url returned error: 404")
        {
            return make(.remoteRepositoryNotFound, "The remote repository wasn't found.")
        }
        if lower.contains("no space left on device") {
            return make(.diskFull, "The disk is full.")
        }
        if lower.contains("would be overwritten by") {
            let paths = listedPaths(in: lines)
            if lower.contains("untracked working tree files") {
                return make(
                    .untrackedWouldBeOverwritten, "Untracked files would be overwritten.", paths: paths)
            }
            return make(.dirtyWorkingTree, "Local changes would be overwritten.", paths: paths)
        }
        if lower.contains("please commit your changes or stash them")
            || lower.contains("cannot rebase: you have unstaged changes")
            || lower.contains("your index contains uncommitted changes")
            || lower.contains("cannot pull with rebase: you have unstaged changes")
        {
            return make(.dirtyWorkingTree, "The working tree has uncommitted changes.")
        }
        if lower.contains("you need to resolve your current index first") || lower.contains("unmerged files")
            || lower.contains("you have unmerged paths") || lower.contains("is unmerged")
        {
            return make(.unmergedIndex, "There are unresolved conflicts.")
        }
        if lower.contains("not possible to fast-forward") || lower.contains("not a fast-forward") {
            return make(.notFastForward, "The branches have diverged; a fast-forward isn't possible.")
        }
        if lower.contains("is not fully merged") {
            return make(.branchNotFullyMerged, "The branch has commits that aren't merged.")
        }
        if lower.contains("is already used by worktree") || lower.contains("is already checked out at") {
            return make(.branchCheckedOutElsewhere, "The branch is checked out in another worktree.")
        }
        if lower.contains("is not a valid branch name") || lower.contains("not a valid ref name")
            || lower.contains("invalid reference") || lower.contains("not a valid branch name")
        {
            return make(.invalidName, "That isn't a valid name.")
        }
        if lower.contains("already exists") {
            return make(.alreadyExists, "Something with that name already exists.")
        }
        if lower.contains("hook declined") || lower.contains("pre-receive hook") || lower.contains("protected branch") {
            return make(.hookRejected, "The remote's hook rejected the push.")
        }
        if lower.contains("you are not currently on a branch") || lower.contains("head detached") {
            return make(.detachedHead, "You're not on a branch.")
        }
        if lower.contains("not a git repository") {
            return make(.invalidRepository, "This folder is no longer a Git repository.")
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return make(.permissionDenied, "Permission was denied.")
        }
        if lower.contains("conflict") && lower.contains("merge conflict") {
            return make(.mergeConflicts, "The operation stopped with conflicts.")
        }
        let first = lines.first { !$0.hasPrefix("hint:") && !$0.hasPrefix("remote:") }.map(ChildProcessMath.humanize)
        return make(.unknown, first ?? "Git exited with status \(exitCode).")
    }

    /// Classifies a `processFailed` error; other errors pass through unchanged.
    public static func classify(_ error: GitCoreError) -> GitCoreError {
        guard case let .processFailed(exitCode, _, detail) = error else { return error }
        return .failed(classify(exitCode: exitCode, stderr: detail))
    }

    /// Tab-indented path lines Git prints between "…would be overwritten…:" and "Please …".
    static func listedPaths(in lines: [String]) -> [String] {
        var paths: [String] = []
        var collecting = false
        for line in lines {
            if line.contains("would be overwritten by") {
                collecting = true
                continue
            }
            guard collecting else { continue }
            if line.hasPrefix("\t") || line.hasPrefix("    ") {
                paths.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                collecting = false
            }
        }
        return paths
    }
}

/// Removes credentials from text that may contain URLs, auth headers or token-shaped strings (shared with
/// Phase 5).
public enum Redactor {
    public static func redact(_ text: String) -> String { Redaction.redact(text) }
}
