import GitCore

extension RefLabel {
    var isBranch: Bool {
        switch kind {
        case .tag, .detachedHead: false
        default: true
        }
    }
}

/// Incremental branch ownership, built off the main actor. Each row stores a four-byte label index;
/// only the graph frontier holds object IDs. Parent lanes break ties at shared ancestors in the same
/// order as the graph, so a merged topic never takes over its destination's first-parent history.
struct GraphLineLabels: Sendable {
    private struct Pending: Sendable {
        let label: Int32
        let lane: UInt16
    }

    private var rows: [Int32] = []
    private var labels: [RefLabel] = []
    private var pending: [ObjectID: Pending] = [:]
    private var refLabels: [ObjectID: Int32] = [:]
    private var mergedLabels: [String: Int32] = [:]

    func label(at index: Int) -> RefLabel? {
        guard rows.indices.contains(index), rows[index] >= 0 else { return nil }
        return labels[Int(rows[index])]
    }

    mutating func append(snapshot: HistorySnapshot, labelsByCommit: [ObjectID: [RefLabel]]) -> Bool {
        guard rows.count <= snapshot.count else { return false }
        if rows.isEmpty {
            for (oid, refs) in labelsByCommit {
                guard let label = refs.first(where: \.isBranch) ?? refs.first else { continue }
                refLabels[oid] = add(label)
            }
        }
        for index in rows.count..<snapshot.count {
            if index.isMultiple(of: 256), Task.isCancelled { return false }
            let row = snapshot.row(index)
            let inherited = pending.removeValue(forKey: row.oid)
            let own = refLabels[row.oid]
            // A tag must not interrupt the branch passing through it.
            let branch = own.flatMap { labels[Int($0)].isBranch ? $0 : nil }
            let label = branch ?? inherited?.label ?? own ?? -1
            rows.append(label)

            var merged: Int32?
            if let name = row.mergedBranchName {
                if let known = mergedLabels[name] {
                    merged = known
                } else {
                    // Historical names are display hints, not live refs that can be checked out.
                    let hint = add(RefLabel(kind: .historical, text: DisplayText.sanitize(name), fullName: nil))
                    mergedLabels[name] = hint
                    merged = hint
                }
            }
            let edges = row.segments.filter { $0.half == .bottom }
            for (ordinal, parent) in row.parents.enumerated() {
                let candidate = ordinal == 1 ? merged ?? label : label
                guard candidate >= 0 else { continue }
                let lane = ordinal < edges.count ? edges[ordinal].toLane : row.nodeLane
                if let existing = pending[parent], existing.lane <= lane { continue }
                pending[parent] = Pending(label: candidate, lane: lane)
            }
        }
        return !Task.isCancelled
    }

    private mutating func add(_ label: RefLabel) -> Int32 {
        let index = Int32(labels.count)
        labels.append(label)
        return index
    }
}
