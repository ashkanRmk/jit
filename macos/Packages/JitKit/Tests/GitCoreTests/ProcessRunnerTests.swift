import Darwin
import Foundation
import Testing

@testable import GitCore

/// `/bin/sh -c` appears here only as a test fixture to build process trees; production code has no
/// API that accepts a shell string.
@Suite(.serialized) struct ProcessRunnerTests {
    let runner = ProcessRunner(terminationGrace: .milliseconds(300))

    func spec(
        _ executable: String, _ arguments: [String], cwd: String = "/",
        timeout: Duration? = nil, stdoutLimit: Int = 1 << 20, accepted: Set<Int32> = [0]
    ) -> ProcessSpec {
        ProcessSpec(
            executable: executable, arguments: arguments, workingDirectory: cwd,
            environment: ProcessEnvironment.make(executableDirectory: nil, kind: .read),
            timeout: timeout, stdoutLimit: stdoutLimit, acceptedExitCodes: accepted)
    }

    func temporaryFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("jit-\(UUID().uuidString)").path
    }

    /// Polls (test-only) until `pid` no longer exists.
    func waitUntilGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func readPID(_ path: String) async throws -> pid_t {
        for _ in 0..<50 {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GitCoreError.internalError(summary: "fixture never wrote its pid")
    }

    @Test func passesArgvWithoutShellInterpretation() async throws {
        let hostile = "a; rm -rf /tmp/jit-never $(id) `whoami` * | cat > x && echo pwned"
        let output = try await runner.run(spec("/usr/bin/printf", ["%s", hostile]))
        #expect(output.stdoutText == hostile)
    }

    @Test func feedsStdinBytesExactly() async throws {
        var processSpec = spec("/bin/cat", [])
        let input: [UInt8] = Array("a\0b\r\nc".utf8) + [0xFF, 0x00] + Array(repeating: 0x41, count: 300_000)
        processSpec.stdin = input
        #expect(try await runner.run(processSpec).stdout == input)
    }

    @Test func childIgnoringLargeStdinDoesNotRaiseSIGPIPE() async throws {
        var processSpec = spec("/usr/bin/true", [])
        processSpec.stdin = Array(repeating: 0x42, count: 4 * 1024 * 1024)
        #expect(try await runner.run(processSpec).exitCode == 0)
    }

    @Test func stdinDefaultsToDevNull() async throws {
        #expect(try await runner.run(spec("/bin/cat", [])).stdout.isEmpty)
    }

    @Test func sanitizesEnvironment() async throws {
        let parent = ["HOME": "/Users/x", "SECRET_TOKEN": "s3cret", "PATH": "/evil/bin", "GIT_DIR": "/elsewhere"]
        var processSpec = spec("/usr/bin/env", [])
        processSpec.environment = ProcessEnvironment.make(
            executableDirectory: "/opt/homebrew/bin", kind: .read,
            overrides: ["GIT_TERMINAL_PROMPT": "1"], parent: parent)
        let lines = Set(try await runner.run(processSpec).stdoutText.split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=/Users/x"))
        #expect(lines.contains("PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(lines.contains("GIT_TERMINAL_PROMPT=0"))  // overrides cannot re-enable prompts
        #expect(lines.contains("GIT_EDITOR=true"))
        #expect(lines.contains("GIT_SEQUENCE_EDITOR=true"))
        #expect(lines.contains("GIT_MERGE_AUTOEDIT=no"))
        #expect(lines.contains("GIT_ASKPASS=/usr/bin/false"))
        #expect(lines.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(lines.contains("LC_ALL=C"))
        #expect(!lines.contains { $0.hasPrefix("SECRET_TOKEN=") || $0.hasPrefix("GIT_DIR=") })
    }

    @Test func writeCommandsTakeOptionalLocks() {
        let environment = ProcessEnvironment.make(executableDirectory: nil, kind: .write, parent: [:])
        #expect(environment["GIT_OPTIONAL_LOCKS"] == nil)
    }

    @Test func capsStdoutAndStderr() async throws {
        await #expect(throws: GitCoreError.outputTooLarge(limitBytes: 1000)) {
            try await runner.run(spec("/bin/sh", ["-c", "head -c 100000 /dev/zero"], stdoutLimit: 1000))
        }
        let output = try await runner.run(spec("/bin/sh", ["-c", "head -c 300000 /dev/zero >&2; printf ok"]))
        #expect(output.stderr.count == ProcessRunner.stderrLimit)
        #expect(output.stdoutText == "ok")
    }

    @Test func timeoutKillsProcessGroup() async throws {
        let pidFile = temporaryFile()
        let started = ContinuousClock.now
        await #expect(throws: GitCoreError.timedOut(seconds: 1)) {
            try await runner.run(
                spec("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile)'; wait"], timeout: .milliseconds(400)))
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        let grandchild = try await readPID(pidFile)
        #expect(await waitUntilGone(grandchild), "grandchild \(grandchild) survived the timeout")
    }

    @Test func ignoredSigtermEscalatesToSigkill() async throws {
        let started = ContinuousClock.now
        await #expect(throws: GitCoreError.timedOut(seconds: 1)) {
            try await runner.run(
                spec("/bin/sh", ["-c", "trap '' TERM; sleep 30 & wait; wait"], timeout: .milliseconds(200)))
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func taskCancellationKillsProcessGroup() async throws {
        let pidFile = temporaryFile()
        let processSpec = spec("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile)'; wait"])
        let task = Task { try await runner.run(processSpec) }
        let grandchild = try await readPID(pidFile)
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
        #expect(await waitUntilGone(grandchild), "grandchild \(grandchild) survived cancellation")
    }

    @Test func cancelledBeforeSpawnThrowsCancelled() async throws {
        let marker = temporaryFile()
        let processSpec = spec("/usr/bin/touch", [marker])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await runner.run(processSpec)
        }
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker), "process was spawned despite cancellation")
    }

    @Test func nonzeroExitMapsToError() async throws {
        let failing = spec("/bin/sh", ["-c", "echo 'fatal: bad thing' >&2; exit 3"])
        await #expect(
            throws: GitCoreError.processFailed(exitCode: 3, summary: "Bad thing", detail: "fatal: bad thing")
        ) {
            try await runner.run(failing)
        }
        var tolerated = failing
        tolerated.acceptedExitCodes = [0, 3]
        #expect(try await runner.run(tolerated).exitCode == 3)
    }

    @Test func missingWorkingDirectoryMapsToError() async throws {
        let missing = "/nonexistent-\(UUID().uuidString)"
        await #expect(throws: GitCoreError.pathNotFound(path: missing)) {
            try await runner.run(spec("/usr/bin/true", [], cwd: missing))
        }
    }

    @Test func terminateAllRunningKillsLiveGroups() async throws {
        let pidFile = temporaryFile()
        let processSpec = spec("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile)'; wait"])
        // A private registry, so parallel suites' processes are untouched.
        let groups = LiveProcessGroups()
        let isolated = ProcessRunner(terminationGrace: .milliseconds(300), liveGroups: groups)
        let task = Task { try await isolated.run(processSpec) }
        let grandchild = try await readPID(pidFile)
        groups.killAll()
        await #expect(throws: GitCoreError.self) { try await task.value }
        #expect(await waitUntilGone(grandchild))
    }

    @Test func leftoverPipeHolderIsKilledAfterGrace() async throws {
        // The leader exits at once; a background child keeps stdout open. The runner must still finish
        // (after the grace period) and kill the leftover member of the group.
        let pidFile = temporaryFile()
        let started = ContinuousClock.now
        let output = try await runner.run(spec("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile)'; printf done"]))
        #expect(output.stdoutText == "done")
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(await waitUntilGone(try await readPID(pidFile)))
    }

    @Test func timeoutReportsWholeSecondsRoundedUp() {
        #expect(ChildProcessMath.roundedUp(.milliseconds(400)) == 1)
        #expect(ChildProcessMath.roundedUp(.seconds(15)) == 15)
        #expect(ChildProcessMath.roundedUp(.milliseconds(15_001)) == 16)
    }

    @Test func noThreadBlockedWhileWaiting() async throws {
        func threadCount() -> Int {
            var threads: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
            return Int(count)
        }
        let before = threadCount()
        let sleepSpec = spec("/bin/sleep", ["1"])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { _ = try await runner.run(sleepSpec) }
            }
            try await Task.sleep(for: .milliseconds(300))
            // 64 children are running. The cooperative pool must still be free...
            let probeStart = ContinuousClock.now
            let value = await Task.detached { 42 }.value
            let latency = ContinuousClock.now - probeStart
            // ...and waiting must not have parked a thread per child.
            let during = threadCount()
            print("threads before=\(before) during=\(during) probe latency=\(latency)")
            #expect(value == 42)
            #expect(latency < .milliseconds(100))
            // A blocking design would park one thread per child (+64). GCD may add a few workers.
            #expect(during - before < 32)
            try await group.waitForAll()
        }
    }
}
