import Darwin
import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Memory budget of the commit store (ADR-0022, implementation.md P2.4).
@Suite(.serialized) struct CommitStoreMemoryTests {
    /// The cached benchmark fixture if present (`make-history-fixture.sh --standard`), else built here.
    static func fixture100k(_ sandbox: GitSandbox) throws -> TestRepo {
        let cached =
            (ProcessInfo.processInfo.environment["JIT_FIXTURES"] ?? NSHomeDirectory() + "/Library/Caches/jit-bench")
            + "/history-100000"
        if FileManager.default.fileExists(atPath: cached + "/.git") { return TestRepo(sandbox: sandbox, path: cached) }
        return try HistoryFixtures.synthetic(100_000, in: sandbox)
    }

    static func liveBlocks() -> (blocks: Int, bytes: Int) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Int(stats.blocks_in_use), Int(stats.size_in_use))
    }

    @Test func storeMemory100kUnder25MB() async throws {
        let sandbox = try GitSandbox()
        let repo = try Self.fixture100k(sandbox)
        let loader = try await HistoryFixtures.loader(repo)
        let snapshot = try await loader.ensureLoaded(.max)
        await loader.close()
        #expect(snapshot.count == 100_000)
        let columns = snapshot.storageBytes
        let subjectBytes = snapshot.chunks.reduce(0) { $0 + $1.subjects.count }
        let segments = snapshot.chunks.reduce(0) { $0 + $1.segments.count }
        let authors = snapshot.authors.reduce(0) { $0 + $1.name.utf8.count + $1.email.utf8.count + 32 }
        let total = columns + authors
        print(
            "commit store: \(total) bytes for \(snapshot.count) commits = \(total / snapshot.count) B/commit; "
                + "excluding subjects \((total - subjectBytes) / snapshot.count) B/commit; "
                + "subjects \(subjectBytes / snapshot.count) B/commit; segments \(Double(segments) / Double(snapshot.count))/row; "
                + "authors \(snapshot.authors.count)")
        var perColumn: [String: Int] = [:]
        for chunk in snapshot.chunks { for (name, bytes) in chunk.columnBytes { perColumn[name, default: 0] += bytes } }
        print(
            perColumn.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value / snapshot.count)" }.joined(
                separator: ", "))
        #expect(total < 25 * 1024 * 1024)
    }

    /// Live heap blocks retained by a loaded 100k history stay O(chunks + authors), not O(commits).
    @Test func noPerCommitHeapObjects() async throws {
        let sandbox = try GitSandbox()
        let repo = try Self.fixture100k(sandbox)
        let handle = try await HistoryFixtures.open(repo)
        let refs = try await handle.refs()
        let before = Self.liveBlocks()
        var loader: HistoryLoader? = HistoryLoader(repository: handle, query: HistoryQuery(), refs: refs)
        let snapshot = try await loader!.ensureLoaded(.max)
        await loader!.close()
        loader = nil
        let after = Self.liveBlocks()
        let retained = after.blocks - before.blocks
        print("live blocks retained by a 100k-commit snapshot: \(retained) (\(snapshot.chunks.count) chunks)")
        // ~15 column buffers per chunk + 2 strings per author + small fixed overhead.
        #expect(retained < snapshot.chunks.count * 20 + snapshot.authors.count * 4 + 500)
        withExtendedLifetime(snapshot) {}
    }
}
