import Foundation
import Testing

@testable import Features

/// P6.1: `-JitBenchmarkScenario` is inert unless passed; unknown names never run anything.
@Suite struct BenchmarkScenarioArgumentTests {
    @Test func absentArgumentIsInert() {
        #expect(BenchmarkScenario.request(from: ["/Applications/Jit.app/Contents/MacOS/Jit"]) == .none)
        #expect(BenchmarkScenario.request(from: ["Jit", "-JitOpen", "/tmp/repo"]) == .none)
    }

    @Test func knownScenariosParse() {
        for scenario in BenchmarkScenario.allCases {
            let request = BenchmarkScenario.request(from: ["Jit", "-JitBenchmarkScenario", scenario.rawValue])
            #expect(request == .scenario(scenario))
        }
    }

    @Test func unknownOrMissingNameIsReportedNotRun() {
        #expect(BenchmarkScenario.request(from: ["Jit", "-JitBenchmarkScenario", "rm-rf"]) == .unknown("rm-rf"))
        #expect(BenchmarkScenario.request(from: ["Jit", "-JitBenchmarkScenario"]) == .unknown(""))
    }

    @Test func repositoriesAreLocalAbsolutePathsOnly() {
        let urls = BenchmarkScenario.repositories([
            "JIT_BENCH_REPOS": "/tmp/a:relative/b:https://example.com/c.git:/tmp/d"
        ])
        #expect(urls.map(\.path) == ["/tmp/a", "/tmp/d"])
        #expect(BenchmarkScenario.repositories(["JIT_OPEN": "/tmp/x"]).map(\.path) == ["/tmp/x"])
        #expect(BenchmarkScenario.repositories([:]).isEmpty)
    }

    @Test func percentilesAreStable() {
        #expect(BenchmarkMath.percentile([], 0.5) == 0)
        #expect(BenchmarkMath.percentile([3, 1, 2], 0.5) == 2)
        #expect(BenchmarkMath.percentile(Array(1...10).map(Double.init), 0.9) == 9)
    }
}
