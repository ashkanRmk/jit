import Foundation

/// Small seeded generator for property tests (no third-party dependency). Same seed → same sequence.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `JIT_PROPERTY_CASES` (default `ciDefault` when `CI` is set, else `localDefault`) and
    /// `JIT_PROPERTY_SEED` (default: derived from the clock, printed so a failure can be re-run).
    public static func propertyConfiguration(localDefault: Int, ciDefault: Int) -> (cases: Int, seed: UInt64) {
        let environment = ProcessInfo.processInfo.environment
        let cases =
            environment["JIT_PROPERTY_CASES"].flatMap(Int.init)
            ?? (environment["CI"] != nil ? ciDefault : localDefault)
        let seed =
            environment["JIT_PROPERTY_SEED"].flatMap { UInt64($0) }
            ?? UInt64(UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)))
        return (cases, seed)
    }
}
