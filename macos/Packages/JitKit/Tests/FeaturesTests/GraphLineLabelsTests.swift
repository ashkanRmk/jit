import Foundation
import GitCore
import GitTestKit
import Testing

@testable import Features

@MainActor @Suite struct GraphLineLabelsTests {
    func load(_ repo: TestRepo) async throws -> HistorySnapshot {
        let handle = try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let loader = HistoryLoader(repository: handle, query: HistoryQuery(), refs: try await handle.refs())
        return try await loader.ensureLoaded(.max)
    }

    func label(_ subject: String, in snapshot: HistorySnapshot, index: GraphLineLabels) throws -> RefLabel {
        let row = try #require((0..<snapshot.count).first { snapshot.row($0).subject == subject })
        return try #require(index.label(at: row))
    }

    @Test func deletedNestedBranchesKeepTheirNamesAndSharedAncestorsKeepMain() async throws {
        let repo = try await GitSandbox().makeRepository()
        var topology = Topology()
        topology.commit("Root")
        topology.branch("dev")
        topology.commit("Dev base")
        topology.branch("feature/topic")
        topology.linear(3, prefix: "Topic")
        topology.tag("v-topic", at: "Topic2")
        topology.checkout("dev")
        topology.commit("Dev work")
        topology.merge("feature/topic", label: "Merge branch 'feature/topic' into dev")
        topology.checkout("main")
        topology.commit("Main work")
        topology.merge("dev", label: "Merge branch 'dev'")
        try await topology.write(to: repo)
        try await repo.git("branch", "-D", "dev", "feature/topic")
        let snapshot = try await load(repo)
        var index = GraphLineLabels()
        #expect(index.append(snapshot: snapshot, labelsByCommit: GraphRowCache.labels(for: snapshot.refs)) == true)
        for subject in ["Root", "Main work", "Merge branch 'dev'"] {
            #expect(try label(subject, in: snapshot, index: index).text == "main")
        }
        for subject in ["Dev base", "Dev work", "Merge branch 'feature/topic' into dev"] {
            #expect(try label(subject, in: snapshot, index: index).text == "dev")
        }
        for subject in ["Topic1", "Topic2", "Topic3"] {
            let hint = try label(subject, in: snapshot, index: index)
            #expect(hint.text == "feature/topic")
            #expect(hint.kind == .historical)
            #expect(hint.fullName == nil)
        }
    }

    @Test func longHistoriesAndReusedLanesResolveEveryCommit() async throws {
        let repo = try await GitSandbox().makeRepository()
        var topology = Topology()
        topology.linear(2_105, prefix: "Main")
        for n in 0..<12 {
            topology.branch("topic\(n)")
            topology.commit("Work\(n)")
            topology.checkout("main")
            topology.merge("topic\(n)", label: "Merge branch 'topic\(n)'")
        }
        try await topology.write(to: repo)
        for n in 0..<12 { try await repo.git("branch", "-D", "topic\(n)") }
        let snapshot = try await load(repo)
        var index = GraphLineLabels()
        #expect(index.append(snapshot: snapshot, labelsByCommit: GraphRowCache.labels(for: snapshot.refs)) == true)
        #expect(try label("Main1", in: snapshot, index: index).text == "main")
        for n in 0..<12 {
            #expect(try label("Work\(n)", in: snapshot, index: index).text == "topic\(n)")
        }
        #expect((0..<snapshot.count).allSatisfy { index.label(at: $0) != nil })
    }

    @Test func paginationMatchesAWholeBuildAndLiveRefsTakePrecedence() async throws {
        let repo = try await GitSandbox().makeRepository()
        var topology = Topology()
        topology.commit("Root")
        topology.branch("topic")
        topology.linear(5, prefix: "Work")
        topology.checkout("main")
        topology.merge("topic", label: "Merge pull request #12 from owner/old-name")
        try await topology.write(to: repo)
        let handle = try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let refs = try await handle.refs()
        let loader = HistoryLoader(repository: handle, query: HistoryQuery(), refs: refs)
        let labels = GraphRowCache.labels(for: refs)
        var paged = GraphLineLabels()
        let first = try await loader.ensureLoaded(2)
        #expect(paged.append(snapshot: first, labelsByCommit: labels) == true)
        let whole = try await loader.ensureLoaded(.max)
        #expect(paged.append(snapshot: whole, labelsByCommit: labels) == true)
        var fresh = GraphLineLabels()
        #expect(fresh.append(snapshot: whole, labelsByCommit: labels) == true)
        for row in 0..<whole.count { #expect(paged.label(at: row) == fresh.label(at: row)) }
        #expect(try label("Work1", in: whole, index: paged).text == "topic")
        #expect(try label("Root", in: whole, index: paged).text == "main")
    }

    @Test func unnamedMergeFallsBackToContainingBranch() async throws {
        let repo = try await GitSandbox().makeRepository()
        var topology = Topology()
        topology.commit("Root")
        topology.branch("topic")
        topology.commit("Work")
        topology.checkout("main")
        topology.merge("topic", label: "Custom merge message")
        try await topology.write(to: repo)
        try await repo.git("branch", "-D", "topic")
        let snapshot = try await load(repo)
        var index = GraphLineLabels()
        #expect(index.append(snapshot: snapshot, labelsByCommit: GraphRowCache.labels(for: snapshot.refs)) == true)
        #expect(try label("Work", in: snapshot, index: index).text == "main")
    }
}
