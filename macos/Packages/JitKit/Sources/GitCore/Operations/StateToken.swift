import Foundation

/// What the repository looked like when the user prepared an action (design §4.2): HEAD, the branch it
/// names, a digest of every ref and the operation state. A mutation validates it inside the write gate and
/// throws `.staleSnapshot` when anything moved (e.g. a commit in Terminal while a sheet was open).
public struct RepoStateToken: Sendable, Hashable {
    /// HEAD's commit; `nil` on an unborn branch.
    public let head: String?
    /// `refs/heads/<name>`; `nil` when detached.
    public let headRef: String?
    public let refsDigest: UInt64
    public let operation: OperationState

    public init(head: String?, headRef: String?, refsDigest: UInt64, operation: OperationState) {
        self.head = head
        self.headRef = headRef
        self.refsDigest = refsDigest
        self.operation = operation
    }

    /// Short branch name, if on a branch.
    public var branch: String? { headRef.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } }
}

extension RepositoryHandle {
    /// Reads the current `RepoStateToken` (read-only; never takes the write gate).
    public nonisolated func captureState() async throws(GitCoreError) -> RepoStateToken {
        try await Self.readState(engine: gitEngine, in: workingDirectory, gitDirectory: info.gitDirectory)
    }

    static func readState(engine: GitEngine, in directory: String, gitDirectory: String) async throws(GitCoreError)
        -> RepoStateToken
    {
        async let refs = engine.run(
            GitCommand(
                ["for-each-ref", "--format=%(refname)%00%(objectname)"], in: directory, kind: .read,
                stdoutLimit: 256 * 1024 * 1024))
        async let symbolic = engine.run(
            GitCommand(["symbolic-ref", "-q", "HEAD"], in: directory, kind: .read, acceptedExitCodes: [0, 1]))
        async let head = engine.run(
            GitCommand(
                ["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: directory, kind: .read,
                acceptedExitCodes: [0, 1]))
        let refsOutput: ProcessOutput
        let symbolicOutput: ProcessOutput
        let headOutput: ProcessOutput
        do {
            refsOutput = try await refs
            symbolicOutput = try await symbolic
            headOutput = try await head
        } catch let error as GitCoreError {
            throw error
        } catch {
            throw .internalError(summary: "Couldn't read the repository state.")
        }
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in refsOutput.stdout {
            digest ^= UInt64(byte)
            digest = digest &* 0x100_0000_01b3
        }
        let headRef = symbolicOutput.exitCode == 0 ? symbolicOutput.stdoutText.trimmingCharacters(in: .newlines) : nil
        let commit = headOutput.exitCode == 0 ? headOutput.stdoutText.trimmingCharacters(in: .newlines) : nil
        return RepoStateToken(
            head: commit, headRef: headRef, refsDigest: digest,
            operation: OperationStateDetector.detect(gitDirectory: gitDirectory))
    }

    /// Throws `.staleSnapshot` unless the repository still matches `expected`. Call inside the write gate.
    static func ensureCurrent(
        _ expected: RepoStateToken?, engine: GitEngine, in directory: String, gitDirectory: String
    ) async throws(GitCoreError) {
        guard let expected else { return }
        let current = try await readState(engine: engine, in: directory, gitDirectory: gitDirectory)
        guard current == expected else {
            throw .staleSnapshot(
                summary:
                    "The repository changed since you prepared this action. Nothing was changed — review and try again."
            )
        }
    }
}
