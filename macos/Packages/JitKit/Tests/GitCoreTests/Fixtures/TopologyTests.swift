import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct TopologyTests {
    static func sample() -> Topology {
        var t = Topology()
        t.linear(3, prefix: "A")
        t.branch("feature")
        t.commit("F1")
        t.commit("F2")
        t.checkout("main")
        t.commit("A4")
        t.merge("feature", label: "M1")
        t.branch("x", from: "A2")
        t.commit("X1")
        t.branch("y", from: "A2")
        t.commit("Y1")
        t.checkout("main")
        t.merge("x", "y", label: "Octo")
        t.orphan("other")
        t.commit("R1")
        t.checkout("main")
        t.tag("v1", at: "A3")
        t.tag("v2", message: "Release 2")
        t.ref("refs/remotes/origin/main", at: "M1")
        return t
    }

    @Test func testkitTopologiesAreDeterministic() async throws {
        let first = try await GitSandbox().makeRepository()
        let second = try await GitSandbox().makeRepository()
        let a = try await Self.sample().write(to: first)
        let b = try await Self.sample().write(to: second)
        #expect(a == b)
        #expect(try await first.git("rev-parse", "HEAD") == a["Octo"])
    }

    @Test func topologyShapesMatchGit() async throws {
        let repo = try await GitSandbox().makeRepository()
        let oids = try await Self.sample().write(to: repo)
        let parents = try await repo.git("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ").map(
            String.init)
        #expect(parents == [oids["Octo"]!, oids["M1"]!, oids["X1"]!, oids["Y1"]!])
        #expect(try await repo.git("rev-list", "--count", "other") == "1")
        #expect(try await repo.git("cat-file", "-t", "v2") == "tag")
        #expect(try await repo.git("rev-parse", "v1") == oids["A3"])
        #expect(try await repo.git("rev-parse", "origin/main") == oids["M1"])
        #expect(try await repo.git("status", "--porcelain") == "")
    }

    @Test func detachedHead() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(3, prefix: "A")
        t.detach(at: "A2")
        let oids = try await t.write(to: repo)
        #expect(try await repo.git("rev-parse", "HEAD") == oids["A2"])
        await #expect(throws: (any Error).self) { try await repo.git("symbolic-ref", "-q", "HEAD") }
    }

    @Test func syntheticHistoryIsReproducible() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jit-synth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let shape = SyntheticHistory(commits: 1000, branches: 20, tags: 30)
        let a = try shape.build(at: base.appendingPathComponent("a").path)
        let b = try shape.build(at: base.appendingPathComponent("b").path)
        #expect(a == b)
        #expect(a.count == 40)
    }
}
