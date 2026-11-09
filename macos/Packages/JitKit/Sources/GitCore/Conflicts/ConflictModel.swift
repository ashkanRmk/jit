import Foundation

/// A content hash of a working-tree file (FNV-1a 64 + length). Used only to detect that a file changed
/// between load and save (design §4.10), never as an object ID.
public struct FileHash: Sendable, Hashable, CustomStringConvertible {
    public let value: UInt64
    public let length: Int
    /// `false` only for `.missing`: a missing file never equals an empty one.
    public let exists: Bool

    public init(_ bytes: some Collection<UInt8>) {
        exists = true
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        value = hash
        length = bytes.count
    }

    private init(missing: Void) {
        value = 0
        length = 0
        exists = false
    }

    /// A file that does not exist.
    public static let missing = FileHash(missing: ())

    public var description: String { exists ? String(value, radix: 16) + ":\(length)" : "missing" }

    static func of(path: String) -> FileHash? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return FileHash(data)
    }
}

/// One stage of an unmerged index entry.
public struct ConflictStage: Sendable, Hashable {
    /// Octal mode, e.g. `100644`, `100755`, `120000` (symlink), `160000` (submodule).
    public let mode: String
    public let oid: String

    public var isSymlink: Bool { mode == "120000" }
    public var isSubmodule: Bool { mode == "160000" }
}

/// One conflicted path (design §4.10).
public struct ConflictEntry: Sendable, Hashable, Identifiable {
    /// `git status` XY code of an unmerged entry.
    public enum Code: String, Sendable, Hashable, CaseIterable {
        case bothModified = "UU", bothAdded = "AA", deletedByThem = "UD", deletedByUs = "DU"
        case addedByUs = "AU", addedByThem = "UA", bothDeleted = "DD"
    }

    /// How Jit resolves it (design §3.9).
    public enum Presentation: Sendable, Hashable {
        /// Three-way text resolver.
        case text
        /// Modified by one side, deleted by the other: keep or delete.
        case modifyDelete(deletedBy: ConflictSide)
        /// Binary, symlink, non-UTF-8 or oversized: take one side.
        case pickSide(reason: String)
        /// Submodule: explanation + Terminal only (Phase 8).
        case submodule
        /// Both sides deleted (rename/rename): keep the paths Git produced or remove.
        case bothDeleted
    }

    public let path: String
    public let code: Code
    public let base: ConflictStage?
    public let ours: ConflictStage?
    public let theirs: ConflictStage?
    public var isBinary: Bool
    public var isOversized: Bool
    public var isValidUTF8: Bool

    public var id: String { path }

    public var isSymlink: Bool { [base, ours, theirs].contains { $0?.isSymlink == true } }
    public var isSubmodule: Bool { [base, ours, theirs].contains { $0?.isSubmodule == true } }

    public var presentation: Presentation {
        if isSubmodule { return .submodule }
        switch code {
        case .bothDeleted: return .bothDeleted
        case .deletedByThem: return .modifyDelete(deletedBy: .theirs)
        case .deletedByUs: return .modifyDelete(deletedBy: .ours)
        default: break
        }
        if ours == nil { return .modifyDelete(deletedBy: .ours) }
        if theirs == nil { return .modifyDelete(deletedBy: .theirs) }
        if isSymlink { return .pickSide(reason: "Symbolic link") }
        if isBinary { return .pickSide(reason: "Binary file") }
        if isOversized { return .pickSide(reason: "Larger than \(ConflictLimits.maxTextBytes / 1_000_000) MB") }
        if !isValidUTF8 { return .pickSide(reason: "Not UTF-8 text") }
        return .text
    }
}

public enum ConflictSide: String, Sendable, Hashable {
    case ours, theirs
}

public enum ConflictLimits {
    /// Text conflicts above this size get the pick-a-side fallback (design §4.10).
    public static let maxTextBytes = 5_000_000
    /// Bytes inspected for NUL (binary detection).
    public static let sniffBytes = 8_000
}

extension RepositoryHandle {
    /// Conflicted paths from `git status --porcelain=v2 -z` `u` records (stage modes and OIDs), classified
    /// by kind and attributes (symlink, submodule, binary, size, UTF-8).
    public nonisolated func conflicts() async throws(GitCoreError) -> [ConflictEntry] {
        let output = try await runRead(
            ["--no-optional-locks", "status", "--porcelain=v2", "-z", "--untracked-files=no"], limit: 128 * 1024 * 1024)
        var entries: [ConflictEntry] = []
        var index = output.startIndex
        while index < output.endIndex {
            let end = output[index...].firstIndex(of: 0) ?? output.endIndex
            let record = output[index..<end]
            index = end < output.endIndex ? output.index(after: end) : end
            guard record.first == UInt8(ascii: "u") else {
                // Renames (`2`) carry an extra NUL-terminated original path.
                if record.first == UInt8(ascii: "2"), index < output.endIndex {
                    index = (output[index...].firstIndex(of: 0).map { output.index(after: $0) }) ?? output.endIndex
                }
                continue
            }
            // u XY sub m1 m2 m3 mW h1 h2 h3 path
            var fields: [Substring] = []
            var rest = Substring(String(decoding: record, as: UTF8.self))
            for _ in 0..<10 {
                guard let space = rest.firstIndex(of: " ") else { break }
                fields.append(rest[..<space])
                rest = rest[rest.index(after: space)...]
            }
            guard fields.count == 10, let code = ConflictEntry.Code(rawValue: String(fields[1])) else { continue }
            func stage(_ mode: Substring, _ oid: Substring) -> ConflictStage? {
                mode == "000000" ? nil : ConflictStage(mode: String(mode), oid: String(oid))
            }
            entries.append(
                ConflictEntry(
                    path: String(rest), code: code, base: stage(fields[3], fields[7]),
                    ours: stage(fields[4], fields[8]),
                    theirs: stage(fields[5], fields[9]), isBinary: false, isOversized: false, isValidUTF8: true))
        }
        guard !entries.isEmpty else { return [] }
        let binaryByAttribute = try await binaryAttributes(entries.map(\.path))
        for position in entries.indices {
            var entry = entries[position]
            if binaryByAttribute.contains(entry.path) { entry.isBinary = true }
            for stage in [entry.ours, entry.theirs, entry.base].compactMap({ $0 }) where !stage.isSubmodule {
                let size = try await blobSize(stage.oid)
                if size > ConflictLimits.maxTextBytes { entry.isOversized = true }
                if stage.isSymlink || entry.isOversized { continue }
                let head = try await blob(stage.oid, limit: max(size, 1) + 1)
                if head.prefix(ConflictLimits.sniffBytes).contains(0) { entry.isBinary = true }
                if String(validating: head, as: UTF8.self) == nil { entry.isValidUTF8 = false }
            }
            entries[position] = entry
        }
        return entries
    }

    private nonisolated func binaryAttributes(_ paths: [String]) async throws(GitCoreError) -> Set<String> {
        var input: [UInt8] = []
        for path in paths {
            input += Array(path.utf8)
            input.append(0)
        }
        let output = try await gitEngine.run(
            GitCommand(
                ["check-attr", "-z", "--stdin", "binary", "diff"], in: workingDirectory, kind: .read,
                stdoutLimit: 16 * 1024 * 1024, stdin: input))
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var binary = Set<String>()
        var position = 0
        while position + 2 < fields.count {
            let (path, attribute, value) = (fields[position], fields[position + 1], fields[position + 2])
            if (attribute == "binary" && value == "set") || (attribute == "diff" && value == "unset") {
                binary.insert(path)
            }
            position += 3
        }
        return binary
    }

    nonisolated func blobSize(_ oid: String) async throws(GitCoreError) -> Int {
        try Self.requireObjectID(oid)
        let text = String(decoding: try await runRead(["cat-file", "-s", oid], limit: 64), as: UTF8.self)
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    nonisolated func blob(_ oid: String, limit: Int) async throws(GitCoreError) -> [UInt8] {
        try Self.requireObjectID(oid)
        return try await runRead(["cat-file", "blob", oid], limit: limit)
    }
}
