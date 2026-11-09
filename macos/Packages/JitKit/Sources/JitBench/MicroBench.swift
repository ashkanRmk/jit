import Darwin
import Foundation
@_spi(Benchmarks) import GitCore
import GitTestKit

/// `JitBench micro [--iterations N] [--out file.json]` (P6.2): release-built GitCore micro-benchmarks —
/// lane layout (10k / 100k commits), status parse (100k entries), diff parse (50k-line file) and patch build.
/// Fixtures come from `$JIT_BENCH_DIR` (gen-repos.sh) when present, otherwise they are built in a temporary
/// directory. Reports median / p90 over N runs after 3 warm-ups, plus the malloc bytes a result keeps alive.
enum MicroBench {
    struct Metric: Encodable {
        let median: Double
        let p90: Double
        let min: Double
        let unit: String
        let runs: Int
        let retainedKiB: Int?
    }

    static func retainedBytes<T>(_ body: () throws -> T) rethrows -> (T, Int) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let before = Int(stats.size_in_use)
        let value = try body()
        malloc_zone_statistics(nil, &stats)
        return (value, Int(stats.size_in_use) - before)
    }

    static func time(_ iterations: Int, _ body: () throws -> Void) rethrows -> [Double] {
        for _ in 0..<3 { try body() }
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = clock.now
            try body()
            samples.append(milliseconds(clock.now - start))
        }
        return samples.sorted()
    }

    static func metric(_ samples: [Double], retained: Int? = nil) -> Metric {
        Metric(
            median: percentile(samples, 0.5), p90: percentile(samples, 0.9), min: samples.first ?? 0, unit: "ms",
            runs: samples.count, retainedKiB: retained.map { $0 / 1024 })
    }

    static func fixture(_ repo: BenchRepo, temporary: String) throws -> String {
        if let dir = ProcessInfo.processInfo.environment["JIT_BENCH_DIR"] {
            let path = "\(dir)/\(repo.rawValue)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let path = "\(temporary)/\(repo.rawValue)"
        if !FileManager.default.fileExists(atPath: path) { try repo.build(at: path) }
        return path
    }

    static func run(iterations: Int, out: String?) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jit-micro-\(getpid())").path
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let engine = GitEngine()
        var results: [String: Metric] = [:]

        // Lane layout: parse + layout + store of the full `git log` output (Git's time excluded).
        for (name, repo) in [("lane-layout-10k", BenchRepo.branchy10k), ("lane-layout-100k", BenchRepo.huge100k)] {
            let path = try fixture(repo, temporary: temporary)
            let handle = try await engine.openRepository(at: URL(fileURLWithPath: path))
            let (output, refs) = try await CoreBenchmarks.historyOutput(handle, engine: engine)
            // The parsed store is what stays alive in the app: report its size as the retained bytes.
            let (rows, storeBytes) = try CoreBenchmarks.parseAndLayout(output, refs: refs)
            let retained = storeBytes
            let samples = try time(max(5, iterations / 4)) { _ = try CoreBenchmarks.parseAndLayout(output, refs: refs) }
            results[name] = metric(samples, retained: retained)
            print(
                String(
                    format: "%@: median %.2f ms, p90 %.2f ms — %d rows, store %.1f MB", name,
                    percentile(samples, 0.5), percentile(samples, 0.9), rows, Double(storeBytes) / 1_048_576))
        }

        // Status parse: 100k porcelain v2 entries in Git's record shapes.
        let oid = String(repeating: "a1b2c3d4e5", count: 4)
        var sample: [UInt8] = Array("# branch.oid \(oid)\0# branch.head main\0# branch.ab +1 -2\0".utf8)
        for index in 0..<100_000 {
            let path = "Sources/Module\(index % 97)/Subsystem\(index % 13)/File\(index).swift"
            switch index % 10 {
            case 0: sample += Array("2 R. N... 100644 100644 100644 \(oid) \(oid) R100 \(path)\0old/\(path)\0".utf8)
            case 1: sample += Array("u UU N... 100644 100644 100644 100644 \(oid) \(oid) \(oid) \(path)\0".utf8)
            case 2, 3: sample += Array("? \(path)\0".utf8)
            default: sample += Array("1 .M N... 100644 100644 100644 \(oid) \(oid) \(path)\0".utf8)
            }
        }
        let (_, statusRetained) = try retainedBytes { try StatusParser.parse(sample) }
        let statusSamples = try time(iterations) { _ = try StatusParser.parse(sample) }
        results["status-parse-100k"] = metric(statusSamples, retained: statusRetained)
        print(
            String(
                format: "status-parse-100k: median %.2f ms, p90 %.2f ms", percentile(statusSamples, 0.5),
                percentile(statusSamples, 0.9)))

        // Diff parse: the large-diff fixture's 50k-line file (200 hunks).
        let largePath = try fixture(.largeDiff, temporary: temporary)
        let large = try await engine.openRepository(at: URL(fileURLWithPath: largePath))
        let document = try await large.openDiff(.unstaged(path: "large-table.swift"))
        let patchBytes = document.storage.bytes
        let (_, diffRetained) = try retainedBytes { try PatchParser.parse(patchBytes) }
        let diffSamples = try time(iterations) { _ = try PatchParser.parse(patchBytes) }
        results["diff-parse-50k"] = metric(diffSamples, retained: diffRetained)
        print(
            String(
                format: "diff-parse-50k: median %.2f ms, p90 %.2f ms (%d KiB patch)", percentile(diffSamples, 0.5),
                percentile(diffSamples, 0.9), patchBytes.count / 1024))

        // Patch build: stage one changed line of that file against its index blob.
        let changed = CoreBenchmarks.changedLines(document)
        let selection: Set<Int> = [changed[changed.count / 2]]
        let indexBytes = try await engine.run(
            GitCommand(["show", ":large-table.swift"], in: largePath, stdoutLimit: 1 << 28)
        ).stdout
        let patchSamples = try time(iterations) {
            _ = try PatchBuilder.build(document, selection: selection, action: .stage, target: indexBytes)
        }
        results["patch-build-50k"] = metric(patchSamples)
        print(
            String(
                format: "patch-build-50k: median %.2f ms, p90 %.2f ms", percentile(patchSamples, 0.5),
                percentile(patchSamples, 0.9)))

        let payload: [String: Any] = [
            "scenarios": [
                "micro": results.mapValues { metric in
                    ["median": metric.median, "p90": metric.p90, "unit": metric.unit, "runs": metric.runs]
                        .merging(metric.retainedKiB.map { ["retained_kib": $0] } ?? [:]) { a, _ in a }
                }
            ]
        ]
        if let out {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out))
            print("micro: wrote \(out)")
        }
    }
}
