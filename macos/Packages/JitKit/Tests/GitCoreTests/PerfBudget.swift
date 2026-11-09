import Foundation

/// Timing assertions in unit tests: the stated budgets are for release builds (implementation.md §4);
/// unoptimized debug builds get 15× headroom so they still catch order-of-magnitude regressions.
/// Release numbers: `swift test -c release -Xswiftc -enable-testing --filter <test>` and JitBench.
enum PerfBudget {
    /// Whether load-sensitive wall-clock budgets are asserted. The full suite runs ~700 tests in parallel, and
    /// the 100k lane-layout budget failed there even with 15× headroom (Phase 5/6 carry-over), so
    /// `scripts/build/test-core.sh` sets `JIT_FULL_SUITE=1` to skip those assertions; filtered runs enforce them,
    /// and release budgets are enforced by `JitBench micro` + the regression gate (ADR-0041).
    /// `JIT_ENFORCE_TIMING=1` forces them on.
    static var enforcesTiming: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["JIT_ENFORCE_TIMING"] == "1" { return true }
        return environment["JIT_FULL_SUITE"] == nil
    }

    static func limit(_ release: Duration) -> Duration {
        #if DEBUG
            release * 15
        #else
            release
        #endif
    }
}
