import Foundation

/// A parsed search field (design §3.3): free text matches subjects (and bodies in deep search), `sha:` or
/// a bare 4–64 digit hex string matches ids, `author:` matches author name/email, `ref:` matches ref
/// names. Tokens are AND-ed. Matching is case-insensitive and literal (no regex).
public struct HistorySearchQuery: Sendable, Hashable {
    public var text: [String] = []
    public var hexPrefixes: [String] = []
    public var authors: [String] = []
    public var refs: [String] = []

    public init(_ input: String) {
        for token in Self.tokens(input) {
            let lower = token.lowercased()
            if lower.hasPrefix("sha:") {
                let value = String(lower.dropFirst(4))
                if !value.isEmpty { hexPrefixes.append(value) }
            } else if lower.hasPrefix("author:") {
                let value = String(token.dropFirst(7))
                if !value.isEmpty { authors.append(value) }
            } else if lower.hasPrefix("ref:") {
                let value = String(token.dropFirst(4))
                if !value.isEmpty { refs.append(value) }
            } else if (4...64).contains(lower.count), lower.allSatisfy(\.isHexDigit) {
                // A bare hex string may be an id or a word; match either.
                hexPrefixes.append(lower)
            } else {
                text.append(token)
            }
        }
    }

    public var isEmpty: Bool { text.isEmpty && hexPrefixes.isEmpty && authors.isEmpty && refs.isEmpty }

    /// Splits on spaces, keeping `"quoted phrases"` (and `author:"Ana Ruiz"`) together.
    static func tokens(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in input {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

extension HistorySnapshot {
    /// Rows of loaded history matching `query`, in row order (in-memory byte scan, no Git process).
    /// A bare hex token matches either an id prefix or the text (it may be a word like `cafe`).
    public func search(_ query: HistorySearchQuery) -> [Int32] {
        guard !query.isEmpty, count > 0 else { return [] }
        let needles = query.text.map { ByteNeedle($0) }
        let hexNeedles = query.hexPrefixes.map { Array($0.utf8) }
        let hexAsText = query.hexPrefixes.map { ByteNeedle($0) }
        // Authors and refs are few: resolve them to sets first.
        var authorMatches: Set<UInt32>?
        if !query.authors.isEmpty {
            let lowered = query.authors.map { $0.lowercased() }
            var set = Set<UInt32>()
            for (index, author) in authors.enumerated() {
                let name = author.name.lowercased()
                let email = author.email.lowercased()
                if lowered.allSatisfy({ name.contains($0) || email.contains($0) }) { set.insert(UInt32(index)) }
            }
            authorMatches = set
        }
        var refCommits: Set<ObjectID>?
        if !query.refs.isEmpty {
            let lowered = query.refs.map { $0.lowercased() }
            refCommits = Set(
                refs.refs.filter { ref in lowered.allSatisfy { ref.shortName.lowercased().contains($0) } }
                    .compactMap(\.commit))
        }
        var result: [Int32] = []
        for chunk in chunks {
            chunk.subjects.withUnsafeBytes { arena in
                for local in 0..<chunk.count {
                    if let authorMatches, !authorMatches.contains(chunk.authors[local]) { continue }
                    let oid = chunk.oids[local]
                    if let refCommits, !refCommits.contains(oid) { continue }
                    let start = local == 0 ? 0 : Int(chunk.subjectEnds[local - 1])
                    let subject = UnsafeRawBufferPointer(rebasing: arena[start..<Int(chunk.subjectEnds[local])])
                    var matched = true
                    for needle in needles where !needle.occurs(in: subject) {
                        matched = false
                        break
                    }
                    if !matched { continue }
                    for (offset, prefix) in hexNeedles.enumerated() {
                        let isID = prefix.withUnsafeBytes { oid.hasHexPrefix($0) }
                        if !isID && !hexAsText[offset].occurs(in: subject) {
                            matched = false
                            break
                        }
                    }
                    if matched { result.append(Int32(chunk.base + local)) }
                }
            }
        }
        return result
    }
}

/// ASCII case-insensitive substring search over UTF-8 bytes (non-ASCII bytes compare exactly).
struct ByteNeedle {
    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8).map(Self.fold)
    }

    @inline(__always) static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }

    func occurs(in haystack: UnsafeRawBufferPointer) -> Bool {
        let n = bytes.count
        guard n > 0 else { return true }
        guard haystack.count >= n else { return false }
        let first = bytes[0]
        var index = 0
        let last = haystack.count - n
        while index <= last {
            if Self.fold(haystack[index]) == first {
                var offset = 1
                while offset < n, Self.fold(haystack[index + offset]) == bytes[offset] { offset += 1 }
                if offset == n { return true }
            }
            index += 1
        }
        return false
    }
}

extension HistoryLoader {
    /// Rows of the loaded history matching `query`.
    public func searchLoaded(_ query: HistorySearchQuery) -> [Int32] {
        snapshot.search(query)
    }
}

extension RepositoryHandle {
    /// Searches all history in scope with `git log` (subjects *and* bodies, authors; literal,
    /// case-insensitive), streaming matching commit ids. Cancelling the consuming task (or dropping the
    /// stream) kills Git. Bounded: the search stops after `limit` matches (memory stays ≤ 32 B × limit).
    public nonisolated func searchDeep(
        _ query: HistorySearchQuery, in historyQuery: HistoryQuery, refs: RefSnapshot, limit: Int = 5000
    ) -> AsyncThrowingStream<ObjectID, any Error> {
        let engine = gitEngine
        let directory = workingDirectory
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do throws(GitCoreError) {
                    guard var arguments = historyQuery.arguments(refs: refs, skip: 0) else {
                        continuation.finish()
                        return
                    }
                    // Replace the display format with ids only and add the filters before the revisions.
                    guard let formatIndex = arguments.firstIndex(where: { $0.hasPrefix("--format=") }) else {
                        continuation.finish()
                        return
                    }
                    arguments[formatIndex] = "--format=%H"
                    var filters = ["--regexp-ignore-case", "--fixed-strings", "--all-match"]
                    filters += query.text.map { "--grep=\($0)" }
                    filters += query.authors.map { "--author=\($0)" }
                    if query.text.isEmpty && query.authors.isEmpty {
                        continuation.finish()
                        return
                    }
                    arguments.insert(contentsOf: filters, at: formatIndex + 1)
                    let stream = try await engine.stream(
                        GitCommand(arguments, in: directory, kind: .read, timeout: nil))
                    var pending: [UInt8] = []
                    var found = 0
                    reading: while let chunk = try await stream.read(maxBytes: 64 * 1024) {
                        pending += chunk
                        var start = 0
                        while let end = pending[start...].firstIndex(where: { $0 == 0 || $0 == 0x0A }) {
                            let field = pending[start..<end]
                            if let oid = ObjectID(hex: field) {
                                continuation.yield(oid)
                                found += 1
                                if found >= limit {
                                    stream.terminate()
                                    break reading
                                }
                            }
                            start = end + 1
                        }
                        pending.removeFirst(start)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
