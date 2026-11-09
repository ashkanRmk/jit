import Darwin
import Foundation
import GitCore
import GitTestKit

// Dev-only micro-benchmarks for GitCore. Usage: JitBench [spawn-latency|discovery|status-parse|all] [--iterations N] [--out DIR]
// Writes one JSON file per benchmark (default: scripts/benchmarks/out/).

struct Result: Encodable {
    let benchmark: String
    let iterations: Int
    let p50Milliseconds: Double
    let p90Milliseconds: Double
    let minMilliseconds: Double
    let maxMilliseconds: Double
    let git: String
    let machine: String
    let osVersion: String
    let timestamp: String
}

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

func machineModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func measure(
    _ name: String, iterations: Int, git: GitExecutable, outDirectory: String,
    _ body: () async throws -> Void
) async throws {
    for _ in 0..<3 { try await body() }  // warm-up
    var samples: [Double] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
        let start = clock.now
        try await body()
        samples.append(milliseconds(clock.now - start))
    }
    samples.sort()
    let result = Result(
        benchmark: name, iterations: iterations,
        p50Milliseconds: percentile(samples, 0.5), p90Milliseconds: percentile(samples, 0.9),
        minMilliseconds: samples.first ?? 0, maxMilliseconds: samples.last ?? 0,
        git: "\(git.path) \(git.version.displayString)", machine: machineModel(),
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        timestamp: ISO8601DateFormatter().string(from: Date()))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    try FileManager.default.createDirectory(atPath: outDirectory, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: outDirectory).appendingPathComponent("\(name).json"))
    print(
        String(
            format: "%@: p50 %.2f ms, p90 %.2f ms (n=%d)", name, result.p50Milliseconds,
            result.p90Milliseconds, iterations))
}

var arguments = Array(CommandLine.arguments.dropFirst())

// `JitBench renderer-spike`: spike S1 for ADR-0011 (TextKit 2 vs CodeLinesView).
if arguments.first == "phase3" {
    try await Phase3Bench.run()
    exit(0)
}

if arguments.first == "renderer-spike" {
    try await RendererSpike.run()
    exit(0)
}

// `JitBench history-source <repo>...`: spike S1 (ADR-0010). Prints one line per strategy.
if arguments.first == "history-source" {
    let engine = GitEngine()
    var all: [HistorySourceSpike.Row] = []
    for path in arguments.dropFirst() {
        for row in try await HistorySourceSpike.run(
            path: path, label: (path as NSString).lastPathComponent, engine: engine)
        {
            all.append(row)
            print(
                String(
                    format: "%@ graph=%@ %@: first300 %.1f ms, full %.0f ms, rows %d, reader idle CPU %@, footprint %@",
                    row.repo, row.commitGraph ? "yes" : "no", row.strategy, row.first300Milliseconds,
                    row.fullMilliseconds, row.rows,
                    row.readerIdleCPUMilliseconds.map { String(format: "%.2f ms/2s", $0) } ?? "n/a",
                    row.readerFootprintMB.map { String(format: "%.1f MB", $0) } ?? "n/a"))
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(atPath: "scripts/benchmarks/out", withIntermediateDirectories: true)
    try encoder.encode(all).write(to: URL(fileURLWithPath: "scripts/benchmarks/out/history-source.json"))
    exit(0)
}

// `JitBench make-history <commits> <branches> <out>`: deterministic history fixture (fast-import).
if arguments.first == "make-history" {
    guard arguments.count == 4, let commits = Int(arguments[1]), let branches = Int(arguments[2]) else {
        print("usage: JitBench make-history <commits> <branches> <out-directory>")
        exit(2)
    }
    let out = arguments[3]
    if FileManager.default.fileExists(atPath: out) {
        print("error: \(out) already exists")
        exit(1)
    }
    let started = ContinuousClock.now
    let head = try SyntheticHistory(commits: commits, branches: branches).build(at: out)
    print(
        "make-history: \(commits) commits, \(branches) branches → \(out) HEAD \(head) in \(ContinuousClock.now - started)"
    )
    exit(0)
}
var iterations = 200
var outDirectory = "scripts/benchmarks/out"
var selection = "all"
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--iterations": iterations = Int(arguments.removeFirst()) ?? iterations
    case "--out": outDirectory = arguments.removeFirst()
    case "-h", "--help":
        print("JitBench [spawn-latency|discovery|status-parse|all] [--iterations N] [--out DIR]")
        print("JitBench make-history <commits> <branches> <out-directory>")
        exit(0)
    default: selection = argument
    }
}

let sandbox = try GitSandbox()
let repo = try await sandbox.makeRepository("bench")
try repo.write("README.md", "bench\n")
try await repo.commit("Initial")
let engine = GitEngine(configuration: sandbox.engineConfiguration())
let git = try await engine.gitInfo()

if selection == "all" || selection == "spawn-latency" {
    try await measure("spawn-latency", iterations: iterations, git: git, outDirectory: outDirectory) {
        _ = try await engine.run(GitCommand(["--version"], in: "/"))
    }
}
if selection == "all" || selection == "discovery" {
    let url = URL(fileURLWithPath: repo.path)
    try await measure("discovery", iterations: iterations, git: git, outDirectory: outDirectory) {
        _ = try await engine.discoverRepository(at: url)
    }
}

if selection == "all" || selection == "status-parse" {
    // A synthetic 100k-entry porcelain v2 `-z` sample in Git's exact record shapes (ordinary, rename,
    // unmerged, untracked) with realistic path lengths.
    let oid = String(repeating: "a1b2c3d4e5", count: 4)
    var sample: [UInt8] = Array(
        "# branch.oid \(oid)\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +1 -2\0".utf8)
    for index in 0..<100_000 {
        let path = "Sources/Module\(index % 97)/Subsystem\(index % 13)/File\(index).swift"
        switch index % 10 {
        case 0: sample += Array("2 R. N... 100644 100644 100644 \(oid) \(oid) R100 \(path)\0old/\(path)\0".utf8)
        case 1: sample += Array("u UU N... 100644 100644 100644 100644 \(oid) \(oid) \(oid) \(path)\0".utf8)
        case 2, 3: sample += Array("? \(path)\0".utf8)
        default: sample += Array("1 .M N... 100644 100644 100644 \(oid) \(oid) \(path)\0".utf8)
        }
    }
    var zoneStats = malloc_statistics_t()
    malloc_zone_statistics(nil, &zoneStats)
    let before = zoneStats.size_in_use
    let retained = try StatusParser.parse(sample)
    malloc_zone_statistics(nil, &zoneStats)
    let retainedBytes = Int(zoneStats.size_in_use) - Int(before)
    print(
        "status-parse: sample \(sample.count / 1024) KiB, \(retained.entries.count) entries, "
            + "snapshot overhead beyond the shared output buffer ≈ \(retainedBytes / 1024) KiB")
    try await measure("status-parse", iterations: max(10, iterations / 10), git: git, outDirectory: outDirectory) {
        _ = try StatusParser.parse(sample)
    }
}
