import Darwin
import Foundation
import GitCore
import GitTestKit

// Dev-only micro-benchmarks for GitCore. Usage: JitBench [spawn-latency|discovery|all] [--iterations N] [--out DIR]
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
var iterations = 200
var outDirectory = "scripts/benchmarks/out"
var selection = "all"
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--iterations": iterations = Int(arguments.removeFirst()) ?? iterations
    case "--out": outDirectory = arguments.removeFirst()
    case "-h", "--help":
        print("JitBench [spawn-latency|discovery|all] [--iterations N] [--out DIR]")
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
