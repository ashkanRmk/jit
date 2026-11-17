import Foundation
import GitCore
import GitTestKit
import Testing

@testable import GitCore
@testable import Services

@MainActor @Suite struct RecoveryJournalTests {
    @Test func sessionRecordsAmendAndReopensJournalWithoutOfferingOldUndo() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "original\n")
        let initial = try await repo.commit("Original")
        let location = StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/state"))
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle,
            watchesFileSystem: false, recoveryLocation: location)
        let identity = GitIdentity(name: "Tester", email: "tester@jit.invalid")
        _ = try await session.commit(
            CommitRequest(
                message: "Amended", amend: true,
                identity: IdentitySnapshot(author: identity, committer: identity)))
        #expect(session.recoveryPoints.first?.oldOID == initial)
        #expect(!session.savedRecoveryPoints.isEmpty)
        let nextHandle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let next = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: nextHandle,
            watchesFileSystem: false, recoveryLocation: location)
        await next.synchronizeRecoveryPoints()
        #expect(next.recoveryPoints.isEmpty)
        #expect(next.savedRecoveryPoints.first?.oldOID == initial)
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: location.directory.path).first)
        let mode = try FileManager.default.attributesOfItem(atPath: location.url(file).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        session.close(); next.close()
    }

    @Test func journalKeepsFiftyAndSeparatesRepositories() async throws {
        let sandbox = try GitSandbox()
        let location = StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/journal"))
        let journal = RecoveryJournal(repository: "/repo/one", location: location)
        let points = (0..<60).map { index in
            RecoveryPoint(
                id: UUID(), operationID: UUID(), operation: "Amend",
                refName: "refs/heads/main", oldOID: String(repeating: "a", count: 40),
                newOID: String(repeating: "b", count: 40), timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let saved = await journal.synchronize(points)
        #expect(saved.points.count == 50)
        #expect(saved.points.first?.timestamp == points.last?.timestamp)
        let reloaded = await journal.synchronize([])
        #expect(reloaded.points.map(\.id) == saved.points.map(\.id))
        let other = RecoveryJournal(repository: "/repo/two", location: location)
        #expect(await other.synchronize([]).points.isEmpty)
    }
}
