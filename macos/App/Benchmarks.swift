import AppKit
import Features
import Foundation
import Services

/// Environment-gated measurement modes used by `scripts/benchmarks/` (inactive in normal launches).
@MainActor
enum Benchmarks {
    /// Prints a result line to stdout and, when `JIT_BENCHMARK_OUTPUT` is set, appends it to that file
    /// (a path-valued launch argument would be taken by AppKit as a file to open).
    static func report(_ line: String) {
        print(line, terminator: "")
        fflush(stdout)
        guard let path = ProcessInfo.processInfo.environment["JIT_BENCHMARK_OUTPUT"] else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// `JIT_BENCHMARK_TAB_SWITCH=1`: with restored tabs, measures select → content laid out and
    /// displayed (the committed frame) for every tab, first while tabs are unloaded, then loaded.
    static func tabSwitch(model: AppModel, controller: MainWindowController) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard model.tabs.count > 1, let window = controller.window else {
            report("tab_switch error=need-2-or-more-restored-tabs\n")
            NSApp.terminate(nil)
            return
        }
        var unloaded: [Double] = []
        var loaded: [Double] = []
        for round in 0..<6 {
            for tab in model.tabs {
                let start = ContinuousClock.now
                model.select(tab.id)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let elapsed = ContinuousClock.now - start
                let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
                if round == 0 { unloaded.append(ms) } else { loaded.append(ms) }
                // Let the session load and the frame settle before the next switch.
                try? await Task.sleep(for: .milliseconds(round == 0 ? 600 : 120))
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func p90(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.9))]
        }
        report(
            String(
                format:
                    "tab_switch_first_ms median=%.2f max=%.2f n=%d\ntab_switch_loaded_ms median=%.2f p90=%.2f n=%d\n",
                median(unloaded), unloaded.max() ?? 0, unloaded.count, median(loaded), p90(loaded), loaded.count))
        NSApp.terminate(nil)
    }

    /// `JIT_STRESS_OPEN_CLOSE=<repo>`: opens and closes a repository tab 50 times and reports the
    /// physical footprint before, after 10 cycles, and after 50 cycles.
    static func openCloseStress(model: AppModel, path: String) async {
        try? await Task.sleep(for: .seconds(1))
        let url = URL(fileURLWithPath: path)
        var samples: [(Int, Double)] = [(0, footprintMB())]
        for cycle in 1...50 {
            model.open(url)
            await model.settleOpen()
            guard let tab = model.activeTab, tab.isRepository else {
                report("stress error=open-failed cycle=\(cycle)\n")
                NSApp.terminate(nil)
                return
            }
            for _ in 0..<100 where tab.session?.status == nil && tab.session?.error == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(50))
            model.closeTab(tab.id)
            try? await Task.sleep(for: .milliseconds(50))
            if cycle == 10 || cycle == 25 || cycle == 50 { samples.append((cycle, footprintMB())) }
        }
        try? await Task.sleep(for: .seconds(2))
        samples.append((-1, footprintMB()))
        report(
            samples.map { $0.0 < 0 ? String(format: "settled=%.1f", $0.1) : String(format: "cycle%d=%.1f", $0.0, $0.1) }
                .joined(separator: " ") + " (MB phys_footprint)\n")
        NSApp.terminate(nil)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
