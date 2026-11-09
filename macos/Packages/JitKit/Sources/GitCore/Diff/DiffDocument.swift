import Foundation

public enum DiffLayout: Sendable, Hashable { case unified, split, fullFile }

/// Stable for the lifetime of a `DiffDocument` (and of documents expanded from it).
public struct HunkID: Sendable, Hashable { public let value: UInt32 }
public struct LineID: Sendable, Hashable, Comparable {
    public let hunk: UInt32
    public let index: UInt32
    public static func < (a: LineID, b: LineID) -> Bool { (a.hunk, a.index) < (b.hunk, b.index) }
}

/// One row of the unified or full-file layout: a view into the document, no copy.
public enum DiffRow: Sendable, Hashable {
    case file(Int)
    case hunk(Int)
    case line(Int)
    /// Collapsed unchanged lines (`count` lines starting at line `first`); `gap` indexes `gaps`.
    case gap(Int)
}

/// One row of the side-by-side layout. `left` shows old lines (context, deleted), `right` new ones
/// (context, added); a missing side is `nil`.
public enum SplitRow: Sendable, Hashable {
    case file(Int)
    case hunk(Int)
    case lines(left: Int?, right: Int?)
    case gap(Int)
}

public struct ContextGap: Sendable, Hashable {
    /// First hidden line and how many.
    public let first: Int
    public let count: Int
    public var lines: Range<Int> { first..<(first + count) }
}

public struct RowMatch: Sendable, Hashable {
    public let row: Int
    /// UTF-16 range in the row's display text.
    public let range: Range<Int>
}

/// An immutable, `Sendable` diff (design §4.2): the shared `PatchStorage` plus layout tables. Changing
/// what is shown (expanding context) makes a new document over the same storage.
public final class DiffDocument: Sendable {
    public let storage: PatchStorage
    public let target: DiffTarget?
    public let options: DiffOptions
    /// What the file looked like when this diff was read (single-path working-tree targets).
    public let token: SnapshotToken?
    /// Unchanged runs hidden in the unified/split layouts.
    public let gaps: [ContextGap]
    /// Packed rows (`PackedRow`): 4 bytes per unified/full row, 8 per split row.
    let unified: [UInt32]
    let split: [UInt64]
    let full: [UInt32]

    public convenience init(
        storage: PatchStorage, target: DiffTarget? = nil, options: DiffOptions = DiffOptions(),
        token: SnapshotToken? = nil
    ) {
        let gaps = Self.initialGaps(storage, context: options.contextLines)
        self.init(storage: storage, target: target, options: options, token: token, gaps: gaps)
    }

    init(storage: PatchStorage, target: DiffTarget?, options: DiffOptions, token: SnapshotToken?, gaps: [ContextGap]) {
        self.storage = storage
        self.target = target
        self.options = options
        self.token = token
        self.gaps = gaps
        let showsFileRows = storage.files.count > 1
        (unified, split) = Self.layouts(storage, gaps: gaps, fileRows: showsFileRows)
        var full: [UInt32] = []
        full.reserveCapacity(storage.lines.count + storage.files.count)
        for (index, file) in storage.files.enumerated() {
            if showsFileRows { full.append(PackedRow.pack(.file(index))) }
            for hunk in storage.hunks[file.hunks] {
                for line in hunk.lines { full.append(PackedRow.pack(.line(line))) }
            }
        }
        self.full = full
    }

    // MARK: Rows

    public var files: [DiffFile] { storage.files }
    public var hunks: [HunkRecord] { storage.hunks }

    public func rowCount(_ layout: DiffLayout) -> Int {
        switch layout {
        case .unified: unified.count
        case .split: split.count
        case .fullFile: full.count
        }
    }

    /// A unified or full-file row (use `splitRow` for the split layout).
    public func row(_ layout: DiffLayout, _ index: Int) -> DiffRow {
        PackedRow.unpack(layout == .fullFile ? full[index] : unified[index])
    }

    public func splitRow(_ index: Int) -> SplitRow { PackedRow.unpackSplit(split[index]) }

    // MARK: Lines

    public func kind(ofLine line: Int) -> DiffLineKind { storage.lines[line].kind }
    public func oldNumber(ofLine line: Int) -> Int? { Self.number(storage.lines[line].oldNumber) }
    public func newNumber(ofLine line: Int) -> Int? { Self.number(storage.lines[line].newNumber) }
    public func isCRLF(line: Int) -> Bool { storage.lines[line].isCRLF }
    /// The file has no final newline after this line.
    public func noNewline(line: Int) -> Bool { storage.lines[line].noNewline }

    /// Text without prefix and line ending, as bytes (no copy).
    public func bytes(ofLine line: Int) -> ArraySlice<UInt8> {
        let record = storage.lines[line]
        return storage.bytes[Int(record.start)..<(Int(record.start) + record.length)]
    }

    /// Display text, lossy UTF-8. Call for visible rows only.
    public func text(ofLine line: Int) -> String { String(decoding: bytes(ofLine: line), as: UTF8.self) }

    /// The line exactly as it is in the file: text plus `\n`, `\r\n`, a lone `\r`, or nothing at the end.
    public func fileBytes(ofLine line: Int) -> [UInt8] {
        let record = storage.lines[line]
        var out = Array(bytes(ofLine: line))
        if record.isCRLF { out.append(UInt8(ascii: "\r")) }
        if !record.noNewline { out.append(UInt8(ascii: "\n")) }
        return out
    }

    public func lineID(_ line: Int) -> LineID {
        let hunk = hunkIndex(containing: line)
        return LineID(hunk: UInt32(hunk), index: UInt32(line - storage.hunks[hunk].firstLine))
    }

    public func line(_ id: LineID) -> Int { storage.hunks[Int(id.hunk)].firstLine + Int(id.index) }

    func hunkIndex(containing line: Int) -> Int {
        var low = 0
        var high = storage.hunks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if storage.hunks[mid].firstLine <= line { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func number(_ value: UInt32) -> Int? { value == 0 ? nil : Int(value) }

    // MARK: Context expansion

    /// Shows up to `lines` more unchanged lines at each edge of gap `gap` (all of it when it is that
    /// small). A new document over the same storage; this one is unchanged.
    public func expandingContext(gap: Int, lines: Int) -> DiffDocument {
        guard gaps.indices.contains(gap), lines > 0 else { return self }
        var next = gaps
        let hidden = gaps[gap]
        if hidden.count <= 2 * lines {
            next.remove(at: gap)
        } else {
            next[gap] = ContextGap(first: hidden.first + lines, count: hidden.count - 2 * lines)
        }
        return DiffDocument(storage: storage, target: target, options: options, token: token, gaps: next)
    }

    /// Shows every line of every hunk.
    public func expandingAll() -> DiffDocument {
        DiffDocument(storage: storage, target: target, options: options, token: token, gaps: [])
    }

    /// Unchanged runs longer than twice the context, inside hunks: keep `context` lines next to changes.
    static func initialGaps(_ storage: PatchStorage, context: Int) -> [ContextGap] {
        var gaps: [ContextGap] = []
        for hunk in storage.hunks {
            var runStart: Int?
            var sawChange = false
            func close(_ end: Int, beforeChange: Bool) {
                guard let start = runStart else { return }
                let keepTop = sawChange ? context : 0
                let keepBottom = beforeChange ? context : 0
                let hidden = (end - start) - keepTop - keepBottom
                if hidden > 0 { gaps.append(ContextGap(first: start + keepTop, count: hidden)) }
                runStart = nil
            }
            for line in hunk.lines {
                if storage.lines[line].kind == .context {
                    if runStart == nil { runStart = line }
                } else {
                    close(line, beforeChange: true)
                    sawChange = true
                }
            }
            if sawChange { close(hunk.lines.upperBound, beforeChange: false) } else { runStart = nil }
        }
        return gaps
    }

    // MARK: Layout tables

    static func layouts(_ storage: PatchStorage, gaps: [ContextGap], fileRows: Bool) -> ([UInt32], [UInt64]) {
        var unified: [UInt32] = []
        var split: [UInt64] = []
        unified.reserveCapacity(storage.lines.count + storage.hunks.count)
        var gapIndex = 0
        for (fileIndex, file) in storage.files.enumerated() {
            if fileRows {
                unified.append(PackedRow.pack(.file(fileIndex)))
                split.append(PackedRow.pack(.file(fileIndex)))
            }
            for hunkIndex in file.hunks {
                let hunk = storage.hunks[hunkIndex]
                unified.append(PackedRow.pack(.hunk(hunkIndex)))
                split.append(PackedRow.pack(.hunk(hunkIndex)))
                var deleted: [Int] = []
                var added: [Int] = []
                func flush() {
                    for offset in 0..<max(deleted.count, added.count) {
                        split.append(
                            PackedRow.pack(
                                .lines(
                                    left: offset < deleted.count ? deleted[offset] : nil,
                                    right: offset < added.count ? added[offset] : nil)))
                    }
                    deleted.removeAll(keepingCapacity: true)
                    added.removeAll(keepingCapacity: true)
                }
                var line = hunk.firstLine
                while line < hunk.lines.upperBound {
                    while gapIndex < gaps.count, gaps[gapIndex].lines.upperBound <= line { gapIndex += 1 }
                    if gapIndex < gaps.count, gaps[gapIndex].first == line {
                        flush()
                        unified.append(PackedRow.pack(.gap(gapIndex)))
                        split.append(PackedRow.pack(.gap(gapIndex)))
                        line = gaps[gapIndex].lines.upperBound
                        gapIndex += 1
                        continue
                    }
                    unified.append(PackedRow.pack(.line(line)))
                    switch storage.lines[line].kind {
                    case .context:
                        flush()
                        split.append(PackedRow.pack(.lines(left: line, right: line)))
                    case .deleted:
                        // A deletion after additions starts a new pairing run.
                        if !added.isEmpty { flush() }
                        deleted.append(line)
                    case .added:
                        added.append(line)
                    }
                    line += 1
                }
                flush()
            }
        }
        return (unified, split)
    }

    // MARK: Search

    /// Case-insensitive (or sensitive) matches in the line rows of `layout` (unified or full file).
    public func search(_ query: String, caseSensitive: Bool = false, layout: DiffLayout = .unified) -> [RowMatch] {
        guard !query.isEmpty else { return [] }
        let rows = layout == .fullFile ? full : unified
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [RowMatch] = []
        for (index, packed) in rows.enumerated() {
            guard case .line(let line) = PackedRow.unpack(packed) else { continue }
            let text = self.text(ofLine: line)
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: query, options: options, range: searchRange) {
                let start = text.utf16.distance(from: text.utf16.startIndex, to: found.lowerBound)
                let end = text.utf16.distance(from: text.utf16.startIndex, to: found.upperBound)
                matches.append(RowMatch(row: index, range: start..<end))
                searchRange = found.upperBound..<text.endIndex
                if found.isEmpty { break }
            }
        }
        return matches
    }

    // MARK: Measurement

    /// Bytes held by this document: Git's output, line/hunk records and the three row tables.
    public var approximateBytes: Int {
        storage.bytes.count + storage.lines.count * MemoryLayout<LineRecord>.stride
            + storage.hunks.count * MemoryLayout<HunkRecord>.stride
            + unified.count * MemoryLayout<UInt32>.stride + full.count * MemoryLayout<UInt32>.stride
            + split.count * MemoryLayout<UInt64>.stride
    }
}

/// Row encoding: top 2 bits kind (line, hunk, file, gap), low 30 bits index. A split row is two such
/// values (left in the high half); `lines` uses kind `line` per side, `0xFFFF_FFFF` for "no line".
enum PackedRow {
    static let none: UInt32 = 0xFFFF_FFFF

    static func pack(_ row: DiffRow) -> UInt32 {
        switch row {
        case .line(let index): UInt32(index)
        case .hunk(let index): 1 << 30 | UInt32(index)
        case .file(let index): 2 << 30 | UInt32(index)
        case .gap(let index): 3 << 30 | UInt32(index)
        }
    }

    static func unpack(_ value: UInt32) -> DiffRow {
        let index = Int(value & 0x3FFF_FFFF)
        switch value >> 30 {
        case 0: return .line(index)
        case 1: return .hunk(index)
        case 2: return .file(index)
        default: return .gap(index)
        }
    }

    static func pack(_ row: SplitRow) -> UInt64 {
        switch row {
        case .lines(let left, let right):
            return UInt64(left.map { UInt32($0) } ?? none) << 32 | UInt64(right.map { UInt32($0) } ?? none)
        case .hunk(let index): return UInt64(pack(DiffRow.hunk(index))) << 32 | UInt64(none - 1)
        case .file(let index): return UInt64(pack(DiffRow.file(index))) << 32 | UInt64(none - 1)
        case .gap(let index): return UInt64(pack(DiffRow.gap(index))) << 32 | UInt64(none - 1)
        }
    }

    static func unpackSplit(_ value: UInt64) -> SplitRow {
        let left = UInt32(value >> 32)
        let right = UInt32(value & 0xFFFF_FFFF)
        if right == none - 1 {
            switch unpack(left) {
            case .hunk(let index): return .hunk(index)
            case .file(let index): return .file(index)
            case .gap(let index): return .gap(index)
            case .line(let index): return .lines(left: index, right: nil)
            }
        }
        return .lines(left: left == none ? nil : Int(left), right: right == none ? nil : Int(right))
    }
}
