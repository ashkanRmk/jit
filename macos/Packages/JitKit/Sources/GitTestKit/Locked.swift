import Synchronization

/// A `Mutex` in a `Sendable` reference, for state shared by test tasks. A bare local `Mutex` captured by
/// `Task {}` / `addTask {}` closures is accepted by Swift 6.4 but rejected by Swift 6.3's region-based
/// isolation check ("passing closure as a 'sending' parameter risks causing data races"), which CI's
/// Xcode 26 uses. Same `withLock` API as `Mutex`.
public final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    public init(_ value: sending Value) { mutex = Mutex(value) }

    public func withLock<Result: Sendable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        try mutex.withLock(body)
    }
}
