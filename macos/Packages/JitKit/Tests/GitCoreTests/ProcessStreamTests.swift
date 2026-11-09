import Darwin
import Foundation
import Testing

@testable import GitCore

/// `/bin/sh -c` is a test fixture only (see `ProcessRunnerTests`).
@Suite(.serialized) struct ProcessStreamTests {
    let runner = ProcessRunner(terminationGrace: .milliseconds(300))

    func spec(_ executable: String, _ arguments: [String], accepted: Set<Int32> = [0]) -> ProcessSpec {
        ProcessSpec(
            executable: executable, arguments: arguments, workingDirectory: "/",
            environment: ProcessEnvironment.make(executableDirectory: nil, kind: .read), acceptedExitCodes: accepted)
    }

    func waitUntilGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// User + system CPU time of `pid` in nanoseconds (mach absolute units converted).
    func cpuNanoseconds(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        guard ok == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    @Test func readsAllOutputThenEnds() async throws {
        let stream = runner.stream(spec("/bin/sh", ["-c", "head -c 1000000 /dev/zero; printf end"]))
        var total = 0
        var last: [UInt8] = []
        while let chunk = try await stream.read() {
            total += chunk.count
            last = chunk
        }
        #expect(total == 1_000_003)
        #expect(last.suffix(3) == Array("end".utf8))
        #expect(try await stream.read() == nil)
    }

    @Test func respectsMaxBytes() async throws {
        let stream = runner.stream(spec("/bin/sh", ["-c", "head -c 10000 /dev/zero"]))
        let first = try #require(try await stream.read(maxBytes: 100))
        #expect(first.count <= 100)
        stream.terminate()
    }

    @Test func idleStreamBlocksChildWithoutCPU() async throws {
        let stream = runner.stream(spec("/usr/bin/yes", []))
        _ = try await stream.read()
        let pid = stream.processIdentifier
        try await Task.sleep(for: .milliseconds(100))  // let the pipe fill
        let before = cpuNanoseconds(pid)
        try await Task.sleep(for: .milliseconds(500))
        let after = cpuNanoseconds(pid)
        #expect(after - before < 5_000_000, "child used \(after - before) ns while nobody read")
        // Reading resumes the flow.
        #expect(try await stream.read() != nil)
        stream.terminate()
        #expect(await waitUntilGone(pid))
    }

    @Test func cancellingAReadKillsTheGroup() async throws {
        let stream = runner.stream(spec("/bin/sh", ["-c", "sleep 30 & wait"]))
        let task = Task { try await stream.read() }
        try await Task.sleep(for: .milliseconds(200))
        let pid = stream.processIdentifier
        #expect(pid > 0)
        task.cancel()
        await #expect(throws: GitCoreError.cancelled) { try await task.value }
        #expect(await waitUntilGone(pid))
        await #expect(throws: GitCoreError.cancelled) { try await stream.read() }
    }

    @Test func releasingTheStreamKillsTheChild() async throws {
        var stream: ProcessStream? = runner.stream(spec("/usr/bin/yes", []))
        _ = try await stream?.read()
        let pid = try #require(stream?.processIdentifier)
        stream = nil
        #expect(await waitUntilGone(pid))
    }

    @Test func exitFailureIsMapped() async throws {
        let stream = runner.stream(spec("/bin/sh", ["-c", "printf partial; echo 'fatal: bad revision' >&2; exit 128"]))
        #expect(try await stream.read() == Array("partial".utf8))
        await #expect(
            throws: GitCoreError.processFailed(exitCode: 128, summary: "Bad revision", detail: "fatal: bad revision")
        ) { try await stream.read() }
    }

    @Test func slowConsumerAfterExitGetsEverything() async throws {
        // The child writes into the pipe buffer and exits; a reader arriving later than the grace period
        // still receives all of it.
        let stream = runner.stream(spec("/bin/sh", ["-c", "head -c 30000 /dev/zero"]))
        _ = try await stream.read(maxBytes: 10)
        try await Task.sleep(for: .milliseconds(800))
        var total = 10
        while let chunk = try await stream.read() { total += chunk.count }
        #expect(total == 30000)
    }

    @Test func launchFailureSurfacesOnFirstRead() async throws {
        let stream = runner.stream(spec("/nonexistent/binary-\(UUID().uuidString)", []))
        await #expect(throws: GitCoreError.self) { try await stream.read() }
    }
}
