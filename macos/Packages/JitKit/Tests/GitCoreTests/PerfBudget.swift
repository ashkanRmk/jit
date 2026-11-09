/// Timing assertions in unit tests: the stated budgets are for release builds (implementation.md §4);
/// unoptimized debug builds get 15× headroom so they still catch order-of-magnitude regressions.
/// Release numbers: `swift test -c release -Xswiftc -enable-testing --filter <test>` and JitBench.
enum PerfBudget {
    static func limit(_ release: Duration) -> Duration {
        #if DEBUG
            release * 15
        #else
            release
        #endif
    }
}
