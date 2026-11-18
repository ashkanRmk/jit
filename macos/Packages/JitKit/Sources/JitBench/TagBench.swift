import Foundation
import GitCore

enum TagBench {
    /// Exact-object details only; does not create, push or delete tags in the supplied fixture.
    static func run(path: String, iterations: Int = 15, out: String) async throws {
        let engine = GitEngine()
        let git = try await engine.gitInfo()
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: path))
        let refs = try await handle.refs()
        guard let tag = refs.tags.first else { throw GitCoreError.refused(summary: "This fixture has no tags.") }
        print("tag fixture: \(refs.tags.count) tags; reading \(tag.shortName)")
        try await measure("tag-details", iterations: iterations, git: git, outDirectory: out) {
            _ = try await handle.tagDetails(named: tag.shortName, object: tag.object.hex(refs.format))
        }
    }
}
