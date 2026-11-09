import Foundation

/// One edge piece inside one row (design §4.2). Rows are drawn independently: every segment is fully
/// described by its row. 6 bytes (lanes are `UInt16` so very wide "All branches" graphs never overflow).
public struct EdgeSegment: Sendable, Hashable {
    public enum Half: UInt8, Sendable {
        /// Row top → row centre (an incoming edge, straight or curving into the node lane).
        case top
        /// Row centre → row bottom (an outgoing edge to a parent lane).
        case bottom
        /// Row top → row bottom, straight (a lane passing by).
        case full
    }

    public var fromLane: UInt16
    public var toLane: UInt16
    public var color: UInt8
    public var half: Half

    public init(fromLane: UInt16, toLane: UInt16, color: UInt8, half: Half) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.color = color
        self.half = half
    }
}

/// Per-row node flags.
public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let merge = NodeFlags(rawValue: 1 << 0)
    public static let root = NodeFlags(rawValue: 1 << 1)
    /// No child lane leads into this commit (a branch tip in the loaded scope).
    public static let tip = NodeFlags(rawValue: 1 << 2)
    public static let head = NodeFlags(rawValue: 1 << 3)
}

/// An interned author (name + email). Few per repository; kept as `String`s.
public struct CommitAuthor: Sendable, Hashable {
    public let name: String
    public let email: String
}

/// 4,096 rows of history in columns (ADR-0022). Immutable once built: one object per chunk, never per
/// commit; safe to read from any thread without locks.
public final class CommitChunk: Sendable {
    public static let capacity = 4096

    public let base: Int
    let oids: ContiguousArray<ObjectID>
    /// `parentEnds[i]` = end offset of row i's parents in `parents` (start = previous end or 0).
    let parentEnds: ContiguousArray<UInt32>
    let parents: ContiguousArray<ObjectID>
    let authors: ContiguousArray<UInt32>
    let times: ContiguousArray<Int64>
    let subjectEnds: ContiguousArray<UInt32>
    let subjects: ContiguousArray<UInt8>
    let nodeLanes: ContiguousArray<UInt16>
    let nodeColors: ContiguousArray<UInt8>
    let nodeFlags: ContiguousArray<UInt8>
    /// Lanes in use by the row (max lane index touched + 1): the graph column width needed.
    let widths: ContiguousArray<UInt16>
    let segmentEnds: ContiguousArray<UInt32>
    let segments: ContiguousArray<EdgeSegment>
    /// Local row indices sorted by object id (binary search for `row(for:)`; 2 bytes per commit instead
    /// of a hash map entry).
    let sortedByID: ContiguousArray<UInt16>

    init(base: Int, builder: ChunkBuilder) {
        self.base = base
        oids = builder.oids
        parentEnds = builder.parentEnds
        parents = builder.parents
        authors = builder.authors
        times = builder.times
        subjectEnds = builder.subjectEnds
        subjects = builder.subjects
        nodeLanes = builder.nodeLanes
        nodeColors = builder.nodeColors
        nodeFlags = builder.nodeFlags
        widths = builder.widths
        segmentEnds = builder.segmentEnds
        segments = builder.segments
        var order = ContiguousArray<UInt16>((0..<builder.oids.count).map { UInt16($0) })
        let ids = builder.oids
        order.sort { ids[Int($0)] < ids[Int($1)] }
        sortedByID = order
    }

    public var count: Int { oids.count }

    func localIndex(of id: ObjectID) -> Int? {
        var low = 0
        var high = sortedByID.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = oids[Int(sortedByID[mid])]
            if candidate == id { return Int(sortedByID[mid]) }
            if candidate < id { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    /// Bytes held by the columns' storage (capacity × stride), for memory accounting.
    var storageBytes: Int {
        oids.capacity * MemoryLayout<ObjectID>.stride + parentEnds.capacity * 4
            + parents.capacity * MemoryLayout<ObjectID>.stride + authors.capacity * 4 + times.capacity * 8
            + subjectEnds.capacity * 4 + subjects.capacity + nodeLanes.capacity * 2 + nodeColors.capacity
            + nodeFlags.capacity + widths.capacity * 2 + segmentEnds.capacity * 4
            + segments.capacity * MemoryLayout<EdgeSegment>.stride + sortedByID.capacity * 2
    }
}

/// The mutable tail chunk while history is being read. Owned by one `HistoryLoader`.
struct ChunkBuilder {
    var oids = ContiguousArray<ObjectID>()
    var parentEnds = ContiguousArray<UInt32>()
    var parents = ContiguousArray<ObjectID>()
    var authors = ContiguousArray<UInt32>()
    var times = ContiguousArray<Int64>()
    var subjectEnds = ContiguousArray<UInt32>()
    var subjects = ContiguousArray<UInt8>()
    var nodeLanes = ContiguousArray<UInt16>()
    var nodeColors = ContiguousArray<UInt8>()
    var nodeFlags = ContiguousArray<UInt8>()
    var widths = ContiguousArray<UInt16>()
    var segmentEnds = ContiguousArray<UInt32>()
    var segments = ContiguousArray<EdgeSegment>()

    init() {
        let n = CommitChunk.capacity
        oids.reserveCapacity(n)
        parentEnds.reserveCapacity(n)
        authors.reserveCapacity(n)
        times.reserveCapacity(n)
        subjectEnds.reserveCapacity(n)
        nodeLanes.reserveCapacity(n)
        nodeColors.reserveCapacity(n)
        nodeFlags.reserveCapacity(n)
        widths.reserveCapacity(n)
        segmentEnds.reserveCapacity(n)
    }

    var count: Int { oids.count }
    var isFull: Bool { oids.count >= CommitChunk.capacity }

    /// Shrinks every column to its size before sealing (sealed chunks never grow).
    mutating func compact() {
        func shrink<T>(_ array: inout ContiguousArray<T>) {
            if array.capacity > array.count + 16 { array = ContiguousArray(array) }
        }
        shrink(&parents)
        shrink(&subjects)
        shrink(&segments)
    }
}

/// A read-only view of loaded history (design §4.2): the sealed chunks plus a frozen copy of the tail.
/// Passing it around copies only the chunk-reference array.
public struct HistorySnapshot: Sendable {
    public let chunks: [CommitChunk]
    public let count: Int
    /// The reader reached the end of history (or the scope's end).
    public let complete: Bool
    public let authors: [CommitAuthor]
    public let format: ObjectFormat
    /// The refs this history was read against.
    public let refs: RefSnapshot
    /// The history ends at a shallow boundary (`.git/shallow` exists).
    public let isShallow: Bool
    /// Lane HEAD's commit sits in, once loaded (the WIP row draws on it).
    public let headRow: Int?

    public init(
        chunks: [CommitChunk], count: Int, complete: Bool, authors: [CommitAuthor], format: ObjectFormat,
        refs: RefSnapshot, isShallow: Bool, headRow: Int?
    ) {
        self.chunks = chunks
        self.count = count
        self.complete = complete
        self.authors = authors
        self.format = format
        self.refs = refs
        self.isShallow = isShallow
        self.headRow = headRow
    }

    public static func empty(refs: RefSnapshot = .empty) -> HistorySnapshot {
        HistorySnapshot(
            chunks: [], count: 0, complete: false, authors: [], format: refs.format, refs: refs, isShallow: false,
            headRow: nil)
    }

    @inline(__always) public func row(_ index: Int) -> CommitRow {
        precondition(index >= 0 && index < count, "row \(index) out of 0..<\(count)")
        return CommitRow(chunk: chunks[index / CommitChunk.capacity], local: index % CommitChunk.capacity)
    }

    /// Row of a loaded commit (binary search per chunk; no global hash map).
    public func row(for id: ObjectID) -> Int? {
        for chunk in chunks {
            if let local = chunk.localIndex(of: id) { return chunk.base + local }
        }
        return nil
    }

    /// The lane of HEAD's commit (for the WIP row).
    public func headLane() -> UInt16? { headRow.map { row($0).nodeLane } }

    public func author(of row: CommitRow) -> CommitAuthor { authors[Int(row.authorIndex)] }

    /// Bytes held by all chunk columns (memory accounting, tests and benchmarks).
    public var storageBytes: Int { chunks.reduce(0) { $0 + $1.storageBytes } }
}

/// A non-owning view of one row: chunk reference + local index. No allocation.
public struct CommitRow {
    let chunk: CommitChunk
    let local: Int

    public var index: Int { chunk.base + local }
    public var oid: ObjectID { chunk.oids[local] }
    public var time: Int64 { chunk.times[local] }
    public var authorIndex: UInt32 { chunk.authors[local] }
    public var nodeLane: UInt16 { chunk.nodeLanes[local] }
    public var nodeColor: UInt8 { chunk.nodeColors[local] }
    public var flags: NodeFlags { NodeFlags(rawValue: chunk.nodeFlags[local]) }
    public var width: UInt16 { chunk.widths[local] }
    public var isMerge: Bool { flags.contains(.merge) }

    private var parentRange: Range<Int> {
        let end = Int(chunk.parentEnds[local])
        let start = local == 0 ? 0 : Int(chunk.parentEnds[local - 1])
        return start..<end
    }

    public var parentCount: Int { parentRange.count }
    public var parents: ArraySlice<ObjectID> { chunk.parents[parentRange] }

    public var segments: ArraySlice<EdgeSegment> {
        let end = Int(chunk.segmentEnds[local])
        let start = local == 0 ? 0 : Int(chunk.segmentEnds[local - 1])
        return chunk.segments[start..<end]
    }

    public func subjectBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let end = Int(chunk.subjectEnds[local])
        let start = local == 0 ? 0 : Int(chunk.subjectEnds[local - 1])
        return try chunk.subjects.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[start..<end])) }
    }

    /// Materializes the subject (visible rows only).
    public var subject: String { subjectBytes { String(decoding: $0, as: UTF8.self) } }
}

/// Appends parsed commits and their lane rows into chunks (owned by one loader; not `Sendable`).
struct CommitStoreBuilder {
    private(set) var sealed: [CommitChunk] = []
    private var tail = ChunkBuilder()
    private(set) var authors: [CommitAuthor] = []
    /// Stable 64-bit hash of (name, email) bytes → author index. No allocation for a known author.
    private var authorLookup: [UInt64: UInt32] = [:]
    private(set) var count = 0

    mutating func internAuthor(name: UnsafeRawBufferPointer, email: UnsafeRawBufferPointer) -> UInt32 {
        var hash = StableHash()
        hash.combine(name)
        hash.combine(0)
        hash.combine(email)
        if let index = authorLookup[hash.value], Self.matches(authors[Int(index)], name, email) { return index }
        let author = CommitAuthor(
            name: String(decoding: name, as: UTF8.self), email: String(decoding: email, as: UTF8.self))
        if authorLookup[hash.value] != nil {
            // 64-bit collision between different authors: astronomically rare; resolve by a scan.
            if let existing = authors.firstIndex(of: author) { return UInt32(existing) }
        }
        let index = UInt32(authors.count)
        authors.append(author)
        if authorLookup[hash.value] == nil { authorLookup[hash.value] = index }
        return index
    }

    private static func matches(_ author: CommitAuthor, _ name: UnsafeRawBufferPointer, _ email: UnsafeRawBufferPointer)
        -> Bool
    {
        author.name.utf8.elementsEqual(name) && author.email.utf8.elementsEqual(email)
    }

    mutating func append(
        oid: ObjectID, parents: [ObjectID], author: UInt32, time: Int64, subject: UnsafeRawBufferPointer, lane: LaneRow
    ) {
        tail.oids.append(oid)
        tail.parents.append(contentsOf: parents)
        tail.parentEnds.append(UInt32(tail.parents.count))
        tail.authors.append(author)
        tail.times.append(time)
        tail.subjects.append(contentsOf: subject)
        tail.subjectEnds.append(UInt32(tail.subjects.count))
        tail.nodeLanes.append(lane.nodeLane)
        tail.nodeColors.append(lane.nodeColor)
        tail.nodeFlags.append(lane.flags.rawValue)
        tail.widths.append(lane.width)
        tail.segments.append(contentsOf: lane.segments)
        tail.segmentEnds.append(UInt32(tail.segments.count))
        count += 1
        if tail.isFull {
            tail.compact()
            sealed.append(CommitChunk(base: sealed.count * CommitChunk.capacity, builder: tail))
            tail = ChunkBuilder()
        }
    }

    /// Sealed chunks plus a frozen copy of the partial tail.
    func chunksForSnapshot() -> [CommitChunk] {
        guard tail.count > 0 else { return sealed }
        return sealed + [CommitChunk(base: sealed.count * CommitChunk.capacity, builder: tail)]
    }
}
