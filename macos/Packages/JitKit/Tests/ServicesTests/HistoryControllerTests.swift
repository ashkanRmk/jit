import Foundation
import GitCore
import GitTestKit
import Testing

@testable import Services

/// Live refresh (ADR-0024) through the controller the graph uses.
@MainActor @Suite(.serialized) struct HistoryControllerTests {
    func make(_ repo: TestRepo) async throws -> HistoryController {
        let handle = try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let controller = HistoryController(handle: handle)
        controller.start()
        try await until { controller.snapshot.count > 0 }
        return controller
    }

    /// Waits for a condition driven by async work (test-only helper; production code never polls).
    func until(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + TimingBudget.latency(timeout)
        while !condition() {
            if ContinuousClock.now > deadline { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func externalCommitAppearsAsReplacementKeepingRows() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(5, prefix: "A")
        try await t.write(to: repo)
        let controller = try await make(repo)
        var updates: [HistoryController.Update] = []
        controller.onUpdate = { updates.append($0) }
        let started = ContinuousClock.now
        let new = try await repo.commit("from Terminal")
        controller.refsMayHaveChanged()
        try await until { controller.snapshot.count == 6 }
        print("external commit visible after \(ContinuousClock.now - started)")
        #expect(controller.snapshot.row(0).oid.hex() == new)
        #expect(updates == [.replaced])
        #expect(ContinuousClock.now - started < TimingBudget.latency(.milliseconds(500)))
    }

    @Test func labelMoveUpdatesInPlace() async throws {
        let repo = try await GitSandbox().makeRepository()
        var t = Topology()
        t.linear(5, prefix: "A")
        let oids = try await t.write(to: repo)
        let controller = try await make(repo)
        var updates: [HistoryController.Update] = []
        controller.onUpdate = { updates.append($0) }
        let replacements = controller.replacements
        try await repo.git("tag", "v1", oids["A3"]!)
        controller.refsMayHaveChanged()
        try await until { !updates.isEmpty }
        #expect(updates == [.labels])
        #expect(controller.replacements == replacements)
        #expect(controller.refs?.tags.count == 1)
    }

    @Test func inactiveTabDefersRefresh() async throws {
        let repo = try await GitSandbox().makeRepository()
        try await repo.commit("one")
        let controller = try await make(repo)
        var updates: [HistoryController.Update] = []
        controller.onUpdate = { updates.append($0) }
        controller.deactivate()
        try await repo.commit("two")
        controller.refsMayHaveChanged()
        try await Task.sleep(for: .milliseconds(300))
        #expect(updates.isEmpty)
        #expect(controller.snapshot.count == 1)
        controller.activate()
        try await until { controller.snapshot.count == 2 }
        #expect(updates == [.replaced])
    }

    @Test func pagesAppendWithoutReplacing() async throws {
        let sandbox = try GitSandbox()
        let path = sandbox.root + "/big"
        try SyntheticHistory(commits: 6000, branches: 10).build(at: path, environment: sandbox.environment)
        let controller = try await make(TestRepo(sandbox: sandbox, path: path))
        var updates: [HistoryController.Update] = []
        controller.onUpdate = { updates.append($0) }
        let first = controller.snapshot.count
        #expect(first < 6000)
        await controller.loadRows(atLeast: 6000)
        #expect(controller.snapshot.count == 6000)
        #expect(updates.allSatisfy { if case .appended = $0 { true } else { false } })
        #expect(updates.first == .appended(from: first))
    }
}
