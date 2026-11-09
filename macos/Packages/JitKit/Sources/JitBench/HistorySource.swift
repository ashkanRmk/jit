import Darwin
import Foundation
import GitCore

/// Measures GitCore's `HistoryLoader` on one repository: first 300 rows, all rows, the idle reader's CPU
/// and footprint. (Spike S1 compared two other sources too; numbers in ADR-0010.)
enum HistorySourceSpike {
    struct Row: Encodable {
        let repo: String
        let commitGraph: Bool
        let strategy: String
        let first300Milliseconds: Double
        let fullMilliseconds: Double
        let readerIdleCPUMilliseconds: Double?
        let readerFootprintMB: Double?
        let rows: Int
    }

    static func cpuAndFootprint(_ pid: pid_t) -> (cpuNanoseconds: UInt64, footprint: UInt64)? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        guard ok == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return (cpu, info.ri_phys_footprint)
    }

    static func run(path: String, label: String, engine: GitEngine) async throws -> [Row] {
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: path))
        let refs = try await handle.refs()
        let hasGraph =
            FileManager.default.fileExists(atPath: handle.info.commonDirectory + "/objects/info/commit-graph")
            || FileManager.default.fileExists(atPath: handle.info.commonDirectory + "/objects/info/commit-graphs")
        var rows: [Row] = []
        let clock = ContinuousClock()

        // 1. Long-lived reader with backpressure (HistoryLoader).
        do {
            let start = clock.now
            let loader = HistoryLoader(repository: handle, query: HistoryQuery(), refs: refs)
            _ = try await loader.ensureLoaded(300)
            let first = clock.now - start
            var idleCPU: Double?
            var footprint: Double?
            // Git keeps writing until the pipe buffer is full; measure after that settles.
            try await Task.sleep(for: .seconds(1))
            if let pid = await loader.readerProcess, let before = cpuAndFootprint(pid) {
                try await Task.sleep(for: .seconds(2))
                if let after = cpuAndFootprint(pid) {
                    idleCPU = Double(after.cpuNanoseconds - before.cpuNanoseconds) / 1e6
                    footprint = Double(after.footprint) / 1_048_576
                }
            }
            let fullStart = clock.now
            var snapshot = try await loader.ensureLoaded(300)
            while !snapshot.complete { snapshot = try await loader.ensureLoaded(snapshot.count + 2000) }
            let full = first + (clock.now - fullStart)
            rows.append(
                Row(
                    repo: label, commitGraph: hasGraph, strategy: "long-lived log", first300Milliseconds: ms(first),
                    fullMilliseconds: ms(full), readerIdleCPUMilliseconds: idleCPU, readerFootprintMB: footprint,
                    rows: snapshot.count))
        }

        return rows
    }

    static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
