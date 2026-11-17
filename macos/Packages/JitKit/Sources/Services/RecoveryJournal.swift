import Foundation
import GitCore

/// Bounded recovery metadata outside the user's repository. Loading this journal never makes old
/// operations eligible for automatic Undo: the live handle alone identifies this session's operations.
actor RecoveryJournal {
    struct Document: Codable {
        var version = 1
        var repository: String
        var points: [RecoveryPoint]
    }

    let repository: String
    let url: URL

    init(repository: String, location: StoreLocation) {
        self.repository = repository
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in repository.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        url = location.url("recovery-\(String(hash, radix: 16)).json")
    }

    func synchronize(_ current: [RecoveryPoint]) -> (points: [RecoveryPoint], error: String?) {
        let previous = JSONFile.load(Document.self, at: url, version: 1).value
        var points = current
        let ids = Set(current.map(\.id))
        if let previous, previous.repository == repository { points += previous.points.filter { !ids.contains($0.id) } }
        points.sort { $0.timestamp > $1.timestamp }
        points = Array(points.prefix(RepositoryHandle.recoveryPointLimit))
        guard !current.isEmpty else { return (points, nil) }
        if previous?.repository == repository, previous?.points.map(\.id) == points.map(\.id) { return (points, nil) }
        do {
            try JSONFile.write(JSONFile.encode(Document(repository: repository, points: points)), to: url)
            return (points, nil)
        } catch {
            return (points, "Recovery history could not be saved. Git's reflog is still available.")
        }
    }
}

extension RepositorySession {
    /// Points from this live handle only. Earlier sessions' journal entries are informative.
    public func synchronizeRecoveryPoints() async {
        guard let handle = repository else { return }
        let current = await handle.recoveryPoints
        let saved = await recoveryJournal.synchronize(current)
        guard lifecycle != .closed else { return }
        recoveryPoints = current
        savedRecoveryPoints = saved.points
        recoveryJournalError = saved.error
    }

    public func findLostCommits() async -> Result<LostCommitResult, PresentableError> {
        guard let handle = repository, lifecycle != .closed else { return .failure(PresentableError.make(.cancelled)) }
        return await operations.run(
            "Find lost commits", cancellation: .cancellable,
            summarize: { result in
                OperationSummary(
                    "Found \(result.commits.count) lost commits\(result.truncated ? " (result limit reached)" : "").")
            }
        ) { progress throws(GitCoreError) in
            try await handle.findUnreachable(progress: progress)
        }
    }
}
