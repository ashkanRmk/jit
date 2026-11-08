import Features
import Foundation
import GitCore
import GitTestKit
import Testing

/// Exercises the app's view model against real repositories through `GitEngine`.
@MainActor @Suite struct JitAppTests {
    /// Test-only wait for the model to leave `.loading`.
    func settled(_ model: FoundationModel) async throws -> FoundationModel.State {
        for _ in 0..<200 {
            if case .loading = model.state {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                return model.state
            }
        }
        Issue.record("discovery did not finish")
        return model.state
    }

    @Test func discoverTempRepositoryThroughEngine() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("app-test")
        try repo.write("file.txt", "hello\n")
        let sha = try await repo.commit("Initial")

        let model = FoundationModel(engine: GitEngine(configuration: sandbox.engineConfiguration()))
        model.open(URL(fileURLWithPath: repo.path))
        guard case let .loaded(info, git) = try await settled(model) else {
            Issue.record("expected loaded state, got \(model.state)")
            return
        }
        #expect(info.topLevel == repo.path)
        #expect(info.head == .branch(name: "main", commit: sha))
        #expect(git.version >= .minimum)
    }

    @Test func notARepositoryShowsError() async throws {
        let sandbox = try GitSandbox()
        let folder = try sandbox.makeDirectory("plain")
        let engine = GitEngine(
            configuration: sandbox.engineConfiguration(extra: ["GIT_CEILING_DIRECTORIES": sandbox.root]))
        let model = FoundationModel(engine: engine)
        model.open(URL(fileURLWithPath: folder))
        #expect(try await settled(model) == .failed(URL(fileURLWithPath: folder), .notARepository(path: folder)))
    }

    @Test func cancellationThrowsCancelled() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let engine = GitEngine(configuration: sandbox.engineConfiguration())
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try await engine.discoverRepository(at: URL(fileURLWithPath: repo.path))
        }
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
    }

    @Test func newSelectionCancelsPreviousDiscovery() async throws {
        let sandbox = try GitSandbox()
        let first = try await sandbox.makeRepository("first")
        let second = try await sandbox.makeRepository("second")
        let model = FoundationModel(engine: GitEngine(configuration: sandbox.engineConfiguration()))
        model.open(URL(fileURLWithPath: first.path))
        model.open(URL(fileURLWithPath: second.path))
        guard case let .loaded(info, _) = try await settled(model) else {
            Issue.record("expected loaded state")
            return
        }
        #expect(info.topLevel == second.path)
    }
}
