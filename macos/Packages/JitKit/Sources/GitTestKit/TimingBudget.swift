import Foundation

/// Wall-clock latency assertions (live refresh, cancellation). Local runs keep the stated limit; a shared
/// CI runner sets `JIT_TEST_TIMING_SCALE` (see `.github/workflows/ci.yml`) because parallel suites on a
/// loaded VM add scheduling delay that is not the code's. The scale is explicit, never inferred.
public enum TimingBudget {
    public static var scale: Int {
        let raw = ProcessInfo.processInfo.environment["JIT_TEST_TIMING_SCALE"].flatMap { Int($0) } ?? 1
        return max(1, raw)
    }

    public static func latency(_ limit: Duration) -> Duration { limit * scale }
}
