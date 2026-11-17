import Foundation
import GitCore

/// Read-only benchmark on an explicitly supplied fixture; does not write refs, objects or reflogs.
enum ReflogBench {
    static func run(path: String, iterations: Int = 15, out: String) async throws {
        let engine = GitEngine()
        let git = try await engine.gitInfo()
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: path))
        let page = try await handle.reflogPage()
        print("reflog fixture: \(page.entries.count) entries on first page; \(try await handle.refs().refs.count) refs")
        try await measure("reflog-page", iterations: iterations, git: git, outDirectory: out) {
            _ = try await handle.reflogPage()
        }
    }
}
