import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct CommitDetailsTests {
    @Test func detailsRootCommit() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("dir/b.txt", "b\n")
        let sha = try await repo.commit("Initial import\n\nLonger body\n\nwith paragraphs")
        let details = try await HistoryFixtures.open(repo).commitDetails(ObjectID(hex: sha)!)
        #expect(details.parents.isEmpty)
        #expect(details.subject == "Initial import")
        #expect(details.body == "Longer body\n\nwith paragraphs")
        #expect(details.files.map(\.path) == ["a.txt", "dir/b.txt"])
        #expect(details.files.allSatisfy { $0.status == .added })
        #expect(details.files.first?.additions == 2)
        #expect(details.authorName == "Jit Tests")
        #expect(details.authorTimeZone == "+0000")
    }

    @Test func detailsMergeFirstParent() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("base.txt", "base\n")
        try await repo.commit("base")
        try await repo.git("checkout", "-q", "-b", "feature")
        try repo.write("feature.txt", "f\n")
        try await repo.commit("feature")
        try await repo.git("checkout", "-q", "main")
        try repo.write("main.txt", "m\n")
        try await repo.commit("main work")
        try await repo.git("merge", "-q", "--no-edit", "feature")
        let head = try await repo.git("rev-parse", "HEAD")
        let details = try await HistoryFixtures.open(repo).commitDetails(ObjectID(hex: head)!)
        #expect(details.parents.count == 2)
        // Against the first parent: only what the merge brought in.
        #expect(details.files.map(\.path) == ["feature.txt"])
    }

    @Test func detailsRenameDetected() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("old name.txt", (1...20).map { "line \($0)" }.joined(separator: "\n"))
        try await repo.commit("create")
        try await repo.git("mv", "old name.txt", "new name.txt")
        let sha = try await repo.commit("rename")
        let file = try #require(try await HistoryFixtures.open(repo).commitDetails(ObjectID(hex: sha)!).files.first)
        #expect(file.status == .renamed)
        #expect(file.oldPath == "old name.txt")
        #expect(file.path == "new name.txt")
        #expect(file.additions == 0)
    }

    @Test func detailsBinaryNumstatDash() async throws {
        let repo = try await GitSandbox().makeRepository()
        try Data([0, 1, 2, 0, 255, 0]).write(to: URL(fileURLWithPath: repo.path + "/blob.bin"))
        let sha = try await repo.commit("binary")
        let file = try #require(try await HistoryFixtures.open(repo).commitDetails(ObjectID(hex: sha)!).files.first)
        #expect(file.isBinary)
        #expect(file.deletions == nil)
    }

    @Test func detailsUnicodePaths() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("résumé/naïve 文件.txt", "x\n")
        try repo.write("tab\there.txt", "y\n")
        let sha = try await repo.commit("unicode")
        let paths = try await HistoryFixtures.open(repo).commitDetails(ObjectID(hex: sha)!).files.map(\.path)
        #expect(Set(paths) == ["résumé/naïve 文件.txt", "tab\there.txt"])
    }

    @Test func detailsCachedAndCancelledOnReselect() async throws {
        let repo = try await GitSandbox().makeRepository()
        let first = try await repo.commit("one")
        let handle = try await HistoryFixtures.open(repo)
        let task = Task { try await handle.commitDetails(ObjectID(hex: first)!) }
        task.cancel()
        _ = try? await task.value  // cancelled before or during Git: no result, no crash
        let details = try await handle.commitDetails(ObjectID(hex: first)!)
        #expect(details.subject == "one")
        #expect(handle.detailsCache.count == 1)
    }
}

@Suite struct CompareTests {
    func repoWithDivergence() async throws -> (TestRepo, base: String, main: String, feature: String) {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("shared.txt", "1\n")
        let base = try await repo.commit("base")
        try await repo.git("checkout", "-q", "-b", "feature")
        try repo.write("feature.txt", "f\n")
        let feature = try await repo.commit("feature")
        try await repo.git("checkout", "-q", "main")
        try repo.write("main.txt", "m\n")
        let main = try await repo.commit("main")
        return (repo, base, main, feature)
    }

    @Test func compareTwoDotVsThreeDot() async throws {
        let (repo, _, main, feature) = try await repoWithDivergence()
        let handle = try await HistoryFixtures.open(repo)
        let direct = try await handle.compare(ObjectID(hex: main)!, ObjectID(hex: feature)!, mode: .direct)
        #expect(Set(direct.map(\.path)) == ["feature.txt", "main.txt"])
        let sinceBase = try await handle.compare(ObjectID(hex: main)!, ObjectID(hex: feature)!, mode: .sinceMergeBase)
        #expect(sinceBase.map(\.path) == ["feature.txt"])
        let expected = try await repo.git("diff", "--name-status", main, feature)
        #expect(expected.split(separator: "\n").count == direct.count)
    }

    @Test func compareWithWorktreeExcludesUntracked() async throws {
        let (repo, base, _, _) = try await repoWithDivergence()
        try repo.write("shared.txt", "changed\n")
        try repo.write("untracked.txt", "u\n")
        let files = try await HistoryFixtures.open(repo).compareWithWorkingTree(ObjectID(hex: base)!)
        #expect(Set(files.map(\.path)) == ["shared.txt", "main.txt"])
    }

    @Test func compareRenames() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("a.txt", (1...30).map { "l\($0)" }.joined(separator: "\n"))
        let first = try await repo.commit("one")
        try await repo.git("mv", "a.txt", "b.txt")
        let second = try await repo.commit("two")
        let files = try await HistoryFixtures.open(repo).compare(
            ObjectID(hex: first)!, ObjectID(hex: second)!, mode: .direct)
        #expect(files.count == 1)
        #expect(files.first?.status == .renamed)
        #expect(files.first?.oldPath == "a.txt")
    }
}

@Suite struct HistorySearchTests {
    func loaded() async throws -> (TestRepo, HistorySnapshot, [String: String]) {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.authors = ["Ana Ruiz <ana@example.invalid>", "Bo Chen <bo@example.invalid>"]
        t.commit("Fix tab overflow")
        t.commit("Add refs panel")
        t.commit("Use [a-z]+ regex.* literally")
        t.branch("feature/search")
        t.commit("Search refs quickly")
        t.checkout("main")
        let oids = try await t.write(to: repo)
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        return (repo, snapshot, oids)
    }

    func subjects(_ snapshot: HistorySnapshot, _ query: String) -> [String] {
        snapshot.search(HistorySearchQuery(query)).map { snapshot.row(Int($0)).subject }
    }

    @Test func searchFreeTextCaseInsensitive() async throws {
        let (_, snapshot, _) = try await loaded()
        #expect(subjects(snapshot, "REFS") == ["Search refs quickly", "Add refs panel"])
        #expect(subjects(snapshot, "refs quickly") == ["Search refs quickly"])
        #expect(subjects(snapshot, "\"refs panel\"") == ["Add refs panel"])
    }

    @Test func searchHexPrefix() async throws {
        let (_, snapshot, oids) = try await loaded()
        let prefix = String(oids["Add refs panel"]!.prefix(7))
        #expect(subjects(snapshot, prefix) == ["Add refs panel"])
        #expect(subjects(snapshot, "sha:" + prefix) == ["Add refs panel"])
    }

    @Test func searchAuthorCaseInsensitive() async throws {
        let (_, snapshot, _) = try await loaded()
        #expect(subjects(snapshot, "author:bo").count == 2)  // commits 2 and 4 (authors alternate)
        #expect(subjects(snapshot, "author:ANA tab") == ["Fix tab overflow"])
    }

    @Test func searchRefToken() async throws {
        let (_, snapshot, _) = try await loaded()
        #expect(subjects(snapshot, "ref:feature/") == ["Search refs quickly"])
    }

    @Test func searchFixedStringMetachars() async throws {
        let (_, snapshot, _) = try await loaded()
        #expect(subjects(snapshot, "[a-z]+") == ["Use [a-z]+ regex.* literally"])
        #expect(subjects(snapshot, "regex.*") == ["Use [a-z]+ regex.* literally"])
        #expect(subjects(snapshot, "x.*z").isEmpty)
    }

    @Test func searchLoaded100kUnder30ms() async throws {
        let sandbox = try GitSandbox()
        let repo = try CommitStoreMemoryTests.fixture100k(sandbox)
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        let started = ContinuousClock.now
        let matches = snapshot.search(HistorySearchQuery("lane colours"))
        let elapsed = ContinuousClock.now - started
        print("search 100k: \(matches.count) matches in \(elapsed)")
        #expect(!matches.isEmpty)
        #expect(elapsed < PerfBudget.limit(.milliseconds(30)))
    }

    @Test func searchDeepFindsBodiesAndCancels() async throws {
        let repo = try await GitSandbox().makeRepository()
        try await repo.commit("first\n\nthe needle is in the body")
        try await repo.commit("second")
        let handle = try await HistoryFixtures.open(repo)
        let refs = try await handle.refs()
        var found: [ObjectID] = []
        for try await oid in handle.searchDeep(HistorySearchQuery("NEEDLE"), in: HistoryQuery(), refs: refs) {
            found.append(oid)
        }
        #expect(found.count == 1)
    }

    @Test func searchDeepCancel() async throws {
        let sandbox = try GitSandbox()
        let repo = try HistoryFixtures.synthetic(30_000, in: sandbox)
        let handle = try await HistoryFixtures.open(repo)
        let refs = try await handle.refs()
        let started = ContinuousClock.now
        let task = Task {
            var count = 0
            for try await _ in handle.searchDeep(
                HistorySearchQuery("zzz-never-matches"), in: HistoryQuery(), refs: refs)
            {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = try? await task.value
        #expect(
            ContinuousClock.now - started
                < .milliseconds(20) + TimingBudget.latency(.milliseconds(100) + .milliseconds(400)))
    }
}

@Suite struct HistoryInvalidationTests {
    func setUp() async throws -> (TestRepo, RepositoryHandle, HistorySnapshot, [String: String]) {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(3, prefix: "A")
        t.branch("feature")
        t.commit("F1")
        t.checkout("main")
        let oids = try await t.write(to: repo)
        let handle = try await HistoryFixtures.open(repo)
        let refs = try await handle.refs()
        let history = try await HistoryLoader(repository: handle, query: HistoryQuery(), refs: refs).ensureLoaded(.max)
        return (repo, handle, history, oids)
    }

    @Test func refreshUnchanged() async throws {
        let (repo, handle, history, _) = try await setUp()
        let refs = try await handle.refs()
        #expect(
            HistoryInvalidation.decide(old: history.refs, new: refs, history: history, query: HistoryQuery())
                == .unchanged)
        withExtendedLifetime(repo) {}
    }

    @Test func refreshLabelMoveInPlace() async throws {
        let (repo, handle, history, oids) = try await setUp()
        try await repo.git("tag", "v1", oids["A2"]!)
        try await repo.git("branch", "-f", "--", "other", oids["A1"]!)
        let refs = try await handle.refs()
        #expect(
            HistoryInvalidation.decide(old: history.refs, new: refs, history: history, query: HistoryQuery())
                == .labelsOnly)
    }

    @Test func refreshNewCommitReloads() async throws {
        let (repo, handle, history, _) = try await setUp()
        try await repo.commit("new on main")
        let refs = try await handle.refs()
        #expect(
            HistoryInvalidation.decide(old: history.refs, new: refs, history: history, query: HistoryQuery()) == .reload
        )
    }

    @Test func refreshDeletedBranchReloads() async throws {
        let (repo, handle, history, _) = try await setUp()
        try await repo.git("branch", "-D", "feature")
        let refs = try await handle.refs()
        #expect(
            HistoryInvalidation.decide(old: history.refs, new: refs, history: history, query: HistoryQuery()) == .reload
        )
    }

    @Test func refreshCheckoutOfLoadedCommitIsLabelsOnly() async throws {
        let (repo, handle, history, _) = try await setUp()
        try await repo.git("checkout", "-q", "feature")
        let refs = try await handle.refs()
        #expect(
            HistoryInvalidation.decide(old: history.refs, new: refs, history: history, query: HistoryQuery())
                == .labelsOnly)
    }
}
