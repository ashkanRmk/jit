import Foundation

/// Tracked paths for the command palette's file source (P6.9): `git ls-files -z`, bounded.
public struct TrackedPaths: Sendable {
    public let paths: [String]
    /// More paths exist than `limit`; only the first `limit` (Git's index order) are listed.
    public let isTruncated: Bool
}

extension RepositoryHandle {
    /// At most `limit` tracked paths (index order). Read-only; one Git process; `stdoutLimit` bounds memory.
    public nonisolated func trackedPaths(limit: Int = 100_000) async throws(GitCoreError) -> TrackedPaths {
        guard let topLevel = info.topLevel else { return TrackedPaths(paths: [], isTruncated: false) }
        let output: ProcessOutput
        do {
            output = try await gitEngine.run(
                GitCommand(
                    ["ls-files", "-z", "--cached"], in: topLevel, kind: .read, timeout: .seconds(30),
                    stdoutLimit: 64 * 1024 * 1024))
        } catch {
            throw RepositoryDiscovery.classify(error, path: topLevel)
        }
        var paths: [String] = []
        paths.reserveCapacity(min(limit, 4096))
        var start = 0
        let bytes = output.stdout
        var truncated = false
        for index in bytes.indices where bytes[index] == 0 {
            if paths.count == limit {
                truncated = true
                break
            }
            if index > start { paths.append(String(decoding: bytes[start..<index], as: UTF8.self)) }
            start = index + 1
        }
        return TrackedPaths(paths: paths, isTruncated: truncated)
    }
}
