import Foundation

/// What `GitCore` learned about a repository.
public struct RepositoryInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case regular
        case bare
        case linkedWorktree
    }

    public enum Head: Sendable, Equatable {
        case branch(name: String, commit: String)
        case detached(commit: String)
        /// A branch with no commits yet (fresh `git init`, orphan branch).
        case unborn(branch: String)
    }

    public let kind: Kind
    /// Root of the working tree; `nil` for bare repositories.
    public let topLevel: String?
    public let gitDirectory: String
    public let commonDirectory: String
    public let head: Head

    /// Folder name shown to the user.
    public var displayName: String {
        if let topLevel { return (topLevel as NSString).lastPathComponent }
        let name = (gitDirectory as NSString).lastPathComponent
        return name.hasSuffix(".git") && name != ".git" ? String(name.dropLast(4)) : name
    }
}

/// Discovery = two `rev-parse` calls (the second only inside a work tree, because `--show-toplevel`
/// fails in bare repositories and inside `.git`), then HEAD resolution.
struct RepositoryDiscovery {
    let engine: GitEngine
    let timeout: Duration

    func discover(at path: String) async throws(GitCoreError) -> RepositoryInfo {
        let layout = try await lines(
            [
                "rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir",
                "--is-bare-repository", "--is-inside-work-tree",
            ],
            in: path
        )
        guard layout.count == 4 else {
            throw .internalError(summary: "Git returned an unexpected repository layout.")
        }
        let gitDirectory = layout[0]
        let commonDirectory = layout[1]
        let isBare = layout[2] == "true"
        let insideWorkTree = layout[3] == "true"

        var topLevel: String?
        if insideWorkTree {
            topLevel = try await lines(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: path).first
        } else if !isBare, (gitDirectory as NSString).lastPathComponent == ".git" {
            // The user picked the `.git` folder itself; report its working tree.
            topLevel = (gitDirectory as NSString).deletingLastPathComponent
        }

        let kind: RepositoryInfo.Kind =
            isBare ? .bare : (gitDirectory == commonDirectory ? .regular : .linkedWorktree)
        let head = try await resolveHead(in: path)
        return RepositoryInfo(
            kind: kind,
            topLevel: topLevel,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            head: head
        )
    }

    func resolveHead(in path: String) async throws(GitCoreError) -> RepositoryInfo.Head {
        let symbolic = try await run(["symbolic-ref", "-q", "HEAD"], in: path, accepted: [0, 1])
        let commit = try await run(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: path, accepted: [0, 1])
        let sha = commit.exitCode == 0 ? Self.splitLines(commit.stdout).first : nil
        if symbolic.exitCode == 0, let ref = Self.splitLines(symbolic.stdout).first {
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            if let sha { return .branch(name: name, commit: sha) }
            return .unborn(branch: name)
        }
        guard let sha else { throw .internalError(summary: "Git couldn't resolve HEAD in this repository.") }
        return .detached(commit: sha)
    }

    private func lines(_ arguments: [String], in path: String) async throws(GitCoreError) -> [String] {
        Self.splitLines(try await run(arguments, in: path, accepted: [0]).stdout)
    }

    private func run(
        _ arguments: [String], in path: String, accepted: Set<Int32>
    ) async throws(GitCoreError) -> ProcessOutput {
        let command = GitCommand(
            arguments, in: path, kind: .read, timeout: timeout, stdoutLimit: 64 * 1024,
            acceptedExitCodes: accepted)
        do {
            return try await engine.run(command)
        } catch {
            throw Self.classify(error, path: path)
        }
    }

    /// Maps Git's (C-locale) stderr to typed errors.
    static func classify(_ error: GitCoreError, path: String) -> GitCoreError {
        guard case let .processFailed(_, _, detail) = error else { return error }
        if detail.contains("detected dubious ownership") { return .unsafeRepository(path: path) }
        if detail.contains("not a git repository") { return .notARepository(path: path) }
        if detail.contains("Permission denied") { return .permissionDenied(path: path) }
        return error
    }

    /// Splits newline-terminated output into lines without materializing the whole buffer as one
    /// `String` first.
    static func splitLines(_ bytes: [UInt8]) -> [String] {
        bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
