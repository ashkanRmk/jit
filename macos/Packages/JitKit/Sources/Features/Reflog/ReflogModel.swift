import Foundation
import GitCore
import Observation
import Services

struct ReflogRow: Identifiable, Equatable {
    let id: String
    let oid: ObjectID
    let action: String
    let message: String
    let timestamp: Int64
    let isUnreachable: Bool
    let looksLikeStash: Bool
}

@MainActor @Observable
final class ReflogModel {
    enum Mode: String, CaseIterable { case reflog = "Reflog", lost = "Lost Commits", recovery = "Recovery Points" }
    static let entryLimit = 2000
    let session: RepositorySession
    var isOpen = false
    var ref = "HEAD"
    var mode: Mode = .reflog
    private(set) var localRefs: [String] = []
    private(set) var entries: [ReflogRow] = []
    private(set) var lostCommits: [ReflogRow] = []
    private(set) var isLoading = false
    private(set) var isSlow = false
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var truncated = false
    private(set) var error: String?
    private(set) var next: ReflogCursor?
    var selection: String? {
        didSet { if oldValue != selection, let selected { onSelect(selected.oid) } }
    }
    @ObservationIgnored var onSelect: (ObjectID) -> Void = { _ in }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var slowTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(session: RepositorySession) { self.session = session }
    var rows: [ReflogRow] {
        switch mode {
        case .reflog: entries
        case .lost: lostCommits
        case .recovery:
            session.savedRecoveryPoints.compactMap { point in
                // Annotated tags and arbitrary refs may name non-commit objects. Preserve their exact
                // journal metadata, but the commit explorer only offers committed branch/stash states.
                guard
                    point.refName == "HEAD" || point.refName == "refs/stash"
                        || point.refName.hasPrefix("refs/heads/") || point.refName.hasPrefix("refs/remotes/")
                else { return nil }
                guard let oid = ObjectID(hex: point.oldOID) else { return nil }
                return ReflogRow(
                    id: point.id.uuidString, oid: oid, action: "Previous State",
                    message: "Before \(point.operation) · \(point.refName)",
                    timestamp: Int64(point.timestamp.timeIntervalSince1970), isUnreachable: false, looksLikeStash: false
                )
            }
        }
    }
    var selected: ReflogRow? { rows.first { $0.id == selection } }
    var format: ObjectFormat { session.history?.refs?.format ?? .sha1 }
    var canLoadMore: Bool { next != nil && entries.count < Self.entryLimit && !isLoading }
    var pageLimitReached: Bool { next != nil && entries.count >= Self.entryLimit }

    var lastRecoverableOperation: RecoveryPoint? {
        guard session.operationState == .clean else { return nil }
        let ref = session.status?.branch.head.map { "refs/heads/" + $0 } ?? "HEAD"
        let prefixes = [
            "Commit", "Amend commit", "Reset ", "Merge ", "Rebase ", "Cherry-pick", "Revert ", "Pull ", "Integrate ",
            "Continue", "Skip commit", "Interactive rebase", "Edit Message", "Drop Commit",
        ]
        return session.recoveryPoints.first { point in
            point.refName == ref && point.newOID == session.status?.branch.oid
                && prefixes.contains(where: point.operation.hasPrefix)
        }
    }

    func clearError() { error = nil }

    func open() { isOpen = true; reload() }
    func close() { isOpen = false; cancelReads() }
    func cancelReads() {
        generation += 1
        loadTask?.cancel(); loadTask = nil
        scanTask?.cancel(); scanTask = nil
        slowTask?.cancel(); slowTask = nil
        isLoading = false; isScanning = false; isSlow = false
    }

    func reload() {
        generation += 1
        loadTask?.cancel()
        entries = []; next = nil; selection = nil; error = nil
        loadPage(first: true)
    }

    func loadMore() { if canLoadMore { loadPage(first: false) } }

    private func loadPage(first: Bool) {
        guard let handle = session.repository else { error = "The repository is not ready. Try Refresh."; return }
        isLoading = true
        let generation = self.generation
        let ref = self.ref
        let cursor = first ? nil : next
        slowTask?.cancel()
        slowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { self?.isSlow = true }
        }
        loadTask = Task { [weak self] in
            do throws(GitCoreError) {
                let page = try await handle.reflogPage(ref: ref, cursor: cursor)
                let refs = first ? try await handle.refs().locals.map(\.fullName) : nil
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                if let refs { self.localRefs = refs }
                self.entries += page.entries.map {
                    ReflogRow(
                        id: $0.selector, oid: $0.oid, action: $0.action.title,
                        message: $0.message, timestamp: $0.timestamp, isUnreachable: $0.isUnreachable,
                        looksLikeStash: false)
                }
                self.next = page.next
                if first { await self.session.synchronizeRecoveryPoints() }
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                if error != .cancelled { self.error = error.summary }
            }
            guard let self, self.generation == generation else { return }
            self.isLoading = false; self.isSlow = false; self.loadTask = nil
            self.slowTask?.cancel(); self.slowTask = nil
        }
    }

    func findLostCommits() {
        guard !isScanning, !session.isBusy else { return }
        mode = .lost; selection = nil; error = nil; isScanning = true
        scanTask = Task { [weak self, session] in
            let result = await session.findLostCommits()
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false; self.scanTask = nil
            switch result {
            case .success(let result):
                self.hasScanned = true; self.truncated = result.truncated
                self.lostCommits = result.commits.map {
                    ReflogRow(
                        id: $0.oid.hex(self.format), oid: $0.oid,
                        action: $0.looksLikeStash ? "Possible Stash" : "Commit", message: $0.subject,
                        timestamp: $0.timestamp, isUnreachable: true, looksLikeStash: $0.looksLikeStash)
                }
            case .failure(let error): if !error.isCancellation { self.error = error.title }
            }
        }
    }

    func cancelScan() { scanTask?.cancel(); scanTask = nil; isScanning = false }
}
