import Foundation
import GitCore
import Testing

@testable import Services

/// Discard recovery store (P3.2, ADR-0025).
@Suite struct RecoveryStoreTests {
    func temporaryStore() throws -> (RecoveryStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jit-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (RecoveryStore(location: StoreLocation(directory: base.appendingPathComponent("Jit"))), base)
    }

    func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func preserveWritesPrivateCopyAndMetadata() throws {
        let (store, base) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("app.swift")
        try Data("edit\n".utf8).write(to: source)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let id = try store.preserve(source, path: "src/app.swift", repository: "/r/demo", branch: "main", now: now)
        let second = try store.preserve(source, path: "src/app.swift", repository: "/r/demo", branch: "main", now: now)
        #expect(id != second && id.hasSuffix("-1") && second.hasSuffix("-2"))  // same second: numbered

        let entry = try #require(store.entries(repository: "/r/demo").first { $0.directory.path == id })
        #expect(entry.meta.path == "src/app.swift" && entry.meta.branch == "main" && entry.meta.bytes == 5)
        #expect(try Data(contentsOf: entry.file) == Data("edit\n".utf8))
        #expect(try permissions(entry.directory) == 0o700)
        #expect(try permissions(entry.file) == 0o600)
        #expect(try permissions(entry.directory.appendingPathComponent("meta.json")) == 0o600)
        #expect(try permissions(store.root) == 0o700)
        // The folder name does not reveal the repository path.
        #expect(!id.contains("demo"))
        #expect(store.entries(repository: "/r/other").isEmpty)
    }

    @Test func preserveKeepsSymlinkAsLink() throws {
        let (store, base) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
        let id = try store.preserve(link, path: "link", repository: "/r", branch: nil)
        let copy = URL(fileURLWithPath: id).appendingPathComponent("link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.path) == "target.txt")
    }

    @Test func pruneByAgeThenSize() throws {
        let (store, base) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("f")
        try Data(repeating: 1, count: 100).write(to: source)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try store.preserve(source, path: "old", repository: "/a", branch: nil, now: now - 8 * 86_400)
        let older = try store.preserve(source, path: "mid", repository: "/b", branch: nil, now: now - 2 * 86_400)
        let newest = try store.preserve(source, path: "new", repository: "/b", branch: nil, now: now - 60)

        #expect(store.prune(now: now, maxBytes: 150) == 2)  // 8 days old, then the oldest over 150 bytes
        let remaining = store.entries().map(\.directory.path)
        #expect(remaining == [newest])
        #expect(!FileManager.default.fileExists(atPath: old) && !FileManager.default.fileExists(atPath: older))
        // The emptied repository folder is gone too.
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: old).deletingLastPathComponent().path))
        #expect(store.prune(now: now) == 0)
    }
}
