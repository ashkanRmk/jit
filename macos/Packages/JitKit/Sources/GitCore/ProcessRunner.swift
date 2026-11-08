import Darwin
import Dispatch
import Foundation
import Synchronization

/// Everything needed to launch one child process. There is deliberately no way to pass a shell
/// command string: `executable` is an absolute path and `arguments` become `argv[1...]` verbatim.
public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var timeout: Duration?
    public var stdoutLimit: Int
    public var acceptedExitCodes: Set<Int32>

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        timeout: Duration? = nil,
        stdoutLimit: Int = 16 * 1024 * 1024,
        acceptedExitCodes: Set<Int32> = [0]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.stdoutLimit = stdoutLimit
        self.acceptedExitCodes = acceptedExitCodes
    }
}

/// Captured result of a process that exited with an accepted status.
public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdout: [UInt8]
    public let stderr: [UInt8]

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Launches child processes with `posix_spawn` (ADR-0005).
///
/// - argv array, explicit working directory, stdin `/dev/null`.
/// - New session (`POSIX_SPAWN_SETSID`): the child leads its own process group and has no
///   controlling terminal, so nothing can prompt on a tty; the whole group is signalled on
///   cancellation/timeout (`SIGTERM`, then `SIGKILL` after `terminationGrace`).
/// - Pipes and exit are observed with Dispatch sources on a per-command serial queue. No thread
///   blocks waiting on a child, and the awaiting task holds no thread.
public struct ProcessRunner: Sendable {
    /// stderr keeps at most the last 64 KiB.
    public static let stderrLimit = 64 * 1024

    public var terminationGrace: Duration
    let liveGroups: LiveProcessGroups

    public init(terminationGrace: Duration = .seconds(2)) {
        self.init(terminationGrace: terminationGrace, liveGroups: .shared)
    }

    init(terminationGrace: Duration, liveGroups: LiveProcessGroups) {
        self.terminationGrace = terminationGrace
        self.liveGroups = liveGroups
    }

    /// Kills every process group started by any `ProcessRunner` that is still running. Called when the
    /// app terminates so no Git child outlives Jit.
    public static func terminateAllRunning() {
        LiveProcessGroups.shared.killAll()
    }

    @concurrent
    public func run(_ spec: ProcessSpec) async throws(GitCoreError) -> ProcessOutput {
        #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        if Task.isCancelled { throw .cancelled }
        let child = ChildProcess(spec: spec, grace: terminationGrace, liveGroups: liveGroups)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                child.start(continuation)
            }
        } onCancel: {
            child.cancel()
        }
        return try result.get()
    }
}

// MARK: - Child process state machine

/// All mutable state is confined to `queue`. The object keeps itself alive through its Dispatch
/// sources' handlers until it finishes, then cancels every source.
private final class ChildProcess: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Result<ProcessOutput, GitCoreError>, Never>

    private let spec: ProcessSpec
    private let grace: Duration
    private let queue = DispatchQueue(label: "jit.process", qos: .userInitiated)

    private var continuation: Continuation?
    private var pid: pid_t = 0
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []
    private var stdoutSource: (any DispatchSourceRead)?
    private var stderrSource: (any DispatchSourceRead)?
    private var exitSource: (any DispatchSourceProcess)?
    private var timers: [any DispatchSourceTimer] = []
    private var waitStatus: Int32?
    private var failure: GitCoreError?
    private var cancelRequested = false
    private var killScheduled = false
    private var finished = false
    private let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)

    private let liveGroups: LiveProcessGroups

    init(spec: ProcessSpec, grace: Duration, liveGroups: LiveProcessGroups) {
        self.spec = spec
        self.grace = grace
        self.liveGroups = liveGroups
    }

    deinit { scratch.deallocate() }

    func start(_ continuation: Continuation) {
        queue.async { [self] in
            self.continuation = continuation
            if cancelRequested {
                complete(.failure(.cancelled))
                return
            }
            launch()
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            if pid == 0 {
                cancelRequested = true
            } else {
                terminate(because: .cancelled)
            }
        }
    }

    // MARK: Launch

    private func launch() {
        #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return complete(.failure(.launchFailed(errno: errno))) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0])
            close(outPipe[1])
            return complete(.failure(.launchFailed(errno: code)))
        }
        for fd in [outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, spec.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags =
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = CStringArray([spec.executable] + spec.arguments)
        let envp = CStringArray(spec.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, spec.executable, &actions, &attributes, argv.pointers, envp.pointers)
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return complete(.failure(classifySpawnFailure(status)))
        }
        pid = childPID
        liveGroups.insert(childPID)

        stdoutSource = makeReader(fd: outPipe[0], isStdout: true)
        stderrSource = makeReader(fd: errPipe[0], isStdout: false)

        let exit = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in reap(afterExitEvent: true) }
        // The child may exit before kqueue registration completes; check again once it is armed.
        exit.setRegistrationHandler { [self] in reap() }
        exitSource = exit
        exit.activate()

        if let timeout = spec.timeout {
            schedule(after: timeout) { [self] in
                terminate(because: .timedOut(seconds: Int(timeout.components.seconds)))
            }
        }
    }

    private func classifySpawnFailure(_ code: Int32) -> GitCoreError {
        let executableUsable = access(spec.executable, X_OK) == 0
        switch code {
        case ENOENT where executableUsable, ENOTDIR where executableUsable:
            return .pathNotFound(path: spec.workingDirectory)
        case EACCES where executableUsable:
            return .permissionDenied(path: spec.workingDirectory)
        default:
            return .launchFailed(errno: code)
        }
    }

    // MARK: Pipes

    private func makeReader(fd: Int32, isStdout: Bool) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain(fd: fd, isStdout: isStdout) }
        source.setCancelHandler { close(fd) }
        source.activate()
        return source
    }

    private func drain(fd: Int32, isStdout: Bool) {
        while true {
            let count = read(fd, scratch.baseAddress, scratch.count)
            if count > 0 {
                append(UnsafeRawBufferPointer(rebasing: scratch[0..<count]), isStdout: isStdout)
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return }
            // EOF or a read error: this stream is done.
            closeStream(isStdout: isStdout)
            return
        }
    }

    private func append(_ bytes: UnsafeRawBufferPointer, isStdout: Bool) {
        if isStdout {
            guard failure == nil else { return }  // Discard after a failure; keep draining to EOF.
            if stdout.count + bytes.count > spec.stdoutLimit {
                terminate(because: .outputTooLarge(limitBytes: spec.stdoutLimit))
                return
            }
            stdout.append(contentsOf: bytes)
        } else {
            stderr.append(contentsOf: bytes)
            if stderr.count > 2 * ProcessRunner.stderrLimit {
                stderr.removeFirst(stderr.count - ProcessRunner.stderrLimit)
            }
        }
    }

    private func closeStream(isStdout: Bool) {
        if isStdout {
            stdoutSource?.cancel()
            stdoutSource = nil
        } else {
            stderrSource?.cancel()
            stderrSource = nil
        }
        finishIfDone()
    }

    // MARK: Exit

    /// - Parameter afterExitEvent: `NOTE_EXIT` was delivered. The kernel can deliver it a moment
    ///   before the child becomes reapable, and it fires only once, so a `WNOHANG` miss is retried on
    ///   a short one-shot timer instead of blocking a thread in `waitpid`.
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
            if afterExitEvent {
                schedule(after: .milliseconds(1)) { [self] in reap(afterExitEvent: true) }
            }
            return
        }
        exitSource?.cancel()
        exitSource = nil
        if stdoutSource != nil || stderrSource != nil {
            // Something else in the group still holds the pipes. Give it the grace period, then
            // kill the group and stop reading.
            schedule(after: grace) { [self] in
                killpg(pid, SIGKILL)
                stdoutSource?.cancel()
                stdoutSource = nil
                stderrSource?.cancel()
                stderrSource = nil
                finishIfDone()
            }
        }
        finishIfDone()
    }

    private func terminate(because reason: GitCoreError) {
        guard !finished, pid > 0 else { return }
        if failure == nil { failure = reason }
        killpg(pid, SIGTERM)
        guard !killScheduled else { return }
        killScheduled = true
        schedule(after: grace) { [self] in
            guard !finished else { return }
            killpg(pid, SIGKILL)
        }
    }

    private func schedule(after delay: Duration, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let (seconds, attoseconds) = delay.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), leeway: .milliseconds(10))
        timer.setEventHandler(handler: handler)
        timers.append(timer)
        timer.activate()
    }

    private func finishIfDone() {
        guard !finished, let waitStatus, stdoutSource == nil, stderrSource == nil else { return }
        if let failure { return complete(.failure(failure)) }
        if stderr.count > ProcessRunner.stderrLimit {
            stderr.removeFirst(stderr.count - ProcessRunner.stderrLimit)
        }
        let signal = waitStatus & 0x7f
        let exitCode: Int32 = signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
        let output = ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr)
        guard spec.acceptedExitCodes.contains(exitCode) else {
            let detail = Redaction.redact(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init)
            let summary =
                signal != 0
                ? "Git was stopped by signal \(signal)."
                : (firstLine.map { Self.humanize($0) } ?? "Git exited with status \(exitCode).")
            return complete(.failure(.processFailed(exitCode: exitCode, summary: summary, detail: detail)))
        }
        complete(.success(output))
    }

    private static func humanize(_ line: String) -> String {
        for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
            let message = line.dropFirst(prefix.count)
            return message.prefix(1).uppercased() + message.dropFirst()
        }
        return line
    }

    private func complete(_ result: Result<ProcessOutput, GitCoreError>) {
        guard !finished else { return }
        finished = true
        if pid > 0 { liveGroups.remove(pid) }
        for timer in timers { timer.cancel() }
        timers.removeAll()
        exitSource?.cancel()
        exitSource = nil
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Process groups of children that have not finished yet.
final class LiveProcessGroups: Sendable {
    static let shared = LiveProcessGroups()
    private let groups = Mutex<Set<pid_t>>([])

    func insert(_ group: pid_t) { _ = groups.withLock { $0.insert(group) } }
    func remove(_ group: pid_t) { _ = groups.withLock { $0.remove(group) } }

    func killAll() {
        for group in groups.withLock({ $0 }) { killpg(group, SIGKILL) }
    }
}

/// A NUL-terminated `char *[]` that owns its strings for the duration of a `posix_spawn` call.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointers[index] = strdup(string) }
        pointers[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
