import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Lane layout golden files (ADR-0021). Expected output lives in `Tests/GitCoreTests/Resources/lanes/`.
/// Regenerate with `UPDATE_GOLDEN=1 swift test --filter LaneGoldenTests` and review the diff by hand.
///
/// Line format: `<subject> | <cells> | n<lane>:<colour> <flags> | <segments>` — cells: `*` commit,
/// `M` merge, `o` root, `|` lane passing by, `\` / `/` a lane curving into the node; flags `t` tip,
/// `h` HEAD; segments `T`op/`B`ottom/`F`ull `<from>><to>:<colour>`.
@Suite struct LaneGoldenTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/lanes")

    static func render(_ snapshot: HistorySnapshot, limit: Int? = nil) -> String {
        var lines: [String] = []
        let rows = Array(0..<snapshot.count)
        let selected: [Int]
        if let limit, rows.count > 2 * limit {
            selected = Array(rows.prefix(limit)) + [-1] + Array(rows.suffix(limit))
        } else {
            selected = rows
        }
        for index in selected {
            if index < 0 {
                lines.append("… \(snapshot.count - 2 * (limit ?? 0)) rows …")
                continue
            }
            let row = snapshot.row(index)
            lines.append("\(row.subject.padding(toLength: 6, withPad: " ", startingAt: 0)) \(LaneDump.line(row))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func check(_ name: String, _ topology: Topology, scope: HistoryScope = .all, limit: Int? = nil) async throws
    {
        let repo = try await GitSandbox().makeRepository()
        try await topology.write(to: repo)
        let snapshot = try await HistoryFixtures.loader(repo, HistoryQuery(scope: scope)).ensureLoaded(.max)
        let actual = render(snapshot, limit: limit)
        let file = directory.appendingPathComponent("\(name).txt")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try actual.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: file, encoding: .utf8)
        #expect(actual == expected, "\(name) differs from its golden file:\n\(actual)")
    }

    @Test func lanesLinear() async throws {
        var t = Topology()
        t.linear(5, prefix: "A")
        try await Self.check("linear", t)
    }

    @Test func lanesSimpleMerge() async throws {
        var t = Topology()
        t.linear(2, prefix: "A")
        t.branch("feature")
        t.linear(2, prefix: "F")
        t.checkout("main")
        t.commit("A3")
        t.merge("feature", label: "M")
        try await Self.check("simple-merge", t)
    }

    @Test func lanesOctopus3() async throws {
        var t = Topology()
        t.commit("A1")
        for name in ["x", "y", "z"] {
            t.branch(name, from: "A1")
            t.commit(name.uppercased() + "1")
        }
        t.checkout("main")
        t.commit("A2")
        t.merge("x", "y", "z", label: "Octo")
        try await Self.check("octopus3", t)
    }

    @Test func lanesCrisscross() async throws {
        var t = Topology()
        t.commit("A1")
        t.branch("b")
        t.commit("B1")
        t.checkout("main")
        t.commit("A2")
        t.merge("b", label: "MA")
        t.checkout("b")
        t.merge("A2", label: "MB")
        t.checkout("main")
        t.commit("A3")
        t.checkout("b")
        t.commit("B2")
        t.checkout("main")
        t.merge("b", label: "M2")
        try await Self.check("crisscross", t)
    }

    @Test func lanesLongLivedDevelop() async throws {
        var t = Topology()
        t.commit("A1")
        t.branch("develop")
        for cycle in 1...3 {
            t.checkout("develop")
            t.linear(2, prefix: "D\(cycle)")
            t.checkout("main")
            t.commit("H\(cycle)")
            t.merge("develop", label: "R\(cycle)")
            t.checkout("develop")
            t.merge("main", label: "S\(cycle)")
        }
        t.checkout("main")
        try await Self.check("long-lived-develop", t)
    }

    @Test func lanesRebasedBranch() async throws {
        var t = Topology()
        t.linear(3, prefix: "A")
        t.branch("feature")
        t.linear(3, prefix: "F")
        t.checkout("main")
        try await Self.check("rebased-branch", t)
    }

    @Test func lanes40Parallel() async throws {
        var t = Topology()
        t.commit("Base")
        for index in 0..<40 {
            t.branch("p\(index)", from: "Base")
            t.commit("P\(index)")
        }
        t.checkout("main")
        t.commit("A2")
        try await Self.check("40-parallel", t)
    }

    @Test func lanesDetachedHead() async throws {
        var t = Topology()
        t.linear(4, prefix: "A")
        t.branch("side", from: "A2")
        t.commit("S1")
        t.checkout("main")
        t.detach(at: "S1")
        try await Self.check("detached-head", t)
    }

    @Test func lanesOrphanRoot() async throws {
        var t = Topology()
        t.linear(3, prefix: "A")
        t.orphan("pages")
        t.linear(2, prefix: "P")
        t.checkout("main")
        t.commit("A4")
        try await Self.check("orphan-root", t)
    }

    @Test func lanesLateSecondParent10k() async throws {
        var t = Topology()
        t.commit("Base")
        t.branch("late")
        t.commit("L1")
        t.checkout("main")
        t.linear(10_000, prefix: "A")
        t.merge("late", label: "M")
        try await Self.check("late-second-parent-10k", t, limit: 8)
    }
}

@Suite struct LanePropertyTests {
    /// layout(all at once) == layout(read in pages and odd-sized pipe reads), for random DAGs.
    @Test(arguments: [UInt64(1), 2, 3, 5, 8, 13, 21, 34])
    func lanesPrefixStableAnyPageSize(seed: UInt64) async throws {
        let repo = try await GitSandbox().makeRepository()
        try await RandomTopology.make(seed: seed, commits: 400).write(to: repo)
        let whole = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        var rng = SyntheticHistory.Generator(state: seed &* 7919)
        for _ in 0..<3 {
            let loader = try await HistoryFixtures.loader(repo)
            await loader.setReadSizes((0..<16).map { _ in 1 + rng.below(4096) })
            var snapshot = HistorySnapshot.empty()
            repeat {
                snapshot = try await loader.ensureLoaded(snapshot.count + 1 + rng.below(2000))
                // Rows already published never change.
                #expect(
                    Array(LaneDump.rows(snapshot)) == Array(LaneDump.rows(whole).prefix(snapshot.count)), "seed \(seed)"
                )
            } while !snapshot.complete
            #expect(snapshot.count == whole.count, "seed \(seed)")
        }
    }

    @Test func lanesDeterministicAcrossRuns() async throws {
        let first = try await GitSandbox().makeRepository()
        let second = try await GitSandbox().makeRepository()
        try await RandomTopology.make(seed: 99, commits: 300).write(to: first)
        try await RandomTopology.make(seed: 99, commits: 300).write(to: second)
        let a = try await HistoryFixtures.loader(first).ensureLoaded(.max)
        let b = try await HistoryFixtures.loader(second).ensureLoaded(.max)
        #expect(LaneDump.rows(a) == LaneDump.rows(b))
    }

    @Test func lanesColorStableForBranchName() async throws {
        // The same branch name gets the same colour in unrelated repositories (unless an adjacent lane
        // already uses it).
        func color(of branch: String, extra: Int) async throws -> UInt8 {
            let repo = try await GitSandbox().makeRepository()
            var t = Topology()
            t.linear(1 + extra, prefix: "A")
            t.branch(branch)
            t.commit("F1")
            t.checkout("main")
            t.commit("Top")
            try await t.write(to: repo)
            let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
            let row = try #require((0..<snapshot.count).map(snapshot.row).first { $0.subject == "F1" })
            return row.nodeColor
        }
        let first = try await color(of: "feature/tabs", extra: 0)
        #expect(try await color(of: "feature/tabs", extra: 5) == first)
        #expect(first != 0)
    }

    @Test func headBranchUsesSlotZero() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(3, prefix: "A")
        t.branch("feature")
        t.commit("F1")
        try await t.write(to: repo)  // HEAD = feature
        let snapshot = try await HistoryFixtures.loader(repo).ensureLoaded(.max)
        let head = snapshot.row(try #require(snapshot.headRow))
        #expect(head.nodeColor == 0)
        #expect(head.flags.contains(.head))
    }

    @Test func pinLeftAssignsLaneZero() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(2, prefix: "A")
        t.branch("pinned")
        t.commit("P1")
        t.checkout("main")
        t.linear(3, prefix: "B")
        try await t.write(to: repo)
        let loader = try await HistoryFixtures.loader(repo, HistoryQuery(pinned: ["refs/heads/pinned"]))
        let snapshot = try await loader.ensureLoaded(.max)
        let rows = (0..<snapshot.count).map(snapshot.row)
        #expect(rows.first { $0.subject == "P1" }?.nodeLane == 0)
        #expect(rows.first { $0.subject == "B3" }?.nodeLane != 0)
        // The reserved lane draws nothing above the pinned tip.
        #expect(rows.first!.segments.allSatisfy { $0.fromLane != 0 || $0.toLane != 0 || $0.half == .bottom })
    }
}

@Suite(.serialized) struct LanePerformanceTests {
    /// Parse + lay out + store 100k commits from captured `git log` output (Git's own time excluded).
    @Test func lanesLayout100kUnder150ms() async throws {
        let sandbox = try GitSandbox()
        let repo = try CommitStoreMemoryTests.fixture100k(sandbox)
        let handle = try await HistoryFixtures.open(repo)
        let refs = try await handle.refs()
        let query = HistoryQuery()
        let output = try await sandbox.engine.run(
            GitCommand(query.arguments(refs: refs, skip: 0)!, in: repo.path, timeout: nil, stdoutLimit: 1 << 30))
        var parser = LogParser()
        var layouter = LaneLayouter(refs: refs)
        var layoutOnly = Duration.zero
        let clock = ContinuousClock()
        let started = clock.now
        var builder = CommitStoreBuilder()
        try parser.consume(output.stdout) { (record: borrowing LogParser.Record) throws(GitCoreError) in
            let author = builder.internAuthor(name: record.name, email: record.email)
            let layoutStart = clock.now
            layouter.layout(oid: record.oid, parents: record.parents, subject: record.subject)
            layoutOnly += clock.now - layoutStart
            builder.append(
                oid: record.oid, parents: record.parents, author: author, time: record.time, subject: record.subject,
                lane: layouter.output)
        }
        let total = clock.now - started
        print("100k: parse+layout+store \(total), layout alone \(layoutOnly)")
        #expect(builder.count == 100_000)
        #expect(layoutOnly < PerfBudget.limit(.milliseconds(150)))
    }
}
