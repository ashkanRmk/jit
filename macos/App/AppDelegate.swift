import AppKit
import GitCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
            // `-JitAppearance light|dark` forces the app appearance for screenshots.
            switch UserDefaults.standard.string(forKey: "JitAppearance") {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No Git child may outlive Jit.
        ProcessRunner.terminateAllRunning()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Benchmark mode (`-JitBenchmarkLaunch`, optional env `JIT_BENCHMARK_OUTPUT=<file>`): measures process start (kernel
/// start time) → first window key, prints `first_window_ms=<value> trigger=<key|content>` to stdout
/// (and the file), then quits. Also emits an os_signpost interval ("Launch",
/// subsystem `jit.performance`) for Instruments. Inactive in normal launches.
@MainActor
final class LaunchProbe {
    private static let signposter = OSSignposter(subsystem: "jit.performance", category: .pointsOfInterest)
    private let interval: OSSignpostIntervalState
    private var observers: [any NSObjectProtocol] = []

    init() {
        interval = Self.signposter.beginInterval("Launch")
        Self.current = self
        // Ends when the first window becomes key, or — when launched in the background, where it never
        // becomes key — when the root view first appears (`firstContentAppeared`).
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.finish(trigger: "key") } })
    }

    /// The active probe, if launched with `-JitBenchmarkLaunch`.
    static var current: LaunchProbe?

    /// Called from `JitApp.init()`, before any scene or app-delegate callback, so the root view can
    /// never appear before the probe exists.
    static func startIfRequested() {
        guard current == nil, ProcessInfo.processInfo.arguments.contains("-JitBenchmarkLaunch") else { return }
        _ = LaunchProbe()
    }

    static func firstContentAppeared() {
        // `-JitBenchmarkTrigger key` (used by launch.sh) waits for the key window only.
        guard UserDefaults.standard.string(forKey: "JitBenchmarkTrigger") != "key" else { return }
        current?.finish(trigger: "content")
    }

    private var isFinished = false

    /// `trigger`: "key" (first window became key — the launch.sh method, via LaunchServices) or
    /// "content" (root view appeared; used when the app is launched in the background and never
    /// becomes active). Only "key" measurements are comparable baselines.
    private func finish(trigger: String) {
        guard !isFinished else { return }
        isFinished = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        // Let the window commit its first frame before stopping the clock.
        DispatchQueue.main.async { [self] in
            Self.signposter.endInterval("Launch", interval)
            let milliseconds = Self.millisecondsSinceProcessStart()
            let line = String(format: "first_window_ms=%.1f trigger=%@\n", milliseconds, trigger)
            print(line, terminator: "")
            fflush(stdout)
            // A path-valued launch argument would be taken by AppKit as a file to open, so the output
            // file comes from the environment (`open --env JIT_BENCHMARK_OUTPUT=…`).
            if let path = ProcessInfo.processInfo.environment["JIT_BENCHMARK_OUTPUT"] {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }

    /// Wall-clock time since the kernel created this process (`kinfo_proc.kp_proc.p_starttime`).
    static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let startMs = Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
        let nowMs = Double(now.tv_sec) * 1000 + Double(now.tv_usec) / 1000
        return nowMs - startMs
    }
}
