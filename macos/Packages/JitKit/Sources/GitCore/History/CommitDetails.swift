import Foundation

/// One changed path between two trees (design §3.4).
public struct ChangedFile: Sendable, Hashable {
    public enum Status: UInt8, Sendable, Hashable {
        case added, modified, deleted, renamed, copied, typeChanged, unmerged, unknown

        init(letter: UInt8) {
            switch letter {
            case UInt8(ascii: "A"): self = .added
            case UInt8(ascii: "M"): self = .modified
            case UInt8(ascii: "D"): self = .deleted
            case UInt8(ascii: "R"): self = .renamed
            case UInt8(ascii: "C"): self = .copied
            case UInt8(ascii: "T"): self = .typeChanged
            case UInt8(ascii: "U"): self = .unmerged
            default: self = .unknown
            }
        }

        /// The one-letter code Git uses.
        public var letter: String {
            switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .typeChanged: "T"
            case .unmerged: "U"
            case .unknown: "?"
            }
        }
    }

    public let status: Status
    /// Path after the change (UTF-8 decoded with replacement characters; `rawPath` keeps the bytes).
    public let path: String
    public let rawPath: [UInt8]
    /// Source path of renames and copies.
    public let oldPath: String?
    /// `nil` for binary files (`-` in `--numstat`).
    public let additions: Int?
    public let deletions: Int?

    public var isBinary: Bool { additions == nil }
}

/// Everything the inspector shows for one commit. Bodies are fetched only here (never stored per row).
public struct CommitDetails: Sendable, Equatable {
    public let oid: ObjectID
    public let parents: [ObjectID]
    public let authorName: String
    public let authorEmail: String
    public let authorTime: Int64
    public let authorTimeZone: String
    public let committerName: String
    public let committerEmail: String
    public let committerTime: Int64
    public let subject: String
    /// Message after the subject line, without the separating blank line.
    public let body: String
    /// Changes against the first parent (or the empty tree for a root commit).
    public let files: [ChangedFile]
}

/// Which side a comparison takes the second tree from.
public enum CompareMode: Sendable, Hashable {
    /// `a..b` — the direct difference between the two trees.
    case direct
    /// `a...b` — changes on `b` since the common ancestor.
    case sinceMergeBase
}

extension RepositoryHandle {
    /// Message, identities and changed files of one commit (design §3.4). Cancelling the calling task
    /// kills the Git processes.
    public func commitDetails(_ oid: ObjectID) async throws(GitCoreError) -> CommitDetails {
        if let cached = detailsCache.value(for: oid) { return cached }
        let format = try await objectFormat()
        let hex = oid.hex(format)
        let header = try await runRead(
            ReadOnlyPolicy.configOverrides + [
                "show", "-s", "--no-color", "--no-show-signature",
                "--format=%H%x00%P%x00%aN%x00%aE%x00%at%x00%ai%x00%cN%x00%cE%x00%ct%x00%B", hex, "--",
            ], limit: 16 * 1024 * 1024)
        var fields: [ArraySlice<UInt8>] = []
        var start = header.startIndex
        for index in header.indices where header[index] == 0 && fields.count < 9 {
            fields.append(header[start..<index])
            start = index + 1
        }
        fields.append(header[start...])
        guard fields.count == 10 else { throw .internalError(summary: "Git returned unexpected commit details.") }
        func text(_ n: Int) -> String { String(decoding: fields[n], as: UTF8.self) }
        let parents = fields[1].split(separator: 0x20).compactMap { ObjectID(hex: $0) }
        let message = text(9).trimmingCharacters(in: .newlines)
        let firstLineEnd = message.firstIndex(of: "\n") ?? message.endIndex
        let subject = String(message[..<firstLineEnd])
        let body = String(message[firstLineEnd...]).trimmingCharacters(in: .newlines)
        let zone = text(5).split(separator: " ").last.map(String.init) ?? "+0000"

        let files: [ChangedFile]
        if let first = parents.first {
            files = try await changedFiles(between: first.hex(format), and: hex)
        } else {
            files = try await changedFiles(arguments: [
                "diff-tree", "--no-commit-id", "--root", "-r", "-z", "-M", "--raw", "--numstat", hex,
            ])
        }
        let details = CommitDetails(
            oid: oid, parents: parents, authorName: text(2), authorEmail: text(3), authorTime: Int64(text(4)) ?? 0,
            authorTimeZone: zone, committerName: text(6), committerEmail: text(7),
            committerTime: Int64(text(8)) ?? 0, subject: subject, body: body, files: files)
        detailsCache.insert(details, for: oid)
        return details
    }

    /// Files changed between two revisions (`git diff a b`, or `a...b`).
    public func compare(_ a: ObjectID, _ b: ObjectID, mode: CompareMode) async throws(GitCoreError) -> [ChangedFile] {
        let format = try await objectFormat()
        switch mode {
        case .direct:
            return try await changedFiles(between: a.hex(format), and: b.hex(format))
        case .sinceMergeBase:
            return try await changedFiles(arguments: [
                "diff", "--no-ext-diff", "--no-textconv", "-z", "-M", "--raw", "--numstat",
                "\(a.hex(format))...\(b.hex(format))", "--",
            ])
        }
    }

    /// Tracked files that differ between `commit` and the working tree. Untracked files are not included
    /// (the UI says so).
    public func compareWithWorkingTree(_ commit: ObjectID) async throws(GitCoreError) -> [ChangedFile] {
        let format = try await objectFormat()
        return try await changedFiles(arguments: [
            "diff", "--no-ext-diff", "--no-textconv", "-z", "-M", "--raw", "--numstat", commit.hex(format), "--",
        ])
    }

    private func changedFiles(between a: String, and b: String) async throws(GitCoreError) -> [ChangedFile] {
        try await changedFiles(arguments: [
            "diff-tree", "--no-commit-id", "-r", "-z", "-M", "--raw", "--numstat", a, b, "--",
        ])
    }

    private func changedFiles(arguments: [String]) async throws(GitCoreError) -> [ChangedFile] {
        let output = try await runRead(ReadOnlyPolicy.configOverrides + arguments, limit: 256 * 1024 * 1024)
        return try ChangedFileParser.parse(output)
    }

    func runRead(_ arguments: [String], limit: Int) async throws(GitCoreError) -> [UInt8] {
        do {
            return try await gitEngine.run(
                GitCommand(arguments, in: workingDirectory, kind: .read, timeout: .seconds(120), stdoutLimit: limit)
            ).stdout
        } catch {
            throw RepositoryDiscovery.classify(error, path: workingDirectory)
        }
    }
}

/// Parses `--raw --numstat -z` output: raw records first (`:<modes> <ids> <status>\0path\0[path\0]`),
/// then numstat records (`adds\tdels\tpath\0` or `adds\tdels\t\0old\0new\0`), in the same order.
enum ChangedFileParser {
    static func parse(_ bytes: [UInt8]) throws(GitCoreError) -> [ChangedFile] {
        struct Raw {
            var status: ChangedFile.Status
            var path: ArraySlice<UInt8>
            var oldPath: ArraySlice<UInt8>?
        }
        var raws: [Raw] = []
        var stats: [(Int?, Int?)] = []
        var index = bytes.startIndex
        func nextField() -> ArraySlice<UInt8>? {
            guard index < bytes.endIndex else { return nil }
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
            let field = bytes[index..<end]
            index = min(end + 1, bytes.endIndex)
            return field
        }
        while index < bytes.endIndex {
            if bytes[index] == UInt8(ascii: "\n") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: ":") {
                guard let meta = nextField(), let statusByte = meta.split(separator: 0x20).last?.first else {
                    throw .internalError(summary: "Git returned an unexpected list of changed files.")
                }
                let status = ChangedFile.Status(letter: statusByte)
                guard let first = nextField() else { break }
                if status == .renamed || status == .copied {
                    guard let second = nextField() else { break }
                    raws.append(Raw(status: status, path: second, oldPath: first))
                } else {
                    raws.append(Raw(status: status, path: first, oldPath: nil))
                }
            } else {
                // numstat: "adds\tdels\tpath" or "adds\tdels\t" followed by two path fields.
                guard let field = nextField() else { break }
                let parts = field.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else {
                    throw .internalError(summary: "Git returned unexpected change statistics.")
                }
                let adds = Int(String(decoding: parts[0], as: UTF8.self))
                let dels = Int(String(decoding: parts[1], as: UTF8.self))
                if parts[2].isEmpty {
                    _ = nextField()
                    _ = nextField()
                }
                stats.append((adds, dels))
            }
        }
        return raws.enumerated().map { offset, raw in
            let stat = offset < stats.count ? stats[offset] : (nil, nil)
            return ChangedFile(
                status: raw.status, path: String(decoding: raw.path, as: UTF8.self), rawPath: Array(raw.path),
                oldPath: raw.oldPath.map { String(decoding: $0, as: UTF8.self) }, additions: stat.0,
                deletions: stat.1)
        }
    }
}

/// A small LRU of commit details (32 entries) kept by `RepositoryHandle`.
final class DetailsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ObjectID: CommitDetails] = [:]
    private var order: [ObjectID] = []
    let capacity: Int

    init(capacity: Int = 32) { self.capacity = capacity }

    func value(for oid: ObjectID) -> CommitDetails? {
        lock.withLock {
            guard let value = entries[oid] else { return nil }
            if let index = order.firstIndex(of: oid) { order.remove(at: index) }
            order.append(oid)
            return value
        }
    }

    func insert(_ details: CommitDetails, for oid: ObjectID) {
        lock.withLock {
            if entries[oid] == nil { order.append(oid) }
            entries[oid] = details
            while order.count > capacity { entries[order.removeFirst()] = nil }
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
        }
    }

    var count: Int { lock.withLock { entries.count } }
}
