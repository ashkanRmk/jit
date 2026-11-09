import Foundation

/// The lane data of one row, produced by `LaneLayouter` (design §4.4).
struct LaneRow {
    var nodeLane: UInt16 = 0
    var nodeColor: UInt8 = 0
    var flags: NodeFlags = []
    var width: UInt16 = 0
    var segments: [EdgeSegment] = []
}

/// Incremental, deterministic, top-down lane assignment (ADR-0021).
///
/// Invariants:
/// - **Prefix stability:** row k depends only on rows 0…k, so loading more history never changes rows
///   already laid out (lanes never move sideways; freed lanes are only reused).
/// - **Determinism:** no randomness, no seeded hashing; colours come from `StableHash` of names.
/// - Lane cooldown: a freed lane is reusable only after one fully empty row.
/// - Colour slot 0 is reserved for HEAD's branch; other lanes use slots 1…7, skipping the colour of the
///   adjacent active lanes.
///
/// Cost: O(active lanes) per row, no allocation per row (buffers are reused).
struct LaneLayouter {
    static let paletteSize: UInt8 = 8

    enum SlotState: UInt8 {
        case free, active, reserved
    }

    private var expected: [ObjectID] = []
    private var colors: [UInt8] = []
    private var states: [SlotState] = []
    private var freedAt: [Int] = []
    private var row = 0
    private var matches: [Int] = []
    var output = LaneRow()

    /// Colour keys for branch tips: commit → stable hash of the most specific ref name pointing at it.
    private let tipKeys: [ObjectID: UInt64]
    private let headKey: UInt64?
    private let headCommit: ObjectID?

    /// - Parameters:
    ///   - refs: names for colour keys (local branch > remote branch > tag; remote names without the
    ///     remote, so `main` and `origin/main` share a colour).
    ///   - pinned: tips to keep in lanes 0, 1, … in this order (reserved until the tip's row arrives).
    init(refs: RefSnapshot, pinned: [ObjectID] = []) {
        var keys: [ObjectID: (rank: Int, key: UInt64)] = [:]
        for ref in refs.refs {
            guard let commit = ref.commit else { continue }
            let rank: Int
            let name: String
            switch ref.kind {
            case .local:
                rank = ref.isHead ? 0 : 1
                name = ref.shortName
            case .remote:
                rank = 2
                name = ref.remoteBranchName ?? ref.shortName
            case .tag:
                rank = 3
                name = ref.shortName
            case .other:
                continue
            }
            if let existing = keys[commit], existing.rank <= rank { continue }
            keys[commit] = (rank, StableHash.of(name))
        }
        tipKeys = keys.mapValues(\.key)
        headCommit = refs.head.commit
        switch refs.head {
        case .branch(let name, _): headKey = StableHash.of(name)
        case .detached(let commit):
            var hash = StableHash()
            hash.combine(commit)
            headKey = hash.value
        case .unborn: headKey = nil
        }
        for (index, tip) in pinned.enumerated() {
            expected.append(tip)
            _ = index
            colors.append(0)
            states.append(.reserved)
            freedAt.append(Int.min / 2)
        }
        output.segments.reserveCapacity(64)
    }

    /// Lays out the next row. `subject` is used only to name second-parent lanes of merges
    /// (`Merge branch 'x'`) so they get the branch's colour.
    mutating func layout(oid: ObjectID, parents: some Collection<ObjectID>, subject: UnsafeRawBufferPointer) {
        let r = row
        row += 1
        output.segments.removeAll(keepingCapacity: true)
        output.flags = []
        if parents.count > 1 { output.flags.insert(.merge) }
        if parents.isEmpty { output.flags.insert(.root) }
        if oid == headCommit { output.flags.insert(.head) }

        // 1. Slots expecting this commit.
        matches.removeAll(keepingCapacity: true)
        for index in states.indices where states[index] != .free && expected[index] == oid {
            matches.append(index)
        }
        // Incoming edges: lanes drawn above that lead into this commit (the leftmost becomes the node lane).
        let node: Int
        var nodeColor: UInt8
        var anyDrawn = false
        if let first = matches.first {
            node = first
            for index in matches where states[index] == .active {
                anyDrawn = true
                output.segments.append(
                    EdgeSegment(fromLane: UInt16(clamping: index), toLane: UInt16(clamping: node), color: colors[index], half: .top))
            }
            if states[node] == .reserved {
                nodeColor = colorFor(key: tipKey(oid), slot: node)
                states[node] = .active
            } else {
                nodeColor = colors[node]
            }
            for index in matches where index != node { free(index, row: r) }
        } else {
            node = allocate(from: 0, row: r)
            nodeColor = colorFor(key: tipKey(oid), slot: node)
            states[node] = .active
        }
        if !anyDrawn { output.flags.insert(.tip) }

        // 2. Lanes passing by.
        for index in states.indices where states[index] == .active && index != node && !matches.contains(index) {
            output.segments.append(
                EdgeSegment(fromLane: UInt16(clamping: index), toLane: UInt16(clamping: index), color: colors[index], half: .full))
        }

        // 3. Parents.
        var parentIterator = parents.makeIterator()
        if let first = parentIterator.next() {
            expected[node] = first
            colors[node] = nodeColor
            output.segments.append(
                EdgeSegment(fromLane: UInt16(clamping: node), toLane: UInt16(clamping: node), color: nodeColor, half: .bottom))
            var mergeOrdinal = 0
            while let parent = parentIterator.next() {
                mergeOrdinal += 1
                if let existing = states.indices.first(where: {
                    $0 != node && states[$0] == .active && expected[$0] == parent
                }) {
                    output.segments.append(
                        EdgeSegment(
                            fromLane: UInt16(clamping: node), toLane: UInt16(clamping: existing), color: colors[existing], half: .bottom))
                } else {
                    let slot = allocate(from: node + 1, row: r)
                    expected[slot] = parent
                    states[slot] = .active
                    let key = mergeKey(subject: subject, ordinal: mergeOrdinal, parent: parent)
                    colors[slot] = colorFor(key: key, slot: slot)
                    output.segments.append(
                        EdgeSegment(fromLane: UInt16(clamping: node), toLane: UInt16(clamping: slot), color: colors[slot], half: .bottom))
                }
            }
        } else {
            free(node, row: r)  // root: the lane ends here
        }

        output.nodeLane = UInt16(clamping: node)
        output.nodeColor = nodeColor
        var width = node + 1
        for segment in output.segments {
            width = max(width, Int(segment.fromLane) + 1, Int(segment.toLane) + 1)
        }
        output.width = UInt16(min(width, Int(UInt16.max)))
    }

    // MARK: - Slots

    private mutating func allocate(from start: Int, row r: Int) -> Int {
        var index = start
        while index < states.count {
            if states[index] == .free && freedAt[index] + 1 < r { return index }
            index += 1
        }
        expected.append(.zero)
        colors.append(0)
        states.append(.free)
        freedAt.append(Int.min / 2)
        return states.count - 1
    }

    private mutating func free(_ index: Int, row r: Int) {
        states[index] = .free
        freedAt[index] = r
    }

    // MARK: - Colours

    private func tipKey(_ oid: ObjectID) -> UInt64 {
        if let key = tipKeys[oid] { return key }
        var hash = StableHash()
        hash.combine(oid)
        return hash.value
    }

    /// `Merge branch 'name'` / `Merge remote-tracking branch 'origin/name'` / `Merge pull request #N from
    /// owner/name` → hash of the branch name (without a remote); otherwise the parent's id.
    private func mergeKey(subject: UnsafeRawBufferPointer, ordinal: Int, parent: ObjectID) -> UInt64 {
        if ordinal == 1, let name = Self.mergedBranchName(subject) {
            var hash = StableHash()
            hash.combine(name)
            return hash.value
        }
        if let key = tipKeys[parent] { return key }
        var hash = StableHash()
        hash.combine(parent)
        return hash.value
    }

    static func mergedBranchName(_ subject: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        func hasPrefix(_ prefix: StaticString) -> Bool {
            guard subject.count >= prefix.utf8CodeUnitCount else { return false }
            for index in 0..<prefix.utf8CodeUnitCount where subject[index] != prefix.utf8Start[index] {
                return false
            }
            return true
        }
        var start: Int
        var end: Int
        if hasPrefix("Merge branch '") {
            start = 14
        } else if hasPrefix("Merge remote-tracking branch '") {
            start = 30
        } else if hasPrefix("Merge pull request #") {
            // "Merge pull request #12 from owner/branch" → branch
            guard let from = Self.find(subject, " from ", after: 20) else { return nil }
            start = from + 6
            end = start
            while end < subject.count, subject[end] != 0x20 { end += 1 }
            guard let slash = (start..<end).first(where: { subject[$0] == 0x2F }) else { return nil }
            start = slash + 1
            return start < end ? UnsafeRawBufferPointer(rebasing: subject[start..<end]) : nil
        } else {
            return nil
        }
        end = start
        while end < subject.count, subject[end] != 0x27 { end += 1 }
        guard end < subject.count, end > start else { return nil }
        if hasPrefix("Merge remote-tracking branch '"),
            let slash = (start..<end).first(where: { subject[$0] == 0x2F })
        {
            start = slash + 1
        }
        return UnsafeRawBufferPointer(rebasing: subject[start..<end])
    }

    private static func find(_ haystack: UnsafeRawBufferPointer, _ needle: StaticString, after: Int) -> Int? {
        let count = needle.utf8CodeUnitCount
        guard haystack.count >= count else { return nil }
        var index = after
        while index + count <= haystack.count {
            var equal = true
            for offset in 0..<count where haystack[index + offset] != needle.utf8Start[offset] {
                equal = false
                break
            }
            if equal { return index }
            index += 1
        }
        return nil
    }

    /// HEAD's branch → slot 0. Otherwise `hash % 7 + 1`, then the next slot while it equals an adjacent
    /// active lane's colour.
    private func colorFor(key: UInt64, slot: Int) -> UInt8 {
        if let headKey, key == headKey { return 0 }
        var color = UInt8(key % UInt64(Self.paletteSize - 1)) + 1
        for _ in 0..<(Self.paletteSize - 1) {
            let left = slot > 0 && states[slot - 1] == .active && colors[slot - 1] == color
            let right = slot + 1 < states.count && states[slot + 1] == .active && colors[slot + 1] == color
            if !left && !right { break }
            color = color % (Self.paletteSize - 1) + 1
        }
        return color
    }
}
