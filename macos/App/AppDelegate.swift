import AppKit
import GitCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchProbe: LaunchProbe?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("-JitBenchmarkLaunch") {
            launchProbe = LaunchProbe()
        }
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

/// Benchmark mode (`-JitBenchmarkLaunch`): measures process start → first key window, prints
/// `first_window_ms=<value>` to stdout, then quits. Also emits an os_signpost interval ("Launch",
/// subsystem `jit.performance`) for Instruments. Inactive in normal launches.
@MainActor
final class LaunchProbe {
    private static let signposter = OSSignposter(subsystem: "jit.performance", category: .pointsOfInterest)
    private let interval: OSSignpostIntervalState
    private var observer: (any NSObjectProtocol)?

    init() {
        interval = Self.signposter.beginInterval("Launch")
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        // Let the window commit its first frame before stopping the clock.
        DispatchQueue.main.async { [self] in
            Self.signposter.endInterval("Launch", interval)
            let milliseconds = Self.millisecondsSinceProcessStart()
            print(String(format: "first_window_ms=%.1f", milliseconds))
            fflush(stdout)
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
