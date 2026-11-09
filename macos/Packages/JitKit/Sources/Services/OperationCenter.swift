import Foundation
import GitCore
import Observation

/// Whether the user may cancel a running operation (design §4.4).
public enum OperationCancellation: Sendable, Equatable {
    case notCancellable
    case cancellable
    /// Cancellable, but the remote may already have changed (push).
    case cancellableWithWarning
}

/// One operation in a repository's activity list (design §3.1).
public struct OperationRecord: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case succeeded(String)
        case failed(PresentableError)
        case cancelled(String)
        /// Stopped with conflicts (or another state needing the user): links to the banner.
        case needsAttention(String)

        public var isFinished: Bool { self != .running }
    }

    public let id: UUID
    public let title: String
    public let started: Date
    public var finished: Date?
    public var state: State
    public var progress: OperationProgress?
    public let cancellation: OperationCancellation
    /// Another operation of this repository runs first (shown "Waiting for …").
    public var waitingFor: String?

    public var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
}

/// What an outcome means for the activity list.
public struct OperationSummary: Sendable, Equatable {
    public var message: String
    public var needsAttention: Bool

    public init(_ message: String, needsAttention: Bool = false) {
        self.message = message
        self.needsAttention = needsAttention
    }
}

/// The per-repository operation log and lifecycle (design §4.2, ADR-0015). It does not queue work: requests go
/// straight to the repository's `RepositoryHandle`, whose write gate is the one serialization primitive; this
/// mirrors the order for display. Cancellation cancels the operation's `Task` (→ `killpg` on its Git
/// children). History is in memory only, bounded to 20 finished operations.
@MainActor @Observable
public final class OperationCenter {
    public static let historyLimit = 20

    /// Newest first: running operations, then finished ones.
    public private(set) var records: [OperationRecord] = []
    /// Bumped when an operation finishes (one-shot UI feedback).
    public private(set) var finishedCount = 0

    /// Cancels the `Task` running each operation's body.
    @ObservationIgnored private var cancellers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var running: [OperationRecord] { records.filter { $0.state == .running } }
    public var isBusy: Bool { records.contains { $0.state == .running } }
    /// The oldest running operation (the one holding the repository's write gate).
    public var current: OperationRecord? { records.last { $0.state == .running } }
    public var lastFinished: OperationRecord? { records.first { $0.state.isFinished } }

    /// Runs `body` as a tracked operation and returns its result. `progress` is a bounded stream
    /// (`.bufferingNewest(1)`), folded into the record on the main actor.
    @discardableResult
    public func run<T: Sendable>(
        _ title: String, cancellation: OperationCancellation = .notCancellable,
        summarize: @escaping @Sendable (T) -> OperationSummary,
        _ body: @escaping @Sendable (AsyncStream<OperationProgress>.Continuation) async throws(GitCoreError) -> T
    ) async -> Result<T, PresentableError> {
        let id = UUID()
        records.insert(
            OperationRecord(
                id: id, title: title, started: Date(), state: .running, cancellation: cancellation,
                waitingFor: current?.title),
            at: 0)
        let (stream, continuation) = AsyncStream.makeStream(
            of: OperationProgress.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task { [weak self] in
            for await value in stream { self?.update(id) { $0.progress = value } }
        }
        let work = Task { () -> Result<T, GitCoreError> in
            defer { continuation.finish() }
            do throws(GitCoreError) {
                return .success(try await body(continuation))
            } catch {
                return .failure(error)
            }
        }
        cancellers[id] = { work.cancel() }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        cancellers[id] = nil
        await progressTask.value
        switch outcome {
        case .success(let value):
            let summary = summarize(value)
            finish(id, summary.needsAttention ? .needsAttention(summary.message) : .succeeded(summary.message))
            return .success(value)
        case .failure(let error):
            let presentable = PresentableError.make(error)
            finish(id, presentable.isCancellation ? .cancelled("Cancelled") : .failed(presentable))
            return .failure(presentable)
        }
    }

    /// Cancels a running operation if it is cancellable (its Git children get SIGTERM via their group).
    public func cancel(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.state == .running,
            record.cancellation != .notCancellable
        else { return }
        cancellers[id]?()
    }

    /// Cancels every cancellable operation (app quit); returns the titles of those that must finish first.
    public func cancelAllCancellable() -> [String] {
        var unsafe: [String] = []
        for record in records where record.state == .running {
            if record.cancellation == .notCancellable { unsafe.append(record.title) } else { cancel(record.id) }
        }
        return unsafe
    }

    public func clearHistory() {
        records.removeAll { $0.state.isFinished }
    }

    private func update(_ id: UUID, _ change: (inout OperationRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }

    private func finish(_ id: UUID, _ state: OperationRecord.State) {
        update(id) { record in
            record.state = state
            record.finished = Date()
            record.progress = nil
            record.waitingFor = nil
        }
        for index in records.indices where records[index].waitingFor != nil && records[index].state == .running {
            records[index].waitingFor =
                records.last {
                    $0.state == .running && $0.id != records[index].id && $0.started < records[index].started
                }?.title
        }
        finishedCount += 1
        // Keep running ones plus the newest `historyLimit` finished ones.
        var finished = 0
        records.removeAll { record in
            guard record.state.isFinished else { return false }
            finished += 1
            return finished > Self.historyLimit
        }
    }
}
