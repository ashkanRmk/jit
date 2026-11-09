import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct RefsTests {
    func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    @Test func objectIDRoundTrip() throws {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        let id = try #require(ObjectID(hex: hex))
        #expect(id.hex() == hex)
        #expect(id.hex(length: 7) == "0123456")
        let long = String(repeating: "fedcba9876543210", count: 4)
        #expect(ObjectID(hex: long)?.hex(.sha256) == long)
        #expect(ObjectID(hex: "0123") == nil)
        #expect(ObjectID(hex: String(repeating: "g", count: 40)) == nil)
        #expect(ObjectID(hex: hex.uppercased()) == id)
        #expect(MemoryLayout<ObjectID>.stride == 32)
    }

    @Test func refsParseBranchesRemotesTags() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(3, prefix: "A")
        t.branch("feature/ui/tabs")
        t.commit("F1")
        t.checkout("main")
        t.tag("v1", at: "A1")
        t.tag("v2", at: "A2", message: "Annotated")
        t.ref("refs/remotes/origin/main", at: "A2")
        let oids = try await t.write(to: repo)
        try await repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        let snapshot = try await open(repo).refs()
        #expect(snapshot.head == .branch(name: "main", commit: ObjectID(hex: oids["A3"]!)!))
        #expect(snapshot.locals.map(\.shortName) == ["feature/ui/tabs", "main"])
        #expect(snapshot.locals.first { $0.isHead }?.shortName == "main")
        #expect(snapshot.remotes.map(\.shortName) == ["origin/main"])
        #expect(snapshot.remotes.first?.remoteName == "origin")
        #expect(snapshot.remoteHeads["origin"] == "refs/remotes/origin/main")
        #expect(snapshot.tags.map(\.shortName) == ["v1", "v2"])
        #expect(snapshot.format == .sha1)
        let byCommit = snapshot.refsByCommit()
        #expect(byCommit[ObjectID(hex: oids["A2"]!)!]?.count == 2)  // v2 (peeled) + origin/main
    }

    @Test func refsAnnotatedTagPeeled() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(2, prefix: "A")
        t.tag("release", at: "A1", message: "Release notes")
        let oids = try await t.write(to: repo)
        let tag = try #require(try await open(repo).refs().tags.first)
        #expect(tag.isAnnotatedTag)
        #expect(tag.commit == ObjectID(hex: oids["A1"]!))
        #expect(tag.object != tag.commit)
    }

    @Test func refsTagToBlobHasNoCommit() async throws {
        let repo = try await GitSandbox().makeRepository()
        try repo.write("a.txt", "a")
        try await repo.commit("A")
        let blob = try await repo.git("rev-parse", "HEAD:a.txt")
        try await repo.git("tag", "blobtag", blob)
        let tag = try #require(try await open(repo).refs().tags.first)
        #expect(tag.commit == nil)
        #expect(!tag.isAnnotatedTag)
    }

    @Test func refsParseDetachedHead() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(3, prefix: "A")
        t.detach(at: "A2")
        let oids = try await t.write(to: repo)
        let snapshot = try await open(repo).refs()
        #expect(snapshot.head == .detached(commit: ObjectID(hex: oids["A2"]!)!))
        #expect(!snapshot.refs.contains { $0.isHead })
    }

    @Test func refsParseUnborn() async throws {
        let repo = try await GitSandbox().makeRepository()
        let snapshot = try await open(repo).refs()
        #expect(snapshot.head == .unborn(branch: "main"))
        #expect(snapshot.refs.isEmpty)
    }

    @Test func refsUpstreamTrackingAndGone() async throws {
        let sandbox = try GitSandbox()
        let upstream = try await sandbox.makeRepository("upstream")
        try await upstream.commit("U1")
        try await upstream.git("branch", "doomed")
        let clone = sandbox.root + "/clone"
        try await sandbox.git(["clone", "-q", "--", upstream.path, clone], in: sandbox.root)
        let repo = TestRepo(sandbox: sandbox, path: clone)
        try await repo.git("branch", "--track", "doomed", "origin/doomed")
        try await repo.commit("L1")
        try await repo.commit("L2")
        try await upstream.commit("U2")
        try await upstream.git("branch", "-D", "doomed")
        try await repo.git("fetch", "-q", "--prune")
        let snapshot = try await open(repo).refs()
        let main = try #require(snapshot.locals.first { $0.shortName == "main" })
        #expect(main.upstream == "origin/main")
        #expect(main.ahead == 2)
        #expect(main.behind == 1)
        let doomed = try #require(snapshot.locals.first { $0.shortName == "doomed" })
        #expect(doomed.upstreamGone)
    }

    @Test func refsUnicodeBranchNames() async throws {
        let repo = try await GitSandbox().makeRepository()
        try await repo.commit("A")
        for name in ["feature/ñandú", "修正/タブ", "emoji-🌿"] { try await repo.branch(name) }
        let names = Set(try await open(repo).refs().locals.map(\.shortName))
        #expect(names == ["main", "feature/ñandú", "修正/タブ", "emoji-🌿"])
    }

    @Test func refsRevisionChangesWithRefs() async throws {
        let repo = try await GitSandbox().makeRepository()
        try await repo.commit("A")
        let handle = try await open(repo)
        let first = try await handle.refs().revision
        #expect(try await handle.refs().revision == first)
        try await repo.branch("x")
        #expect(try await handle.refs().revision != first)
    }

    @Test func parseTrackVariants() {
        func track(_ text: String) -> (Int, Int, Bool) {
            var copy = text
            return copy.withUTF8 {
                let t = RefParser.parseTrack(UnsafeRawBufferPointer($0)); return (t.ahead, t.behind, t.gone)
            }
        }
        #expect(track("") == (0, 0, false))
        #expect(track("gone") == (0, 0, true))
        #expect(track("ahead 2") == (2, 0, false))
        #expect(track("behind 15") == (0, 15, false))
        #expect(track("ahead 2, behind 5") == (2, 5, false))
    }

    @Test func refs10kBranchesUnder100ms() throws {
        // Parser cost only (Git's own time excluded); a synthetic 10k-branch output in Git's exact shape.
        let oid = String(repeating: "a1b2c3d4", count: 5)
        var output: [UInt8] = []
        for index in 0..<10_000 {
            output += Array(
                "refs/heads/team\(index % 40)/feature-\(index)\0\(oid)\0commit\0\0\0origin/x\0ahead 1, behind 2\0 \0\n"
                    .utf8)
        }
        let started = ContinuousClock.now
        let snapshot = try RefParser.parse(output, head: .unborn(branch: "main"), format: .sha1)
        let elapsed = ContinuousClock.now - started
        #expect(snapshot.refs.count == 10_000)
        #expect(elapsed < PerfBudget.limit(.milliseconds(100)), "parse took \(elapsed)")
    }
}

@Suite struct TagMessageTests {
    @Test func annotatedTagMessageExactObject() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(2, prefix: "A")
        t.tag("v1", at: "A1", message: "First release\n\nNotes")
        t.tag("v10", at: "A2", message: "Other")
        try await t.write(to: repo)
        let handle = try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let tag = try #require(try await handle.refs().tags.first { $0.shortName == "v1" })
        #expect(try await handle.tagMessage(object: tag.object) == "First release\n\nNotes")
    }
}
