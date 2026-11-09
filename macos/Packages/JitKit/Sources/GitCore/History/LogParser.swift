import Foundation

/// Incremental byte-level parser of `git log -z --format=<LogParser.format>` (design §4.1, ADR-0005).
///
/// Records are six NUL-terminated fields: id, parent ids (space-separated), author name, author email,
/// author time (Unix seconds), subject. No `String` is created per field; the handler receives views
/// into the read buffer that are valid only during the call.
struct LogParser {
    /// `%aN`/`%aE` honour `.mailmap`, like `git log`'s own display.
    static let format = "%H%x00%P%x00%aN%x00%aE%x00%at%x00%s"
    static let fieldCount = 6

    struct Record {
        var oid = ObjectID.zero
        /// Reused for every record.
        var parents: [ObjectID] = []
        var name = UnsafeRawBufferPointer(start: nil, count: 0)
        var email = UnsafeRawBufferPointer(start: nil, count: 0)
        var time: Int64 = 0
        var subject = UnsafeRawBufferPointer(start: nil, count: 0)
    }

    private var pending: [UInt8] = []
    private var record = Record()
    private var fieldEnds = [Int](repeating: 0, count: fieldCount)
    /// Records parsed so far.
    private(set) var parsed = 0

    init() {
        record.parents.reserveCapacity(8)
        pending.reserveCapacity(512 * 1024)
    }

    /// Bytes received but not yet forming a complete record.
    var hasPartialRecord: Bool { !pending.isEmpty }

    /// Appends `bytes` and calls `handle` for every complete record, in order.
    mutating func consume(
        _ bytes: [UInt8], _ handle: (borrowing Record) throws(GitCoreError) -> Void
    ) throws(GitCoreError) {
        pending.append(contentsOf: bytes)
        var consumed = 0
        let input = pending  // shares storage; avoids overlapping access to `self` inside the closure
        let failure: GitCoreError? = input.withUnsafeBytes { buffer -> GitCoreError? in
            var start = 0
            outer: while start < buffer.count {
                var field = 0
                var index = start
                while field < Self.fieldCount {
                    guard let nul = memchr(buffer.baseAddress! + index, 0, buffer.count - index) else { break outer }
                    let position = buffer.baseAddress!.distance(to: UnsafeRawPointer(nul))
                    fieldEnds[field] = position
                    field += 1
                    index = position + 1
                }
                if let error = fill(buffer, recordStart: start) { return error }
                do throws(GitCoreError) {
                    try handle(record)
                } catch {
                    return error
                }
                parsed += 1
                start = index
                consumed = start
            }
            return nil
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        if let failure { throw failure }
    }

    private mutating func fill(_ buffer: UnsafeRawBufferPointer, recordStart: Int) -> GitCoreError? {
        func field(_ n: Int) -> UnsafeRawBufferPointer {
            let start = n == 0 ? recordStart : fieldEnds[n - 1] + 1
            return UnsafeRawBufferPointer(rebasing: buffer[start..<fieldEnds[n]])
        }
        // `git log -z` separates records with NUL; a leading newline can follow in some modes — skip it.
        var idField = field(0)
        while let first = idField.first, first == 0x0A {
            idField = UnsafeRawBufferPointer(rebasing: idField.dropFirst())
        }
        guard let oid = ObjectID(hex: idField) else {
            return .internalError(summary: "Git returned a malformed commit id in the history.")
        }
        record.oid = oid
        record.parents.removeAll(keepingCapacity: true)
        let parents = field(1)
        var start = 0
        while start < parents.count {
            var end = start
            while end < parents.count, parents[end] != 0x20 { end += 1 }
            if end > start {
                guard let parent = ObjectID(hex: UnsafeRawBufferPointer(rebasing: parents[start..<end])) else {
                    return .internalError(summary: "Git returned a malformed parent id in the history.")
                }
                record.parents.append(parent)
            }
            start = end + 1
        }
        record.name = field(2)
        record.email = field(3)
        var time: Int64 = 0
        var negative = false
        for byte in field(4) {
            if byte == 0x2D { negative = true } else if byte >= 0x30 && byte <= 0x39 {
                time = time &* 10 &+ Int64(byte - 0x30)
            }
        }
        record.time = negative ? -time : time
        record.subject = field(5)
        return nil
    }
}
