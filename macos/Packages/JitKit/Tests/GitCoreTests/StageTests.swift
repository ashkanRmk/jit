import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import GitCore

/// File-level stage/unstage and the write gate (P3.1) against real repositories.
@Suite struct StageTests {
    func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        return try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    func committedRepo(_ sandbox: GitSandbox, files: [String: String]) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        return repo
    }

    /// `git ls-files -s -z` as one string: modes, blob ids and stages of every index entry.
    func indexListing(_ repo: TestRepo) async throws -> String {
        try await repo.git("ls-files", "-s")
    }

    func indexEntries(_ repo: TestRepo, excluding excluded: Set<String>) async throws -> [String] {
        try await indexListing(repo).split(separator: "\n").map(String.init).filter { line in
            guard let tab = line.firstIndex(of: "\t") else { return true }
            return !excluded.contains(String(line[line.index(after: tab)...]))
        }
    }

    func entry(_ snapshot: StatusSnapshot, _ path: String) -> Int? {
        (0..<snapshot.entries.count).first { snapshot.entries.path(at: $0) == path }
    }

    func snapshot(_ handle: RepositoryHandle) async throws -> StatusSnapshot {
        _ = try await handle.status()
        return try #require(await handle.lastSnapshot())
    }

    func bytes(_ repo: TestRepo, _ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: repo.path + "/" + path))
    }

    // MARK: Stage

    @Test func stagePathsNewDeletedRenamed() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(
            sandbox,
            files: [
                "a.txt": "a\n", "b.txt": "b\n", "c.txt": String(repeating: "rename me\n", count: 20),
                "untouched.txt": "u\n",
            ])
        try repo.write("a.txt", "a changed\n")
        try FileManager.default.removeItem(atPath: repo.path + "/b.txt")
        try FileManager.default.moveItem(atPath: repo.path + "/c.txt", toPath: repo.path + "/d.txt")
        try repo.write("e.txt", "new\n")
        try repo.write("not staged.txt", "stays untracked\n")
        let handle = try await open(repo)
        let before = try await handle.repoRevision

        let revision = try await handle.stage(["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])

        #expect(revision > before)
        let status = try await snapshot(handle)
        let entries = status.entries
        #expect(try entries.statusCodes(at: #require(entry(status, "a.txt"))) == ("M", "."))
        #expect(try entries.statusCodes(at: #require(entry(status, "b.txt"))) == ("D", "."))
        #expect(try entries.statusCodes(at: #require(entry(status, "e.txt"))) == ("A", "."))
        let renamed = try #require(entry(status, "d.txt"))
        #expect(entries.kind(at: renamed) == .renamedOrCopied)
        #expect(entries.originalPath(at: renamed) == "c.txt")
        #expect(entries.rename(at: renamed)?.kind == .renamed)
        #expect(entries.rename(at: renamed)?.score == 100)
        #expect(try entries.kind(at: #require(entry(status, "not staged.txt"))) == .untracked)
        #expect(entry(status, "untouched.txt") == nil)
        #expect(status.summary.staged == 4)
        #expect(status.summary.unstaged == 0)
    }

    @Test func stageKeepsUnrelatedIndexEntriesAndWorktreeBytes() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n"])
        try repo.write("b.txt", "b staged\n")
        try await repo.git("add", "b.txt")
        try repo.write("b.txt", "b staged\nplus unstaged\n")
        try repo.write("a.txt", "a\r\nCRLF stays\r\n")
        try repo.write("c.txt", "c changed\n")
        let handle = try await open(repo)
        let unrelatedBefore = try await indexEntries(repo, excluding: ["a.txt"])
        let worktreeBefore = try ["a.txt", "b.txt", "c.txt"].map { try bytes(repo, $0) }

        try await handle.stage(["a.txt"])

        #expect(try await indexEntries(repo, excluding: ["a.txt"]) == unrelatedBefore)
        #expect(try ["a.txt", "b.txt", "c.txt"].map { try bytes(repo, $0) } == worktreeBefore)
        let staged = try await repo.git("show", ":a.txt")
        #expect(staged == "a\r\nCRLF stays")  // `git` helper trims the final newline only
    }

    @Test func stageTreatsPathsLiterally() async throws {
        let sandbox = try GitSandbox()
        let names = ["*.txt", "-n.txt", ":(glob)x", "new\nline.txt", "café — résumé.txt", "dir with space/f.txt"]
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n"])
        for name in names { try repo.write(name, "content of \(name)\n") }
        try repo.write("a.txt", "changed\n")
        let handle = try await open(repo)

        try await handle.stage(["*.txt"])
        var status = try await snapshot(handle)
        // A glob would also have matched a.txt; a literal pathspec stages only the file named "*.txt".
        #expect(try status.entries.statusCodes(at: #require(entry(status, "*.txt"))) == ("A", "."))
        #expect(try status.entries.statusCodes(at: #require(entry(status, "a.txt"))) == (".", "M"))

        try await handle.stage(Array(names.dropFirst()))
        status = try await snapshot(handle)
        for name in names {
            let index = try #require(entry(status, name), "missing \(name)")
            #expect(status.entries.statusCodes(at: index) == ("A", "."), "\(name)")
        }
    }

    @Test func stageDirectoryFromUntrackedNormalMode() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n"])
        try repo.write("folder/one.txt", "1\n")
        try repo.write("folder/sub/two.txt", "2\n")
        let handle = try await open(repo)
        let before = try await snapshot(handle)
        // Normal untracked mode reports the directory, not its files.
        #expect(try before.entries.kind(at: #require(entry(before, "folder/"))) == .untracked)

        try await handle.stage(["folder/"])

        let after = try await snapshot(handle)
        #expect(entry(after, "folder/one.txt") != nil)
        #expect(entry(after, "folder/sub/two.txt") != nil)
        #expect(after.summary.staged == 2)
    }

    // MARK: Unstage

    @Test func unstageRestoresHeadVersionAndKeepsWorktree() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "a changed\n")
        try repo.write("new.txt", "new\n")
        try await repo.git("add", "a.txt", "new.txt")
        try await repo.git("rm", "-q", "b.txt")
        let handle = try await open(repo)

        try await handle.unstage(["a.txt", "new.txt", "b.txt"])

        let status = try await snapshot(handle)
        #expect(try status.entries.statusCodes(at: #require(entry(status, "a.txt"))) == (".", "M"))
        #expect(try status.entries.kind(at: #require(entry(status, "new.txt"))) == .untracked)
        // `git rm` deleted the file too, so unstaging leaves an unstaged deletion.
        #expect(try status.entries.statusCodes(at: #require(entry(status, "b.txt"))) == (".", "D"))
        #expect(try String(decoding: bytes(repo, "a.txt"), as: UTF8.self) == "a changed\n")
        #expect(status.summary.staged == 0)
    }

    @Test func unstageStagedRenameNeedsBothPaths() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["old.txt": String(repeating: "line\n", count: 10)])
        try await repo.git("mv", "old.txt", "new.txt")
        let handle = try await open(repo)
        let status = try await snapshot(handle)
        let index = try #require(entry(status, "new.txt"))
        let paths = [status.entries.path(at: index)] + [status.entries.originalPath(at: index)].compactMap { $0 }

        try await handle.unstage(paths)

        let after = try await snapshot(handle)
        #expect(try after.entries.statusCodes(at: #require(entry(after, "old.txt"))) == (".", "D"))
        #expect(try after.entries.kind(at: #require(entry(after, "new.txt"))) == .untracked)
        #expect(after.summary.staged == 0)
    }

    @Test func unstagePathsOnUnbornHead() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("x.txt", "x\n")
        try repo.write("y.txt", "y\n")
        try await repo.git("add", "x.txt", "y.txt")
        try repo.write("x.txt", "x edited after staging\n")  // staged content differs from worktree
        let handle = try await open(repo)

        try await handle.unstage(["x.txt"])

        let status = try await snapshot(handle)
        #expect(status.branch.isUnborn)
        #expect(try status.entries.kind(at: #require(entry(status, "x.txt"))) == .untracked)
        #expect(try status.entries.statusCodes(at: #require(entry(status, "y.txt"))) == ("A", "."))
        #expect(try String(decoding: bytes(repo, "x.txt"), as: UTF8.self) == "x edited after staging\n")
    }

    @Test func stageThenUnstageRestoresIndex() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "a changed\n")
        let handle = try await open(repo)
        let before = try await indexListing(repo)

        try await handle.stage(["a.txt"])
        #expect(try await indexListing(repo) != before)
        try await handle.unstage(["a.txt"])

        #expect(try await indexListing(repo) == before)
    }

    // MARK: Safety

    @Test func indexLockPresentRefused() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n"])
        try repo.write("a.txt", "changed\n")
        let handle = try await open(repo)
        let lock = repo.path + "/.git/index.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        let before = try await indexListing(repo)

        await #expect(throws: GitCoreError.indexLocked(path: lock)) { try await handle.stage(["a.txt"]) }
        await #expect(throws: GitCoreError.indexLocked(path: lock)) { try await handle.unstage(["a.txt"]) }

        try FileManager.default.removeItem(atPath: lock)
        #expect(try await indexListing(repo) == before)
        try await handle.stage(["a.txt"])  // works once the lock is gone
        #expect(try await indexListing(repo) != before)
    }

    @Test func staleReadResultsDiscarded() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n"])
        try repo.write("a.txt", "changed\n")
        let handle = try await open(repo)
        // A status read racing the mutation: whatever it returns, a read after the mutation reflects it.
        let racing = Task { try await handle.status() }
        try await handle.stage(["a.txt"])
        _ = try? await racing.value

        let status = try await handle.status()
        #expect(status.summary?.staged == 1)
        #expect(status.summary?.unstaged == 0)
        #expect(status.revision == (try await handle.lastSnapshot())?.revision)
    }

    // MARK: Write gate

    @Test func writeGateSerializesAcrossAwaits() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n"])
        let handle = try await open(repo)
        let log = Mutex<[String]>([])

        await withTaskGroup(of: Void.self) { group in
            for name in ["one", "two", "three"] {
                group.addTask {
                    _ = try? await handle.performExclusive(name) { () throws(GitCoreError) in
                        log.withLock { $0.append("\(name) start") }
                        // Suspension points inside the critical section: actor reentrancy alone would
                        // let the other mutations interleave here.
                        for _ in 0..<5 { await Task.yield() }
                        try? await Task.sleep(for: .milliseconds(20))
                        log.withLock { $0.append("\(name) end") }
                    }
                }
            }
        }

        let entries = log.withLock { $0 }
        #expect(entries.count == 6)
        for pair in stride(from: 0, to: entries.count, by: 2) {
            let name = entries[pair].replacingOccurrences(of: " start", with: "")
            #expect(entries[pair + 1] == "\(name) end", "interleaved: \(entries)")
        }
        #expect(try await handle.repoRevision == RepoRevision(3))
        #expect(await handle.writeGateState() == WriteGateState())
    }

    @Test func writeGateReportsPendingAndDropsCancelledWaiter() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n"])
        let handle = try await open(repo)
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let ran = Mutex<[String]>([])

        let holder = Task {
            try await handle.performExclusive("holder") { () throws(GitCoreError) in
                ran.withLock { $0.append("holder") }
                for await _ in release { break }
            }
        }
        while await handle.writeGateState().current != "holder" { await Task.yield() }
        let cancelled = Task {
            try await handle.performExclusive("cancelled") { () throws(GitCoreError) in
                ran.withLock { $0.append("cancelled") }
            }
        }
        let queued = Task {
            try await handle.performExclusive("queued") { () throws(GitCoreError) in
                ran.withLock { $0.append("queued") }
            }
        }
        while await handle.writeGateState().pending.count < 2 { await Task.yield() }
        #expect(await handle.writeGateState().isBusy)
        #expect(Set(await handle.writeGateState().pending) == ["cancelled", "queued"])

        cancelled.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await cancelled.value }
        #expect(await handle.writeGateState().pending == ["queued"])

        releaseContinuation.yield()
        try await holder.value
        try await queued.value
        #expect(ran.withLock { $0 } == ["holder", "queued"])
        #expect(await handle.writeGateState() == WriteGateState())
    }

    @Test func stageAndUnstageGoThroughTheGate() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committedRepo(sandbox, files: ["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "a2\n")
        try repo.write("b.txt", "b2\n")
        let handle = try await open(repo)
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await handle.performExclusive("holder") { () throws(GitCoreError) in
                for await _ in release { break }
            }
        }
        while await handle.writeGateState().current != "holder" { await Task.yield() }
        let stage = Task { try await handle.stage(["a.txt", "b.txt"]) }
        while await handle.writeGateState().pending.isEmpty { await Task.yield() }
        #expect(await handle.writeGateState().pending == ["Stage 2 files"])
        // Nothing was staged while the gate was held.
        #expect(try await repo.git("diff", "--cached", "--name-only") == "")

        releaseContinuation.yield()
        try await holder.value
        _ = try await stage.value
        #expect(try await repo.git("diff", "--cached", "--name-only") == "a.txt\nb.txt")
    }
}

/// Typed status views (P3.1) over real Git output.
@Suite struct StatusModelTests {
    func open(_ repo: TestRepo) async throws -> StatusSnapshot {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
        _ = try await handle.status()
        return try #require(await handle.lastSnapshot())
    }

    func index(_ snapshot: StatusSnapshot, _ path: String) throws -> Int {
        try #require((0..<snapshot.entries.count).first { snapshot.entries.path(at: $0) == path })
    }

    @Test func statusRenameStaged() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("old.txt", String(repeating: "same\n", count: 30))
        try await repo.commit("Initial")
        try await repo.git("mv", "old.txt", "new.txt")
        try repo.write("new.txt", String(repeating: "same\n", count: 30) + "edit\n")
        try await repo.git("add", "new.txt")
        try repo.write("new.txt", String(repeating: "same\n", count: 30) + "edit\nmore\n")

        let snapshot = try await open(repo)
        let row = try index(snapshot, "new.txt")
        #expect(snapshot.entries.originalPath(at: row) == "old.txt")
        let rename = try #require(snapshot.entries.rename(at: row))
        #expect(rename.kind == .renamed)
        #expect(rename.score > 50 && rename.score < 100)
        #expect(snapshot.entries.isPartiallyStaged(at: row))
        #expect(snapshot.entries.modes(at: row) == [0o100644, 0o100644, 0o100644])
        #expect(snapshot.summary.partiallyStaged == 1)
        #expect(snapshot.summary.changedFiles == 1)
    }

    @Test func statusConflictEntries() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("both.txt", "base\n")
        try repo.write("deleted.txt", "base\n")
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "other")
        try repo.write("both.txt", "theirs\n")
        try repo.write("deleted.txt", "changed by them\n")
        try repo.write("added.txt", "theirs\n")
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try repo.write("both.txt", "ours\n")
        try FileManager.default.removeItem(atPath: repo.path + "/deleted.txt")
        try repo.write("added.txt", "ours\n")
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "-q", "other")

        let snapshot = try await open(repo)
        #expect(snapshot.summary.conflicted == 3)
        #expect(snapshot.entries.conflict(at: try index(snapshot, "both.txt")) == .bothModified)
        #expect(snapshot.entries.conflict(at: try index(snapshot, "added.txt")) == .bothAdded)
        #expect(snapshot.entries.conflict(at: try index(snapshot, "deleted.txt")) == .deletedByUs)
        #expect(snapshot.entries.modes(at: try index(snapshot, "both.txt")).count == 4)
        #expect(!snapshot.entries.hasStagedChange(at: try index(snapshot, "both.txt")))
    }

    @Test func statusSubmoduleModified() async throws {
        let sandbox = try GitSandbox(extraEnvironment: [
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always",
        ])
        let sub = try await sandbox.makeRepository("sub")
        try sub.write("lib.txt", "lib\n")
        try await sub.commit("Lib")
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        try await repo.git("submodule", "add", "-q", "--", sub.path, "vendor/sub")
        try await repo.commit("Add submodule")
        try repo.write("vendor/sub/lib.txt", "edited inside\n")
        try repo.write("vendor/sub/stray.txt", "untracked inside\n")

        let snapshot = try await open(repo)
        let row = try index(snapshot, "vendor/sub")
        #expect(snapshot.entries.isSubmodule(at: row))
        #expect(
            snapshot.entries.submoduleState(at: row)
                == .init(commitChanged: false, hasTrackedChanges: true, hasUntrackedChanges: true))
        #expect(snapshot.entries.modes(at: row).first == 0o160000)
    }

    @Test func statusTypeChange() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("target.txt", "t\n")
        try repo.write("link", "was a file\n")
        try await repo.commit("Initial")
        try FileManager.default.removeItem(atPath: repo.path + "/link")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "target.txt")

        let snapshot = try await open(repo)
        let row = try index(snapshot, "link")
        #expect(snapshot.entries.isTypeChange(at: row))
        #expect(snapshot.entries.statusCodes(at: row) == (".", "T"))
    }

    @Test func statusUnicodeAndNewlinePathsAndUntrackedNormalMode() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("seed.txt", "s\n")
        try await repo.commit("Initial")
        let names = ["日本語.txt", "tab\there.txt", "new\nline.txt", "\"quoted\".txt"]
        for name in names { try repo.write(name, "x\n") }
        try repo.write("untracked dir/a.txt", "a\n")
        try repo.write("untracked dir/b.txt", "b\n")

        let snapshot = try await open(repo)
        for name in names { #expect(throws: Never.self) { try index(snapshot, name) } }
        // Normal mode: one entry for the whole untracked directory.
        #expect(snapshot.entries.kind(at: try index(snapshot, "untracked dir/")) == .untracked)
        #expect(snapshot.summary.untracked == names.count + 1)
        #expect(snapshot.summary.changedFiles == names.count + 1)
        #expect(snapshot.entries.hasUnstagedChange(at: try index(snapshot, "untracked dir/")))
    }
}
