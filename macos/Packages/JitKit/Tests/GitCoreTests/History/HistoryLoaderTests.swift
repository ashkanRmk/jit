import Darwin
import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Shared helpers for history tests.
enum HistoryFixtures {
    static func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    static func loader(_ repo: TestRepo, _ query: HistoryQuery = HistoryQuery()) async throws -> HistoryLoader {
        let handle = try await open(repo)
        return HistoryLoader(repository: handle, query: query, refs: try await handle.refs())
    }

    static func oids(_ snapshot: HistorySnapshot) -> [String] {
        (0..<snapshot.count).map { snapshot.row($0).oid.hex(snapshot.format) }
    }

    /// A synthetic history built in the sandbox.
    static func synthetic(_ commits: Int, in sandbox: GitSandbox, branches: Int = 50) throws -> TestRepo {
        let path = sandbox.root + "/synthetic-\(commits)"
        try SyntheticHistory(commits: commits, branches: branches).build(at: path, environment: sandbox.environment)
        return TestRepo(sandbox: sandbox, path: path)
    }

    static func sampleRepo() async throws -> (TestRepo, [String: String]) {
        let repo = try await GitSandbox().makeRepository()
        let oids = try await TopologyTests.sample().write(to: repo)
        return (repo, oids)
    }
}

@Suite struct HistoryLoaderTests {
    @Test func historyMatchesGitLogTopoOrder() async throws {
        let (repo, _) = try await HistoryFixtures.sampleRepo()
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        let expected = try await repo.git("rev-list", "--topo-order", "--branches", "--remotes", "--tags", "HEAD")
        #expect(HistoryFixtures.oids(snapshot) == expected.split(separator: "\n").map(String.init))
        #expect(snapshot.complete)
        let first = snapshot.row(0)
        #expect(first.subject == "R1" || first.subject == "Octo")
    }

    @Test func historyMatchesGitLogOnSyntheticHistory() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(3000, in: sandbox)
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        let expected = try await repo.git("rev-list", "--topo-order", "--branches", "--remotes", "--tags", "HEAD")
        #expect(HistoryFixtures.oids(snapshot) == expected.split(separator: "\n").map(String.init))
        #expect(snapshot.count == 3000)
        // Subjects, authors and times round-trip.
        let line = try await repo.git("log", "-1", "--format=%s%x00%aN%x00%at", snapshot.row(1234).oid.hex())
        let fields = line.split(separator: "\0").map(String.init)
        let row = snapshot.row(1234)
        #expect(row.subject == fields[0])
        #expect(snapshot.author(of: row).name == fields[1])
        #expect(String(row.time) == fields[2])
    }

    @Test func historyPaginationEquivalence() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(5000, in: sandbox)
        let whole = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        for page in [1, 7, 300, 2000] {
            let loader = try await HistoryFixtures.loader(repo)
            var snapshot = try await loader.ensureLoaded(page)
            while !snapshot.complete { snapshot = try await loader.ensureLoaded(snapshot.count + page) }
            #expect(snapshot.count == whole.count)
            #expect(LaneDump.rows(snapshot) == LaneDump.rows(whole), "page size \(page)")
        }
    }

    @Test func historyFirstPageIsPartial() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(20_000, in: sandbox)
        let loader = try await HistoryFixtures.loader(repo)
        let first = try await loader.ensureLoaded(300)
        #expect(first.count >= 300)
        #expect(first.count < 20_000)
        #expect(!first.complete)
        #expect(await loader.readerProcess != nil)
        await loader.close()
    }

    @Test func historyCancelKillsProcess() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(20_000, in: sandbox)
        let loader = try await HistoryFixtures.loader(repo)
        _ = try await loader.ensureLoaded(300)
        let pid = try #require(await loader.readerProcess)
        await loader.close()
        #expect(await ProcessGone.wait(pid))
        await #expect(throws: GitCoreError.cancelled) { try await loader.ensureLoaded(.max) }
    }

    @Test func historyTaskCancellationKillsReader() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(20_000, in: sandbox)
        let loader = try await HistoryFixtures.loader(repo)
        _ = try await loader.ensureLoaded(300)
        let pid = try #require(await loader.readerProcess)
        let task = Task { try await loader.ensureLoaded(.max) }
        try await Task.sleep(for: .milliseconds(30))  // let the read start
        task.cancel()
        _ = try? await task.value
        // Either the read was cancelled (reader killed) or it finished first (reader exited): both end it.
        #expect(await ProcessGone.wait(pid))
        // Loading resumes afterwards with a new reader (--skip) and the same rows.
        let resumed = try await loader.ensureLoaded(.max)
        #expect(resumed.count == 20_000)
    }

    @Test func historyReaderExitMapsError() async throws {
        let (repo, _) = try await HistoryFixtures.sampleRepo()
        let loader = try await HistoryFixtures.loader(repo, HistoryQuery(scope: .solo("refs/heads/does-not-exist")))
        await #expect {
            try await loader.ensureLoaded(10)
        } throws: { error in
            guard case .processFailed(_, let summary, _) = error as? GitCoreError else { return false }
            return summary.lowercased().contains("does-not-exist") || summary.lowercased().contains("bad revision")
                || summary.lowercased().contains("ambiguous")
        }
    }

    @Test func historyShallowBoundary() async throws {
        let sandbox = try GitSandbox()
        let source = try await sandbox.makeRepository("source")
        var t = Topology()
        t.linear(10, prefix: "A")
        try await t.write(to: source)
        let clone = sandbox.root + "/shallow"
        try await sandbox.git(["clone", "-q", "--depth", "3", "--", "file://" + source.path, clone], in: sandbox.root)
        let snapshot = try await HistoryFixtures.loader(TestRepo(sandbox: sandbox, path: clone)).ensureLoaded(.max)
        #expect(snapshot.count == 3)
        #expect(snapshot.isShallow)
        #expect(snapshot.row(2).parentCount == 0)
        #expect(snapshot.row(2).flags.contains(.root))
    }

    @Test func historySha256Repo() async throws {
        let sandbox = try GitSandbox()
        let path = try sandbox.makeDirectory("sha256")
        try await sandbox.git(["init", "-q", "--object-format=sha256"], in: path)
        let repo = TestRepo(sandbox: sandbox, path: path)
        try await repo.commit("one")
        try await repo.commit("two")
        let handle = try await HistoryFixtures.open(repo)
        let refs = try await handle.refs()
        #expect(refs.format == .sha256)
        let snapshot = try await HistoryLoader(repository: handle, query: HistoryQuery(), refs: refs).ensureLoaded(.max)
        let expected = try await repo.git("rev-list", "HEAD").split(separator: "\n").map(String.init)
        #expect(HistoryFixtures.oids(snapshot) == expected)
        #expect(expected.first?.count == 64)
        #expect(snapshot.row(for: snapshot.row(1).oid) == 1)
    }

    @Test func historyEmptyRepository() async throws {
        let repo = try await GitSandbox().makeRepository()
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(300)
        #expect(snapshot.count == 0)
        #expect(snapshot.complete)
    }

    @Test func historyFileHistoryFollowsRename() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("old.txt", "line 1\nline 2\nline 3\nline 4\n")
        try await repo.commit("create")
        try repo.write("other.txt", "x")
        try await repo.commit("unrelated")
        try await repo.git("mv", "old.txt", "new.txt")
        try await repo.commit("rename")
        try repo.write("new.txt", "line 1\nline 2\nline 3\nline 4\nline 5\n")
        try await repo.commit("edit")
        let followed = try await HistoryFixtures.loader(
            repo, HistoryQuery(scope: .current, path: "new.txt", follow: true)
        )
        .ensureLoaded(.max)
        #expect((0..<followed.count).map { followed.row($0).subject } == ["edit", "rename", "create"])
        let unfollowed = try await HistoryFixtures.loader(repo, HistoryQuery(scope: .current, path: "new.txt"))
            .ensureLoaded(.max)
        #expect((0..<unfollowed.count).map { unfollowed.row($0).subject } == ["edit", "rename"])
    }

    @Test func historyRowLookupAcrossChunks() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(10_000, in: sandbox)
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        #expect(snapshot.chunks.count == 3)
        for index in [0, 4095, 4096, 9999] {
            #expect(snapshot.row(for: snapshot.row(index).oid) == index)
        }
        #expect(snapshot.row(for: ObjectID(hex: String(repeating: "0", count: 40))!) == nil)
    }
}

enum ProcessGone {
    static func wait(_ pid: pid_t) async -> Bool {
        for _ in 0..<150 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// Text form of lane rows for golden files and equality checks.
enum LaneDump {
    static func rows(_ snapshot: HistorySnapshot) -> [String] {
        (0..<snapshot.count).map { line(snapshot.row($0)) }
    }

    static func line(_ row: CommitRow) -> String {
        let width = Int(row.width)
        var cells = [Character](repeating: " ", count: width)
        for segment in row.segments where segment.half == .full { cells[Int(segment.fromLane)] = "|" }
        for segment in row.segments where segment.half == .top && segment.fromLane != segment.toLane {
            cells[Int(segment.fromLane)] = segment.fromLane > segment.toLane ? "/" : "\\"
        }
        let flags = row.flags
        cells[Int(row.nodeLane)] = flags.contains(.merge) ? "M" : flags.contains(.root) ? "o" : "*"
        let segments = row.segments.map { s -> String in
            let half = s.half == .top ? "T" : s.half == .bottom ? "B" : "F"
            return "\(half)\(s.fromLane)>\(s.toLane):\(s.color)"
        }.joined(separator: " ")
        var flagText = ""
        if flags.contains(.tip) { flagText += "t" }
        if flags.contains(.head) { flagText += "h" }
        return "\(String(cells)) | n\(row.nodeLane):\(row.nodeColor) \(flagText) | \(segments)"
    }
}

@Suite struct HistoryReaderSuspensionTests {
    @Test func suspendedReaderResumesWithSkip() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(8000, in: sandbox)
        let whole = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        let loader = try await HistoryFixtures.loader(repo)
        _ = try await loader.ensureLoaded(300)
        let pid = try #require(await loader.readerProcess)
        await loader.suspendReader()
        #expect(await ProcessGone.wait(pid))
        #expect(await loader.readerProcess == nil)
        let resumed = try await loader.ensureLoaded(.max)
        #expect(await loader.readerStarts == 2)
        #expect(LaneDump.rows(resumed) == LaneDump.rows(whole))
    }

    @Test func driftAfterSuspendIsReported() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(20_000, in: sandbox)
        let loader = try await HistoryFixtures.loader(repo, HistoryQuery(scope: .current))
        let first = try await loader.ensureLoaded(1)
        #expect(!first.complete)
        await loader.suspendReader()
        // History rewritten underneath: rows shift, so the resume point is no longer the same commit.
        try await repo.git("update-ref", "refs/heads/main", "main~40")
        await #expect(throws: GitCoreError.self) { try await loader.ensureLoaded(.max) }
    }
}

@Suite struct HistoryPathspecTests {
    @Test func fileHistoryPathIsLiteral() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("a[1].txt", "x\n")
        try repo.write("a1.txt", "y\n")
        try await repo.commit("both")
        try repo.write("a1.txt", "changed\n")
        try await repo.commit("only a1")
        let snapshot = try await HistoryFixtures.loader(repo, HistoryQuery(scope: .current, path: "a[1].txt"))
            .ensureLoaded(.max)
        #expect((0..<snapshot.count).map { snapshot.row($0).subject } == ["both"])
    }
}
