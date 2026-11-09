import Foundation

/// Seeded random commit graphs for property tests (no external property-testing dependency).
public enum RandomTopology {
    /// A random topology with `commits` commits: random branching from any existing commit, merges of 2–4
    /// parents, occasional orphan roots and tags. Same seed → same topology.
    public static func make(seed: UInt64, commits: Int) -> Topology {
        var rng = SyntheticHistory.Generator(state: seed)
        var t = Topology()
        var branches = ["main"]
        var labels: [String] = []
        var serial = 0
        while labels.count < commits {
            serial += 1
            let roll = rng.below(100)
            if labels.isEmpty || roll < 3 {
                let name = labels.isEmpty ? "main" : "orphan\(serial)"
                if !labels.isEmpty { t.orphan(name) } else { t.checkout("main") }
                if !branches.contains(name) { branches.append(name) }
                let label = "c\(serial)"
                t.commit(label)
                labels.append(label)
            } else if roll < 20 {
                let name = "b\(serial)"
                t.branch(name, from: labels[rng.below(labels.count)])
                branches.append(name)
            } else if roll < 32, branches.count > 1 {
                let others = branches.filter { $0 != t.current }
                let count = min(others.count, 1 + (rng.below(10) == 0 ? rng.below(3) : 0))
                var picked: [String] = []
                for _ in 0..<count {
                    let candidate = others[rng.below(others.count)]
                    if !picked.contains(candidate) { picked.append(candidate) }
                }
                let label = "m\(serial)"
                t.merge(picked, label: label)
                labels.append(label)
            } else {
                if rng.below(4) == 0 { t.checkout(branches[rng.below(branches.count)]) }
                let label = "c\(serial)"
                t.commit(label)
                labels.append(label)
            }
            if rng.below(40) == 0, let target = labels.last { t.tag("t\(serial)", at: target) }
        }
        t.checkout("main")
        return t
    }
}
