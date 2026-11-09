import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import GitCore

/// File-level discard (P3.2, ADR-0025) against real repositories.
@Suite struct DiscardTests {
    func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        return try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    func committed(_ sandbox: GitSandbox, _ files: [String: String]) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        return repo
    }

    func read(_ repo: TestRepo, _ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: repo.path + "/" + path))
    }

    /// Hooks that copy into `<sandbox>/recovery` and "trash" into `<sandbox>/trash`, recording the order.
    final class Recorder: Sendable {
        let events = Locked<[String]>([])
        let root: String
        init(_ root: String) throws {
            self.root = root
            try FileManager.default.createDirectory(atPath: root + "/recovery", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root + "/trash", withIntermediateDirectories: true)
        }
        var hooks: DiscardHooks {
            DiscardHooks(
                preserve: { path, url in
                    let id = path.replacingOccurrences(of: "/", with: "_")
                    try FileManager.default.copyItem(atPath: url.path, toPath: self.root + "/recovery/" + id)
                    self.events.withLock { $0.append("preserve \(path)") }
                    return id
                },
                trash: { url in
                    try FileManager.default.moveItem(
                        atPath: url.path, toPath: self.root + "/trash/" + url.lastPathComponent)
                    self.events.withLock { $0.append("trash \(url.lastPathComponent)") }
                })
        }
    }

    func items(_ handle: RepositoryHandle, _ paths: [String]) async throws -> [DiscardItem] {
        var result: [DiscardItem] = []
        for path in paths { result.append(DiscardItem(token: try await handle.discardToken(for: path))) }
        return result
    }

    @Test func discardTrackedKeepsStagedChanges() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "one\n"])
        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "staged\nand unstaged\n")
        let indexBefore = try await repo.git("ls-files", "-s")
        let handle = try await open(repo)
        let recorder = try Recorder(sandbox.root + "/hooks")

        let outcome = try await handle.discard(try await items(handle, ["a.txt"]), hooks: recorder.hooks)
        #expect(String(decoding: try read(repo, "a.txt"), as: UTF8.self) == "staged\n")  // index version
        #expect(try await repo.git("ls-files", "-s") == indexBefore)  // staged change kept
        #expect(outcome.recovered == ["a.txt": "a.txt"])
        #expect(
            String(
                decoding: try Data(contentsOf: URL(fileURLWithPath: recorder.root + "/recovery/a.txt")), as: UTF8.self)
                == "staged\nand unstaged\n")
    }

    @Test func discardWritesRecoveryCopyFirst() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "one\n"])
        try repo.write("a.txt", "precious edit\n")
        let handle = try await open(repo)
        let seen = Locked<String?>(nil)
        let hooks = DiscardHooks(
            preserve: { _, url in
                // At preserve time the working tree must still hold the user's bytes.
                seen.withLock { $0 = try? String(contentsOf: url, encoding: .utf8) }
                return "id"
            }, trash: { _ in })
        _ = try await handle.discard(try await items(handle, ["a.txt"]), hooks: hooks)
        #expect(seen.withLock { $0 } == "precious edit\n")
        #expect(String(decoding: try read(repo, "a.txt"), as: UTF8.self) == "one\n")

        // A failing recovery copy stops the discard: the edit survives.
        try repo.write("a.txt", "second edit\n")
        let failing = DiscardHooks(preserve: { _, _ in throw CocoaError(.fileWriteNoPermission) }, trash: { _ in })
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.discard(try await items(handle, ["a.txt"]), hooks: failing)
        }
        #expect(String(decoding: try read(repo, "a.txt"), as: UTF8.self) == "second edit\n")
    }

    @Test func discardUntrackedMovesToTrash() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n"])
        try repo.write("new.txt", "new\n")
        try repo.write("scratch/x.txt", "x\n")
        let handle = try await open(repo)
        let recorder = try Recorder(sandbox.root + "/hooks")
        let token = try await handle.discardToken(for: "new.txt")
        #expect(token.isUntracked)

        let outcome = try await handle.discard(try await items(handle, ["new.txt", "scratch/"]), hooks: recorder.hooks)
        #expect(outcome.trashed == ["new.txt", "scratch/"] && outcome.recovered.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/new.txt"))
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/scratch"))
        #expect(FileManager.default.fileExists(atPath: recorder.root + "/trash/new.txt"))
        #expect(FileManager.default.fileExists(atPath: recorder.root + "/trash/scratch/x.txt"))
    }

    @Test func discardStaleTokenRefused() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "a edit\n")
        try repo.write("b.txt", "b edit\n")
        try repo.write("new.txt", "n\n")
        let handle = try await open(repo)
        let recorder = try Recorder(sandbox.root + "/hooks")
        let chosen = try await items(handle, ["a.txt", "b.txt", "new.txt"])

        // b.txt is edited again (same size: content hash catches it) after the user confirmed.
        try repo.write("b.txt", "B edit\n")
        do {
            _ = try await handle.discard(chosen, hooks: recorder.hooks)
            Issue.record("expected staleSnapshot")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3 SILGen crashes on non-exhaustive typed catches (CI, Xcode 26).
            guard case .staleSnapshot(let summary) = error else { throw error }
            #expect(summary.contains("b.txt"))
        }
        // Nothing changed, including the items listed before the stale one.
        #expect(String(decoding: try read(repo, "a.txt"), as: UTF8.self) == "a edit\n")
        #expect(String(decoding: try read(repo, "b.txt"), as: UTF8.self) == "B edit\n")
        #expect(FileManager.default.fileExists(atPath: repo.path + "/new.txt"))
        #expect(recorder.events.withLock { $0 }.isEmpty)

        // Staging after the token was taken also makes it stale.
        let token = try await items(handle, ["a.txt"])
        try await repo.git("add", "a.txt")
        await #expect(throws: GitCoreError.self) { _ = try await handle.discard(token, hooks: recorder.hooks) }
    }

    @Test func discardUnrelatedFilesByteIdentical() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n", "keep.txt": "k\n", "gone.txt": "g\n"])
        try repo.write("a.txt", "a edit\n")
        try repo.write("keep.txt", "keep edit\r\nno newline at end")
        try FileManager.default.removeItem(atPath: repo.path + "/gone.txt")
        try repo.write("other-new.txt", "stay\n")
        try repo.write("staged.txt", "s\n")
        try await repo.git("add", "staged.txt")
        let keepBefore = try read(repo, "keep.txt")
        let indexBefore = try await repo.git("ls-files", "-s")
        let handle = try await open(repo)
        let recorder = try Recorder(sandbox.root + "/hooks")

        let outcome = try await handle.discard(try await items(handle, ["a.txt", "gone.txt"]), hooks: recorder.hooks)
        #expect(String(decoding: try read(repo, "a.txt"), as: UTF8.self) == "a\n")
        #expect(String(decoding: try read(repo, "gone.txt"), as: UTF8.self) == "g\n")  // deletion undone
        #expect(outcome.recovered == ["a.txt": "a.txt"])  // a deleted file has nothing to copy
        #expect(try read(repo, "keep.txt") == keepBefore)
        #expect(String(decoding: try read(repo, "other-new.txt"), as: UTF8.self) == "stay\n")
        #expect(try await repo.git("ls-files", "-s") == indexBefore)
    }

    @Test func discardTreatsPathsLiterally() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["*.txt": "star\n", "b.txt": "b\n"])
        try repo.write("*.txt", "star edit\n")
        try repo.write("b.txt", "b edit\n")
        let handle = try await open(repo)
        _ = try await handle.discard(try await items(handle, ["*.txt"]), hooks: try Recorder(sandbox.root + "/h").hooks)
        #expect(String(decoding: try read(repo, "*.txt"), as: UTF8.self) == "star\n")
        #expect(String(decoding: try read(repo, "b.txt"), as: UTF8.self) == "b edit\n")
    }

    @Test func previewShowsRemovedAndRestoredLines() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "keep\nold\n"])
        try repo.write("a.txt", "keep\nnew 1\nnew 2\n")
        try repo.write("u.txt", (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let handle = try await open(repo)
        let tracked = try await handle.discardPreview(for: try await handle.discardToken(for: "a.txt"))
        #expect(tracked.removedCount == 2 && tracked.restoredCount == 1 && !tracked.isTruncated)
        #expect(tracked.lines.map(\.text) == ["old", "new 1", "new 2"])
        #expect(tracked.lines.map(\.kind) == [.restored, .removed, .removed])

        let untracked = try await handle.discardPreview(for: try await handle.discardToken(for: "u.txt"))
        #expect(untracked.removedCount == 30 && untracked.lines.count == 20 && untracked.isTruncated)
    }
}
