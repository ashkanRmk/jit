import Darwin
import Dispatch
import Foundation

extension ProcessRunner {
    /// Launches a long-lived child whose stdout is read on demand (ADR-0005, ADR-0010).
    ///
    /// The stdout read source runs only while a `read()` is waiting. Between reads it is suspended: the
    /// pipe fills, the child blocks in `write(2)` and neither process uses CPU — backpressure without a
    /// parked thread. `spec.timeout` and `spec.stdoutLimit` are ignored (the consumer decides how much
    /// to read). Releasing the stream, `terminate()`, or cancelling a waiting `read()` kills the
    /// child's process group.
    public func stream(_ spec: ProcessSpec) -> ProcessStream {
        ProcessStream(core: StreamCore(spec: spec, grace: terminationGrace, liveGroups: liveGroups))
    }
}

/// Owner handle of a streamed child. Not shareable between concurrent readers: one `read()` at a time.
public final class ProcessStream: Sendable {
    fileprivate let core: StreamCore

    fileprivate init(core: StreamCore) {
        self.core = core
    }

    deinit { core.terminate(because: .cancelled) }

    /// The process id (= process group id), once launched; `0` before the first `read()`.
    public var processIdentifier: pid_t { core.currentPID }

    /// The next chunk of stdout (at most `maxBytes`), or `nil` at end of output after the child exited with
    /// an accepted status. Throws the mapped exit failure, `.cancelled` if the task is cancelled (which
    /// kills the child), or a launch error on the first call.
    public func read(maxBytes: Int = 256 * 1024) async throws(GitCoreError) -> [UInt8]? {
        if Task.isCancelled {
            core.terminate(because: .cancelled)
            throw .cancelled
        }
        let core = self.core
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                core.request(maxBytes: maxBytes, continuation)
            }
        } onCancel: {
            core.terminate(because: .cancelled)
        }
        return try result.get()
    }

    /// Kills the child's process group. Pending and later reads throw `.cancelled`.
    public func terminate() { core.terminate(because: .cancelled) }
}

/// All mutable state is confined to `queue`. Keeps itself alive through its Dispatch sources until the
/// child is reaped and both pipes are closed.
private final class StreamCore: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Result<[UInt8]?, GitCoreError>, Never>

    private let spec: ProcessSpec
    private let grace: Duration
    private let liveGroups: LiveProcessGroups
    private let queue = DispatchQueue(label: "jit.process.stream", qos: .userInitiated)

    private var launched = false
    private var pid: pid_t = 0
    private let pidBox = PIDBox()
    private var stdoutFD: Int32 = -1
    private var stdoutSource: (any DispatchSourceRead)?
    private var stdoutSuspended = false
    private var stdoutEOF = false
    private var stderrSource: (any DispatchSourceRead)?
    private var stderr: [UInt8] = []
    private var exitSource: (any DispatchSourceProcess)?
    private var waitStatus: Int32?
    private var timers: [any DispatchSourceTimer] = []
    private var failure: GitCoreError?
    private var killScheduled = false
    private var finished = false
    private var pending: (continuation: Continuation, maxBytes: Int)?
    private var scratch: UnsafeMutableRawBufferPointer?

    init(spec: ProcessSpec, grace: Duration, liveGroups: LiveProcessGroups) {
        self.spec = spec
        self.grace = grace
        self.liveGroups = liveGroups
    }

    deinit { scratch?.deallocate() }

    var currentPID: pid_t { pidBox.value }

    func request(maxBytes: Int, _ continuation: Continuation) {
        queue.async { [self] in
            guard pending == nil else {
                continuation.resume(returning: .failure(.internalError(summary: "Concurrent reads of one Git stream.")))
                return
            }
            if let failure { return continuation.resume(returning: .failure(failure)) }
            if !launched {
                launched = true
                guard launch() else { return continuation.resume(returning: .failure(failure ?? .cancelled)) }
            }
            pending = (continuation, max(1, maxBytes))
            if stdoutEOF {
                finishIfDone()
            } else if stdoutSuspended {
                stdoutSuspended = false
                stdoutSource?.resume()
            }
        }
    }

    func terminate(because reason: GitCoreError) {
        queue.async { [self] in
            if failure == nil { failure = reason }
            guard launched, pid > 0, !finished else {
                deliver(.failure(failure ?? reason))
                return
            }
            deliver(.failure(failure ?? reason))
            signalGroup(SIGTERM)
            // A suspended source never sees EOF; read on so the pipe drains and closes.
            if stdoutSuspended {
                stdoutSuspended = false
                stdoutSource?.resume()
            }
            guard !killScheduled else { return }
            killScheduled = true
            schedule(after: grace) { [self] in
                guard !finished else { return }
                signalGroup(SIGKILL)
                reap(afterExitEvent: true)
            }
        }
    }

    // MARK: Launch

    private func launch() -> Bool {
        switch SpawnedChild.spawn(spec) {
        case .failure(let error):
            failure = error
            finished = true
            return false
        case .success(let child):
            pid = child.pid
            pidBox.value = child.pid
            liveGroups.insert(child.pid)
            stdoutFD = child.stdout
            scratch = .allocate(byteCount: 256 * 1024, alignment: 16)

            let out = DispatchSource.makeReadSource(fileDescriptor: child.stdout, queue: queue)
            out.setEventHandler { [self] in readStdout() }
            out.setCancelHandler { close(child.stdout) }
            out.activate()
            out.suspend()  // runs only while a read() waits
            stdoutSuspended = true
            stdoutSource = out

            let err = DispatchSource.makeReadSource(fileDescriptor: child.stderr, queue: queue)
            err.setEventHandler { [self] in drainStderr(child.stderr) }
            err.setCancelHandler { close(child.stderr) }
            err.activate()
            stderrSource = err

            let exit = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [self] in reap(afterExitEvent: true) }
            exit.setRegistrationHandler { [self] in reap() }
            exitSource = exit
            exit.activate()
            return true
        }
    }

    // MARK: Pipes

    private func readStdout() {
        guard let scratch else { return }
        let wanted = min(pending?.maxBytes ?? scratch.count, scratch.count)
        let count = Darwin.read(stdoutFD, scratch.baseAddress, wanted)
        if count > 0 {
            if failure != nil { return }  // draining after termination: discard
            deliver(.success(Array(UnsafeRawBufferPointer(rebasing: scratch[0..<count]))))
            return
        }
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        // EOF or read error: stdout is done.
        stdoutEOF = true
        if stdoutSuspended {
            stdoutSuspended = false
            stdoutSource?.resume()  // a suspended source must be resumed before cancel releases it
        }
        stdoutSource?.cancel()
        stdoutSource = nil
        if stderrSource == nil, waitStatus == nil { reap() }
        finishIfDone()
    }

    private func drainStderr(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                stderr.append(contentsOf: buffer[0..<count])
                if stderr.count > 2 * ProcessRunner.stderrLimit {
                    stderr.removeFirst(stderr.count - ProcessRunner.stderrLimit)
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return }
            stderrSource?.cancel()
            stderrSource = nil
            if stdoutSource == nil, waitStatus == nil { reap() }
            finishIfDone()
            return
        }
    }

    /// Hands a result to the waiting reader and stops reading stdout until the next request.
    private func deliver(_ result: Result<[UInt8]?, GitCoreError>) {
        guard let pending else { return }
        self.pending = nil
        if !stdoutSuspended, let stdoutSource, !stdoutEOF, failure == nil {
            stdoutSource.suspend()
            stdoutSuspended = true
        }
        pending.continuation.resume(returning: result)
    }

    // MARK: Exit

    private func reap(afterExitEvent: Bool = false) {
        guard waitStatus == nil, pid > 0 else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            waitStatus = status
        } else if result == -1 && errno == EINTR {
            return reap(afterExitEvent: afterExitEvent)
        } else if result == -1 {
            waitStatus = -1
            if failure == nil { failure = .internalError(summary: "Lost track of a Git process.") }
        } else {
            if afterExitEvent { schedule(after: .milliseconds(1)) { [self] in reap(afterExitEvent: true) } }
            return
        }
        exitSource?.cancel()
        exitSource = nil
        if (stdoutSource != nil || stderrSource != nil) && processGroupHasMembers(pid) {
            // Something else in the group still holds the pipes: after the grace period, kill the group and
            // stop reading. (Without other members, unread data stays in the pipe until the reader asks.)
            schedule(after: grace) { [self] in
                guard !finished else { return }
                signalGroup(SIGKILL)
                if stdoutSuspended {
                    stdoutSuspended = false
                    stdoutSource?.resume()
                }
                stdoutSource?.cancel()
                stdoutSource = nil
                stdoutEOF = true
                stderrSource?.cancel()
                stderrSource = nil
                finishIfDone()
            }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard let waitStatus, stdoutSource == nil, stderrSource == nil else { return }
        if !finished {
            finished = true
            liveGroups.remove(pid)
            for timer in timers { timer.cancel() }
            timers.removeAll()
            exitSource?.cancel()
            exitSource = nil
            if failure == nil {
                let signal = waitStatus & 0x7f
                let exitCode: Int32 = signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
                if !spec.acceptedExitCodes.contains(exitCode) {
                    failure = ChildProcessMath.exitFailure(waitStatus: waitStatus, stderr: stderr).error
                }
            }
        }
        if pending != nil { deliver(failure.map { .failure($0) } ?? .success(nil)) }
    }

    private func signalGroup(_ signal: Int32) {
        guard pid > 0 else { return }
        if waitStatus == nil || processGroupHasMembers(pid) { killpg(pid, signal) }
    }

    private func schedule(after delay: Duration, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let (seconds, attoseconds) = delay.components
        let cappedSeconds = Int(min(max(seconds, 0), 86_400 * 365))
        let nanoseconds = cappedSeconds * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), leeway: .milliseconds(10))
        timer.setEventHandler(handler: handler)
        timers.append(timer)
        timer.activate()
    }
}

/// The child's pid, readable from any thread.
private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: pid_t = 0
    var value: pid_t {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
