import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@Suite @MainActor struct BlameModelTests {
    @Test func blameModelAssignsEveryLineAndGroupsBlocks() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "a\nb\nc\nd\n")
        let first = try await repo.commit("First")
        try repo.write("f.txt", "a\nB\nC\nd\ne\n")
        let second = try await repo.commit("Second")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        let model = BlameModel(session: session)
        model.handle = handle
        var revealed: ObjectID?
        model.revealCommit = { revealed = $0 }
        model.open(path: "f.txt", revision: nil)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while model.isLoading || model.lineCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.lineCount == 5 && model.attributedLines == 5)
        #expect((0..<5).map { model.commit(atLine: $0)?.id } == [first, second, second, first, second])
        #expect((0..<5).map { model.startsBlock($0) } == [true, true, false, true, true])
        #expect(model.text(1) == "B")
        let newest = try #require(model.commit(atLine: 1))
        #expect(model.age(newest) == 1)
        model.revealCommit(try #require(ObjectID(hex: second)))
        #expect(revealed == ObjectID(hex: second))
        model.close()
        #expect(!model.isOpen && model.lineCount == 0)
    }
}
