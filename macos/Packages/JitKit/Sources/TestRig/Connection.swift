import Foundation
import Network

/// Buffered, callback-driven wrapper over `NWConnection`. All state is confined to `queue` (the queue the
/// connection was started on, and on which Network delivers every callback), hence `@unchecked Sendable`.
/// Connections that are spliced together share one queue.
final class RigConnection: @unchecked Sendable {
    let nw: NWConnection
    let queue: DispatchQueue
    private var buffer = Data()
    private var isEOF = false
    private var started = false
    private(set) var isClosed = false

    static let maxChunk = 64 * 1024

    init(_ nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
    }

    /// The state handler retains `self` until the connection is cancelled, which keeps the session alive.
    func start(ready: @escaping @Sendable () -> Void, failed: @escaping @Sendable (String) -> Void = { _ in }) {
        nw.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                if !started {
                    started = true
                    ready()
                }
            case .waiting(let error), .failed(let error):
                if !started {
                    started = true
                    failed("\(error)")
                }
                close()
            case .cancelled:
                isClosed = true
                nw.stateUpdateHandler = nil
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        nw.cancel()
    }

    // MARK: Reading

    private func fill(_ done: @escaping @Sendable (Bool) -> Void) {
        if isEOF || isClosed {
            done(false)
            return
        }
        nw.receive(minimumIncompleteLength: 1, maximumLength: Self.maxChunk) { [self] data, _, isComplete, error in
            var got = false
            if let data, !data.isEmpty {
                buffer.append(data)
                got = true
            }
            if isComplete || error != nil { isEOF = true }
            if got || isEOF { done(got) } else { fill(done) }
        }
    }

    private func take(_ count: Int) -> Data {
        let head = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return head
    }

    /// Bytes up to (excluding) `delimiter`, consuming the delimiter. `nil` on EOF or when `max` is exceeded.
    func read(until delimiter: Data, max: Int, _ completion: @escaping @Sendable (Data?) -> Void) {
        if let range = buffer.range(of: delimiter) {
            let length = range.lowerBound - buffer.startIndex
            let head = take(length)
            _ = take(delimiter.count)
            completion(head)
            return
        }
        if buffer.count > max {
            completion(nil)
            return
        }
        fill { [self] got in
            if got { read(until: delimiter, max: max, completion) } else { completion(nil) }
        }
    }

    func readLine(max: Int = 8 * 1024, _ completion: @escaping @Sendable (Data?) -> Void) {
        read(until: Data("\r\n".utf8), max: max, completion)
    }

    func read(exactly count: Int, _ completion: @escaping @Sendable (Data?) -> Void) {
        if buffer.count >= count {
            completion(take(count))
            return
        }
        fill { [self] got in
            if got { read(exactly: count, completion) } else { completion(nil) }
        }
    }

    /// At least one and at most `max` bytes; buffered bytes first. `nil` at EOF.
    func readSome(max: Int = RigConnection.maxChunk, _ completion: @escaping @Sendable (Data?) -> Void) {
        if !buffer.isEmpty {
            completion(take(min(max, buffer.count)))
            return
        }
        fill { [self] got in
            if got { readSome(max: max, completion) } else { completion(nil) }
        }
    }

    // MARK: Writing

    func send(_ data: Data, _ completion: @escaping @Sendable ((any Error)?) -> Void) {
        nw.send(content: data, completion: .contentProcessed { error in completion(error) })
    }

    /// Half-close (FIN) after pending data.
    func shutdownWrite() {
        nw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Opens an outbound TCP connection on this connection's queue (for proxy tunnels).
    func connectUpstream(
        host: String, port: UInt16, ready: @escaping @Sendable (RigConnection) -> Void,
        failed: @escaping @Sendable (String) -> Void
    ) {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            failed("invalid port")
            return
        }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let upstream = RigConnection(NWConnection(host: NWEndpoint.Host(bare), port: nwPort, using: .tcp), queue: queue)
        upstream.start(ready: { ready(upstream) }, failed: failed)
    }
}

/// Copies bytes in both directions until both sides finish, then closes both.
final class Tunnel: @unchecked Sendable {
    private let a: RigConnection
    private let b: RigConnection
    private var finishedDirections = 0

    init(_ a: RigConnection, _ b: RigConnection) {
        self.a = a
        self.b = b
    }

    func start() {
        pump(from: a, to: b)
        pump(from: b, to: a)
    }

    private func pump(from source: RigConnection, to sink: RigConnection) {
        source.readSome { [self] data in
            guard let data else {
                sink.shutdownWrite()
                finishedDirections += 1
                if finishedDirections == 2 || sink.isClosed { closeBoth() }
                return
            }
            sink.send(data) { [self] error in
                if error != nil { closeBoth() } else { pump(from: source, to: sink) }
            }
        }
    }

    private func closeBoth() {
        a.close()
        b.close()
    }
}
