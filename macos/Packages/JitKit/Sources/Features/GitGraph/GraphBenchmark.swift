import AppKit
import Foundation
import GitCore
import Services

/// `JIT_BENCHMARK_GRAPH=1` with `JIT_OPEN=<repo>` (all builds; release for numbers): measures the graph in
/// the real window — first rows drawn, page-append and scroll-step main-thread cost, per-row draw time and
/// the footprint once all history is loaded. Results are one line per metric (implementation.md §4).
@MainActor
public enum GraphBenchmark {
    /// Row draw durations (ms) while a benchmark runs; nil otherwise (no cost in normal use).
    static var drawSamples: [Double]?
    static var appendSamples: [Double]?
    static var openedAt: ContinuousClock.Instant?
    static var firstRowsAt: ContinuousClock.Instant?
    static var historyStartedAt: ContinuousClock.Instant?

    static func noteHistoryStart() {
        guard isEnabled, historyStartedAt == nil else { return }
        historyStartedAt = .now
    }

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["JIT_BENCHMARK_GRAPH"] != nil
            || BenchmarkScenario.current == .scenario(.graphScroll)
    }

    public static func prepare() {
        guard isEnabled else { return }
        openedAt = .now
        drawSamples = []
        appendSamples = []
    }

    static func noteFirstRows() {
        guard isEnabled, firstRowsAt == nil else { return }
        firstRowsAt = .now
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    /// Runs after the window shows; `report` writes a line.
    public static func run(controller: MainWindowController, report: @escaping (String) -> Void) async {
        guard isEnabled else { return }
        var graph: GraphViewController?
        for _ in 0..<600 {  // up to 30 s for the repository to open (benchmark harness only)
            graph = controller.activeGraph
            if let graph, graph.loadedCount > 0, firstRowsAt != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let graph, let window = controller.window, let opened = openedAt, let first = firstRowsAt else {
            report("graph_benchmark error=no-history\n")
            return
        }
        let fromHistory = historyStartedAt.map { ms(first - $0) } ?? -1
        report(
            String(
                format: "graph_first_rows_ms=%.1f from_history_start_ms=%.1f rows=%d\n", ms(first - opened),
                fromHistory,
                graph.loadedCount))
        // Settle, then scroll one screen per step for 400 steps (pages append on the way), measuring each
        // step's main-thread layout + display (the committed frame).
        try? await Task.sleep(for: .seconds(1))
        drawSamples = []
        let table = graph.tableView
        var steps: [Double] = []
        for _ in 0..<400 {
            let visible = table.visibleRect
            let start = ContinuousClock.now
            table.scroll(NSPoint(x: 0, y: visible.minY + visible.height))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            steps.append(ms(ContinuousClock.now - start))
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
        }
        let draws = drawSamples ?? []
        let appends = appendSamples ?? []
        report(
            String(
                format: "graph_scroll_step_ms median=%.2f p95=%.2f max=%.2f n=%d over_16ms=%d\n",
                percentile(steps, 0.5), percentile(steps, 0.95), steps.max() ?? 0, steps.count,
                steps.filter { $0 > 16.7 }.count))
        report(
            String(
                format: "graph_row_draw_ms median=%.3f p95=%.3f max=%.3f n=%d\n", percentile(draws, 0.5),
                percentile(draws, 0.95), draws.max() ?? 0, draws.count))
        report(
            String(
                format: "graph_page_append_ms median=%.2f p95=%.2f max=%.2f n=%d\n", percentile(appends, 0.5),
                percentile(appends, 0.95), appends.max() ?? 0, appends.count))
        // Search over everything loaded.
        if let history = graph.history {
            await history.loadRows(atLeast: .max)
            let snapshot = history.snapshot
            let start = ContinuousClock.now
            let matches = snapshot.search(HistorySearchQuery("lane colours"))
            report(
                String(
                    format: "graph_search_loaded_ms=%.2f rows=%d matches=%d\n", ms(ContinuousClock.now - start),
                    snapshot.count, matches.count))
            try? await Task.sleep(for: .seconds(2))
            report(
                String(
                    format: "graph_footprint_all_loaded_mb=%.1f rows=%d store_mb=%.1f\n", footprintMB(), snapshot.count,
                    Double(snapshot.storageBytes) / 1_048_576))
        }
        drawSamples = nil
        appendSamples = nil
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
