import Foundation

/// Monotonic counter of mutations Jit performed through one `RepositoryHandle` (ADR-0027). Reads tag
/// their results with the revision they observed; the UI discards results older than the latest one.
public struct RepoRevision: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static func < (lhs: RepoRevision, rhs: RepoRevision) -> Bool { lhs.value < rhs.value }
    public var description: String { "r\(value)" }
}

/// What the write gate is doing, for busy UI (design §4.7). Queued operations are shown as pending,
/// never silently dropped.
public struct WriteGateState: Sendable, Equatable {
    public var current: String?
    public var pending: [String]

    public init(current: String? = nil, pending: [String] = []) {
        self.current = current
        self.pending = pending
    }

    public var isBusy: Bool { current != nil }
}

/// FIFO mutual exclusion that holds across suspension points (ADR-0027).
///
/// Actor isolation alone does not serialize async work: every `await` inside an actor method lets other
/// calls in. The gate is plain state owned by the actor; `acquire` suspends callers in arrival order and
/// `release` hands the gate directly to the next waiter, so no third caller can slip in between.
struct WriteGate {
    private struct Waiter {
        let id: UInt64
        let description: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var current: String?
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    var state: WriteGateState { WriteGateState(current: current, pending: waiters.map(\.description)) }

    /// Takes the gate now if it is free; otherwise returns a ticket to wait on.
    mutating func tryAcquire(_ description: String) -> Bool {
        guard current == nil else { return false }
        current = description
        return true
    }

    mutating func makeTicket() -> UInt64 {
        nextID &+= 1
        return nextID
    }

    mutating func enqueue(_ id: UInt64, _ description: String, _ continuation: CheckedContinuation<Bool, Never>) {
        waiters.append(Waiter(id: id, description: description, continuation: continuation))
    }

    /// A cancelled waiter leaves the queue (resumed with `false`). No effect once it holds the gate.
    mutating func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Hands the gate to the next waiter, or frees it.
    mutating func release() {
        guard !waiters.isEmpty else {
            current = nil
            return
        }
        let next = waiters.removeFirst()
        current = next.description
        next.continuation.resume(returning: true)
    }
}
