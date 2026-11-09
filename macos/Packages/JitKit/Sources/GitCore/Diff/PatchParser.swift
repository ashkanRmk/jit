import Foundation

/// How one diff line changed.
public enum DiffLineKind: UInt8, Sendable, Hashable {
    case context = 0, added = 1, deleted = 2

    var prefix: UInt8 {
        switch self {
        case .context: UInt8(ascii: " ")
        case .added: UInt8(ascii: "+")
        case .deleted: UInt8(ascii: "-")
        }
    }
}

/// One line of a hunk in 16 bytes (ADR-0005/0026): where its text is in the shared buffer and its numbers.
/// Text excludes the `+`/`-`/` ` prefix and the line ending.
struct LineRecord: Sendable, Hashable {
    /// Offset of the text in the buffer.
    var start: UInt32
    /// Bits 0–23 text length, 24–25 kind, 26 CRLF, 27 "\ No newline at end of file" follows.
    var packed: UInt32
    /// 1-based numbers; 0 when the line has no old (added) or new (deleted) side.
    var oldNumber: UInt32
    var newNumber: UInt32

    static let maxLength = (1 << 24) - 1

    var length: Int { Int(packed & 0x00FF_FFFF) }
    var kind: DiffLineKind { DiffLineKind(rawValue: UInt8((packed >> 24) & 0b11)) ?? .context }
    var isCRLF: Bool { packed & (1 << 26) != 0 }
    var noNewline: Bool { packed & (1 << 27) != 0 }

    init(start: Int, length: Int, kind: DiffLineKind, crlf: Bool, oldNumber: UInt32, newNumber: UInt32) {
        self.start = UInt32(start)
        packed = UInt32(length) | UInt32(kind.rawValue) << 24 | (crlf ? 1 << 26 : 0)
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }

    mutating func markNoNewline() { packed |= 1 << 27 }
}

/// One `@@` hunk.
public struct HunkRecord: Sendable, Hashable {
    public let oldStart: UInt32
    public let oldCount: UInt32
    public let newStart: UInt32
    public let newCount: UInt32
    /// The raw `@@ … @@ section` line, newline included.
    let headerRange: Range<Int>
    /// Lines `firstLine ..< firstLine + lineCount` in `PatchStorage.lines`.
    public let firstLine: Int
    public let lineCount: Int
    public let file: Int

    public var lines: Range<Int> { firstLine..<(firstLine + lineCount) }
}

/// One file of a patch. Paths are decoded (C-quoting removed); `nil` means `/dev/null`.
public struct DiffFile: Sendable, Hashable {
    public enum Status: Sendable, Hashable { case added, deleted, modified, renamed, copied }

    public var oldPath: String?
    public var newPath: String?
    public var status: Status = .modified
    public var oldMode: UInt32?
    public var newMode: UInt32?
    public var oldID: String?
    public var newID: String?
    /// Rename/copy similarity in percent.
    public var similarity: Int?
    public var isBinary = false
    /// Everything from `diff --git` up to the first hunk (extended headers, binary patch body).
    var headerRange: Range<Int> = 0..<0
    public var hunks: Range<Int> = 0..<0

    /// The path to show: the new path, or the old one for a deletion.
    public var path: String { newPath ?? oldPath ?? "" }
    public var isSubmodule: Bool { oldMode == 0o160000 || newMode == 0o160000 }
    public var isSymlink: Bool { oldMode == 0o120000 || newMode == 0o120000 }
    public var modeChanged: Bool { oldMode != nil && newMode != nil && oldMode != newMode }
}

/// The parsed patch: Git's bytes plus flat records into them. Immutable and shared by every layout of
/// every `DiffDocument` made from it.
public final class PatchStorage: Sendable {
    public let bytes: [UInt8]
    public let files: [DiffFile]
    public let hunks: [HunkRecord]
    let lines: [LineRecord]
    /// The exact "\ No newline at end of file" line Git printed (newline included).
    let noNewlineMarker: [UInt8]
    let endsWithNewline: Bool

    init(
        bytes: [UInt8], files: [DiffFile], hunks: [HunkRecord], lines: [LineRecord], noNewlineMarker: [UInt8],
        endsWithNewline: Bool
    ) {
        self.bytes = bytes
        self.files = files
        self.hunks = hunks
        self.lines = lines
        self.noNewlineMarker = noNewlineMarker
        self.endsWithNewline = endsWithNewline
    }

    public var lineCount: Int { lines.count }

    /// Re-emits the patch from the records (headers verbatim, every hunk line rebuilt from kind, text,
    /// ending and marker). Equal to Git's output byte for byte (`roundtripParseSerializeIdenticalBytes`).
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for file in files {
            out += bytes[file.headerRange]
            for hunk in hunks[file.hunks] {
                out += bytes[hunk.headerRange]
                for record in lines[hunk.lines] {
                    out.append(record.kind.prefix)
                    out += bytes[Int(record.start)..<(Int(record.start) + record.length)]
                    if record.isCRLF { out.append(UInt8(ascii: "\r")) }
                    out.append(UInt8(ascii: "\n"))
                    if record.noNewline { out += noNewlineMarker }
                }
            }
        }
        if !endsWithNewline, out.last == UInt8(ascii: "\n") { out.removeLast() }
        return out
    }
}

/// Parses `git diff` patch output as bytes (ADR-0026): never decodes whole lines to `String`, never
/// normalizes line endings.
public enum PatchParser {
    public static func parse(_ bytes: [UInt8]) throws(GitCoreError) -> PatchStorage {
        var files: [DiffFile] = []
        var hunks: [HunkRecord] = []
        var lines: [LineRecord] = []
        var marker: [UInt8] = Array("\\ No newline at end of file\n".utf8)
        var cursor = 0
        let count = bytes.count

        /// The line at `cursor`: content range (without `\n`) and the index after it.
        func line(at position: Int) -> (content: Range<Int>, next: Int) {
            var end = position
            while end < count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            return (position..<end, end < count ? end + 1 : end)
        }
        func starts(_ range: Range<Int>, _ prefix: String) -> Bool {
            bytes[range].starts(with: prefix.utf8)
        }
        func fail(_ what: String) -> GitCoreError {
            .internalError(summary: "Unexpected `git diff` output (\(what)).")
        }

        while cursor < count {
            let (first, afterFirst) = line(at: cursor)
            guard starts(first, "diff --git ") else { throw fail("expected a file header") }
            var file = DiffFile()
            let headerStart = cursor
            var gitLinePaths = Self.gitLinePaths(bytes[(first.lowerBound + 11)..<first.upperBound])
            cursor = afterFirst
            // Extended headers (and a binary patch body) up to the first hunk or the next file.
            while cursor < count {
                let (content, next) = line(at: cursor)
                if starts(content, "@@ ") || starts(content, "diff --git ") { break }
                let text = bytes[content]
                func value(after prefix: String) -> ArraySlice<UInt8> { text.dropFirst(prefix.utf8.count) }
                func mode(after prefix: String) -> UInt32? {
                    UInt32(String(decoding: value(after: prefix), as: UTF8.self), radix: 8)
                }
                if starts(content, "old mode ") {
                    file.oldMode = mode(after: "old mode ")
                } else if starts(content, "new mode ") {
                    file.newMode = mode(after: "new mode ")
                } else if starts(content, "deleted file mode ") {
                    file.oldMode = mode(after: "deleted file mode ")
                    file.status = .deleted
                } else if starts(content, "new file mode ") {
                    file.newMode = mode(after: "new file mode ")
                    file.status = .added
                } else if starts(content, "rename from ") {
                    file.oldPath = Self.path(value(after: "rename from "), stripPrefix: false)
                    file.status = .renamed
                } else if starts(content, "rename to ") {
                    file.newPath = Self.path(value(after: "rename to "), stripPrefix: false)
                } else if starts(content, "copy from ") {
                    file.oldPath = Self.path(value(after: "copy from "), stripPrefix: false)
                    file.status = .copied
                } else if starts(content, "copy to ") {
                    file.newPath = Self.path(value(after: "copy to "), stripPrefix: false)
                } else if starts(content, "similarity index ") || starts(content, "dissimilarity index ") {
                    let digits = text.drop { !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
                        .prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
                    file.similarity = Int(String(decoding: digits, as: UTF8.self))
                } else if starts(content, "index ") {
                    let fields = value(after: "index ").split(separator: UInt8(ascii: " "))
                    if let ids = fields.first {
                        let parts = ids.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: true)
                        if parts.count == 2 {
                            file.oldID = String(decoding: parts[0], as: UTF8.self)
                            file.newID = String(decoding: parts[1], as: UTF8.self)
                        }
                    }
                    if fields.count > 1, let shared = UInt32(String(decoding: fields[1], as: UTF8.self), radix: 8) {
                        file.oldMode = file.oldMode ?? shared
                        file.newMode = file.newMode ?? shared
                    }
                } else if starts(content, "--- ") {
                    let path = Self.path(value(after: "--- "), stripPrefix: true)
                    if file.status != .renamed, file.status != .copied { file.oldPath = path }
                    gitLinePaths = nil
                } else if starts(content, "+++ ") {
                    let path = Self.path(value(after: "+++ "), stripPrefix: true)
                    if file.status != .renamed, file.status != .copied { file.newPath = path }
                } else if starts(content, "Binary files ") || starts(content, "GIT binary patch") {
                    file.isBinary = true
                }
                cursor = next
            }
            // Mode-only, empty and binary files have no ---/+++ lines: paths come from `diff --git`.
            if let (old, new) = gitLinePaths, file.oldPath == nil, file.newPath == nil {
                file.oldPath = file.status == .added ? nil : old
                file.newPath = file.status == .deleted ? nil : new
            }
            if file.status == .added { file.oldPath = nil }
            if file.status == .deleted { file.newPath = nil }
            file.headerRange = headerStart..<cursor
            let fileIndex = files.count
            let firstHunk = hunks.count

            // Hunks.
            while cursor < count {
                let (header, afterHeader) = line(at: cursor)
                guard starts(header, "@@ ") else { break }
                guard let numbers = Self.hunkNumbers(bytes[header]) else { throw fail("hunk header") }
                let firstLine = lines.count
                var oldLeft = numbers.oldCount
                var newLeft = numbers.newCount
                var oldNumber = numbers.oldStart == 0 ? 1 : numbers.oldStart
                var newNumber = numbers.newStart == 0 ? 1 : numbers.newStart
                cursor = afterHeader
                while cursor < count {
                    let (content, next) = line(at: cursor)
                    let lead = content.isEmpty ? UInt8(ascii: " ") : bytes[content.lowerBound]
                    if lead == UInt8(ascii: "\\") {
                        guard firstLine < lines.count else { throw fail("marker without a line") }
                        lines[lines.count - 1].markNoNewline()
                        marker = Array(bytes[content.lowerBound..<next])
                        cursor = next
                        continue
                    }
                    if oldLeft == 0 && newLeft == 0 { break }
                    let kind: DiffLineKind
                    switch lead {
                    case UInt8(ascii: " "): kind = .context
                    case UInt8(ascii: "+"): kind = .added
                    case UInt8(ascii: "-"): kind = .deleted
                    default: throw fail("hunk line")
                    }
                    var start = content.lowerBound + (content.isEmpty ? 0 : 1)
                    if start > content.upperBound { start = content.upperBound }
                    var end = content.upperBound
                    let crlf = end > start && bytes[end - 1] == UInt8(ascii: "\r")
                    if crlf { end -= 1 }
                    guard end - start <= LineRecord.maxLength else { throw fail("line longer than 16 MB") }
                    switch kind {
                    case .context:
                        guard oldLeft > 0, newLeft > 0 else { throw fail("hunk count") }
                        lines.append(
                            .init(
                                start: start, length: end - start, kind: kind, crlf: crlf,
                                oldNumber: oldNumber, newNumber: newNumber))
                        oldLeft -= 1; newLeft -= 1; oldNumber += 1; newNumber += 1
                    case .added:
                        guard newLeft > 0 else { throw fail("hunk count") }
                        lines.append(
                            .init(
                                start: start, length: end - start, kind: kind, crlf: crlf,
                                oldNumber: 0, newNumber: newNumber))
                        newLeft -= 1; newNumber += 1
                    case .deleted:
                        guard oldLeft > 0 else { throw fail("hunk count") }
                        lines.append(
                            .init(
                                start: start, length: end - start, kind: kind, crlf: crlf,
                                oldNumber: oldNumber, newNumber: 0))
                        oldLeft -= 1; oldNumber += 1
                    }
                    cursor = next
                }
                guard oldLeft == 0, newLeft == 0 else { throw fail("truncated hunk") }
                hunks.append(
                    HunkRecord(
                        oldStart: numbers.oldStart, oldCount: numbers.oldCount, newStart: numbers.newStart,
                        newCount: numbers.newCount, headerRange: header.lowerBound..<afterHeader,
                        firstLine: firstLine, lineCount: lines.count - firstLine, file: fileIndex))
            }
            file.hunks = firstHunk..<hunks.count
            files.append(file)
        }
        return PatchStorage(
            bytes: bytes, files: files, hunks: hunks, lines: lines, noNewlineMarker: marker,
            endsWithNewline: bytes.last.map { $0 == UInt8(ascii: "\n") } ?? true)
    }

    /// `@@ -a[,b] +c[,d] @@`.
    static func hunkNumbers(_ text: ArraySlice<UInt8>) -> (
        oldStart: UInt32, oldCount: UInt32, newStart: UInt32, newCount: UInt32
    )? {
        var index = text.startIndex + 3
        func number() -> UInt32? {
            var value: UInt32 = 0
            var digits = 0
            while index < text.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[index]) {
                value = value &* 10 &+ UInt32(text[index] - UInt8(ascii: "0"))
                index += 1
                digits += 1
            }
            return digits > 0 ? value : nil
        }
        func range(_ sign: UInt8) -> (UInt32, UInt32)? {
            guard index < text.endIndex, text[index] == sign else { return nil }
            index += 1
            guard let start = number() else { return nil }
            var length: UInt32 = 1
            if index < text.endIndex, text[index] == UInt8(ascii: ",") {
                index += 1
                guard let value = number() else { return nil }
                length = value
            }
            return (start, length)
        }
        guard let old = range(UInt8(ascii: "-")), index < text.endIndex, text[index] == UInt8(ascii: " ") else {
            return nil
        }
        index += 1
        guard let new = range(UInt8(ascii: "+")) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// A path field: C-quoted (`"a/x\ty"`) or plain; `/dev/null` → `nil`. Plain `---`/`+++` paths may carry
    /// a trailing tab (Git adds one when the name contains a space).
    static func path(_ field: ArraySlice<UInt8>, stripPrefix: Bool) -> String? {
        var raw: [UInt8]
        if field.first == UInt8(ascii: "\"") {
            guard let (decoded, _) = unquote(field) else { return String(decoding: field, as: UTF8.self) }
            raw = decoded
        } else {
            raw = Array(field)
            if raw.last == UInt8(ascii: "\t") { raw.removeLast() }
        }
        if raw.elementsEqual("/dev/null".utf8) { return nil }
        if stripPrefix, raw.count >= 2, raw[1] == UInt8(ascii: "/"),
            raw[0] == UInt8(ascii: "a") || raw[0] == UInt8(ascii: "b")
        {
            raw.removeFirst(2)
        }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Paths from `a/<old> b/<new>` after `diff --git `: both quoted, or plain and equal (split in the middle).
    static func gitLinePaths(_ text: ArraySlice<UInt8>) -> (String, String)? {
        if text.first == UInt8(ascii: "\"") {
            guard let (old, used) = unquote(text) else { return nil }
            let rest = text.dropFirst(used).drop { $0 == UInt8(ascii: " ") }
            let new: [UInt8]
            if rest.first == UInt8(ascii: "\"") {
                guard let (decoded, _) = unquote(rest) else { return nil }
                new = decoded
            } else {
                new = Array(rest)
            }
            return (strip(old), strip(new))
        }
        if let quote = text.firstIndex(of: UInt8(ascii: "\"")), quote > text.startIndex {
            let old = Array(text[text.startIndex..<(quote - 1)])
            guard let (new, _) = unquote(text[quote...]) else { return nil }
            return (strip(old), strip(new))
        }
        // "a/P b/P": the two halves are the same path.
        let length = text.count
        guard length >= 5, (length - 1) % 2 == 0 else { return nil }
        let half = (length - 1) / 2
        let old = text.prefix(half)
        let new = text.suffix(half)
        guard text[text.startIndex + half] == UInt8(ascii: " "), old.dropFirst(2).elementsEqual(new.dropFirst(2)) else {
            return nil
        }
        return (strip(Array(old)), strip(Array(new)))
    }

    private static func strip(_ raw: [UInt8]) -> String {
        let trimmed = raw.count >= 2 && raw[1] == UInt8(ascii: "/") ? Array(raw.dropFirst(2)) : raw
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Decodes a C-quoted string starting at `text.first == "`; returns the bytes and how many input bytes
    /// were consumed (both quotes included).
    static func unquote(_ text: ArraySlice<UInt8>) -> ([UInt8], Int)? {
        var out: [UInt8] = []
        var index = text.startIndex + 1
        while index < text.endIndex {
            let byte = text[index]
            if byte == UInt8(ascii: "\"") { return (out, index - text.startIndex + 1) }
            if byte == UInt8(ascii: "\\"), index + 1 < text.endIndex {
                let next = text[index + 1]
                switch next {
                case UInt8(ascii: "a"): out.append(7)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "v"): out.append(11)
                case UInt8(ascii: "f"): out.append(12)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "0")...UInt8(ascii: "3"):
                    guard index + 3 < text.endIndex else { return nil }
                    var value: UInt8 = 0
                    for offset in 1...3 {
                        let digit = text[index + offset]
                        guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { return nil }
                        value = value &* 8 &+ (digit - UInt8(ascii: "0"))
                    }
                    out.append(value)
                    index += 4
                    continue
                default: out.append(next)
                }
                index += 2
                continue
            }
            out.append(byte)
            index += 1
        }
        return nil
    }
}
