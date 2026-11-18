import Foundation
import GitCore

/// Only prepares a preview; never executes reset or stash on the supplied repository.
enum ResetBench {
    static func run(path: String, iterations: Int = 15, out: String) async throws {
        let engine = GitEngine()
        let git = try await engine.gitInfo()
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: path))
        let target = try await engine.run(GitCommand(["rev-parse", "HEAD~5"], in: path)).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = try await handle.resetPreview(to: target, mode: .hard)
        print("reset fixture: \(preview.removedCount) removed commits, \(preview.localChanges.count) local changes")
        try await measure("reset-preview", iterations: iterations, git: git, outDirectory: out) {
            _ = try await handle.resetPreview(to: target, mode: .hard)
        }
    }
}
