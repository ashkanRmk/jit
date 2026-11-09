import Foundation
import GitCore
import GitTestKit
import Synchronization
import Testing

@testable import Services

/// P4.1 — OperationCenter lifecycle and the session's operation API on real repositories.
@MainActor @Suite struct OperationCenterTests {
    static let ada = IdentitySnapshot(
        author: GitIdentity(name: "Ada Lovelace", email: "ada@profile.example"),
        committer: GitIdentity(name: "Ada Lovelace", email: "ada@profile.example"))

    func session(_ repo: TestRepo) async throws -> RepositorySession {
        let handle = try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: repo.sandbox.engine, handle: handle, watchesFileSystem: false)
        session.activate()
        await session.settle()
        return session
    }

    @Test func recordsLifecycleAndBoundedHistory() async {
        let center = OperationCenter()
        for index in 0..<25 {
            _ = await center.run("Op \(index)", summarize: { (_: Int) in OperationSummary("ok \(index)") }) {
                _ throws(GitCoreError) in index
            }
        }
        #expect(center.records.count == OperationCenter.historyLimit)
        #expect(center.records.first?.title == "Op 24")
        #expect(center.records.first?.state == .succeeded("ok 24"))
        #expect(!center.isBusy)
    }

    @Test func failuresArePresentableAndCancellationIsNeutral() async {
        let center = OperationCenter()
        let failed = await center.run("Fails", summarize: { (_: Int) in OperationSummary("") }) {
            _ throws(GitCoreError) -> Int in
            throw .failed(ClassifiedFailure(kind: .authenticationFailed, summary: "needs credentials"))
        }
        guard case .failure(let error) = failed else {
            Issue.record("expected failure")
            return
        }
        #expect(error.title == "This remote needs credentials.")
        let cancelled = await center.run("Cancelled", summarize: { (_: Int) in OperationSummary("") }) {
            _ throws(GitCoreError) -> Int in
            throw .cancelled
        }
        guard case .failure(let neutral) = cancelled else { return }
        #expect(neutral.isCancellation)
        #expect(center.records.first?.state == .cancelled("Cancelled"))
    }

    @Test func cancelStopsCancellableOperation() async throws {
        let center = OperationCenter()
        let started = Locked(false)
        let task = Task {
            await center.run("Long", cancellation: .cancellable, summarize: { (_: Void) in OperationSummary("done") }) {
                _ throws(GitCoreError) in
                started.withLock { $0 = true }
                do { try await Task.sleep(for: .seconds(30)) } catch { throw .cancelled }
            }
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        let id = try #require(center.running.first?.id)
        center.cancel(id)
        let result = await task.value
        guard case .failure(let error) = result else {
            Issue.record("expected cancellation")
            return
        }
        #expect(error.isCancellation)
    }

    @Test func notCancellableIgnoresCancel() async throws {
        let center = OperationCenter()
        let started = Locked(false)
        let task = Task {
            await center.run(
                "Merge", cancellation: .notCancellable, summarize: { (_: Void) in OperationSummary("done") }
            ) {
                _ throws(GitCoreError) in
                started.withLock { $0 = true }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        center.cancel(try #require(center.running.first?.id))
        guard case .success = await task.value else {
            Issue.record("a non-cancellable operation must finish")
            return
        }
    }

    @Test func queuedOperationShowsWhatItWaitsFor() async throws {
        let center = OperationCenter()
        let release = Locked(false)
        let first = Task {
            await center.run("Fetch origin", summarize: { (_: Void) in OperationSummary("") }) {
                _ throws(GitCoreError) in
                while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        while center.running.isEmpty { await Task.yield() }
        let second = Task {
            await center.run("Push", summarize: { (_: Void) in OperationSummary("") }) { _ throws(GitCoreError) in }
        }
        while center.records.count < 2 { await Task.yield() }
        #expect(center.records.first { $0.title == "Push" }?.waitingFor == "Fetch origin")
        release.withLock { $0 = true }
        _ = await first.value
        _ = await second.value
    }

    @Test func orderingFollowsTheWriteGate() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        let session = try await session(repo)
        // Two branch creations started back to back run in order; both succeed.
        async let first = session.createBranch("one", at: "HEAD", switchTo: false, expected: nil)
        async let second = session.createBranch("two", at: "HEAD", switchTo: false, expected: nil)
        let results = await [first, second]
        for result in results {
            if case .failure(let error) = result { Issue.record("\(error)") }
        }
        #expect(try await repo.git("branch", "--list", "one", "two").split(separator: "\n").count == 2)
        #expect(session.operations.records.map(\.title).sorted() == ["Create branch one", "Create branch two"])
        session.close()
    }

    @Test func snapshotImmutableAcrossProfileSwitch() async throws {
        // The identity is captured when the operation is enqueued; changing the profile afterwards (even while
        // the operation waits behind another one) never changes who the commit is by.
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commit("Feature")
        try await repo.git("switch", "-q", "main")
        try repo.write("m.txt", "m\n")
        try await repo.commit("Main")
        let session = try await session(repo)
        let store = ProfileStore(
            location: StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/state", isDirectory: true)))
        store.create(GitProfile(displayName: "Work", colorIndex: 0, author: Self.ada.author), activate: true)
        let snapshot = try #require(store.snapshot())
        let context = ExecContext(identity: IdentitySnapshot(author: snapshot.author, committer: snapshot.committer))
        async let merge = session.merge(
            MergeRequest(source: "feature", strategy: .noFastForward), context: context, expected: nil)
        store.create(
            GitProfile(
                displayName: "Other", colorIndex: 1, author: GitIdentity(name: "Someone Else", email: "else@x.example")),
            activate: true)
        _ = await merge
        #expect(try await repo.git("log", "-1", "--format=%an|%cn") == "Ada Lovelace|Ada Lovelace")
        session.close()
    }

    @Test func sessionRefreshesOperationStateAfterConflict() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "1\n2\n3\n")
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("a.txt", "1\nF\n3\n")
        try await repo.commit("F")
        try await repo.git("switch", "-q", "main")
        try repo.write("a.txt", "1\nM\n3\n")
        try await repo.commit("M")
        let session = try await session(repo)
        let result = await session.merge(
            MergeRequest(source: "feature"), context: ExecContext(identity: Self.ada), expected: nil)
        #expect((try? result.get()) == .stoppedWithConflicts(paths: ["a.txt"]))
        for _ in 0..<200 where session.operationState == .clean { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.operationState == .merging(source: "feature", conflicted: 1))
        #expect(session.operations.records.first?.state == .needsAttention("Stopped with 1 conflicted file."))
        session.close()
    }

    @Test func stashListLoadsOnceTheRepositoryOpens() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        try repo.write("a.txt", "changed\n")
        try await repo.git("stash", "push", "-q", "-m", "kept")
        // No handle yet: a request made now must not be lost.
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.loadStashes()
        session.activate()
        await session.settle()
        for _ in 0..<200 where session.stashes == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.stashes?.map(\.message) == ["kept"])
        session.close()
    }

    @Test(arguments: FailureKind.allCases)
    func everyFailureKindHasAnExplanation(kind: FailureKind) {
        let error = PresentableError.make(.failed(ClassifiedFailure(kind: kind, summary: "x", detail: "detail")))
        #expect(!error.title.isEmpty)
        #expect(!error.explanation.isEmpty)
        #expect(!error.isCancellation)
    }

    @Test func hostKeyChangeNeverOffersRetry() {
        let error = PresentableError.make(.failed(ClassifiedFailure(kind: .sshHostKeyChanged, summary: "x")))
        #expect(!error.actions.contains(.retry))
    }
}
