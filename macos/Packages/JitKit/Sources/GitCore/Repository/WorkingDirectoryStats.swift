import Foundation

/// Added/removed line counts of one changed file. Both `nil` for binary files (`-` in `--numstat`).
public struct LineStats: Sendable, Equatable {
    public var additions: Int?
    public var deletions: Int?

    public init(additions: Int?, deletions: Int?) {
        self.additions = additions
        self.deletions = deletions
    }

    public var isBinary: Bool { additions == nil || deletions == nil }
    /// Lines touched, for "Size of change" sorting; binary counts as zero.
    public var total: Int { (additions ?? 0) + (deletions ?? 0) }
}

extension RepositoryHandle {
    /// Line counts for working-directory paths (P3.1 "lazy numstat for visible paths"): `staged` compares
    /// HEAD (the empty tree on an unborn branch) with the index, otherwise the index with the working tree.
    /// Untracked files are not part of either diff and are absent from the result. Keyed by the (new)
    /// path; a staged rename is reported under its new path when both of its paths are passed. Read-only:
    /// never takes the write gate.
    public func lineStats(staged: Bool, paths: [String]) async throws(GitCoreError) -> [String: LineStats] {
        guard let topLevel = info.topLevel, !paths.isEmpty else { return [:] }
        var result: [String: LineStats] = [:]
        // `git diff` has no `--pathspec-from-file`; visible rows are few, so argv stays small. Chunked so a
        // huge selection can never exceed ARG_MAX.
        var start = 0
        while start < paths.count {
            if Task.isCancelled { throw .cancelled }
            let chunk = Array(paths[start..<min(start + 256, paths.count)])
            start += chunk.count
            var arguments =
                ReadOnlyPolicy.configOverrides + [
                    "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "-z", "--numstat",
                ]
            if staged { arguments += ["--cached", "-M"] }
            arguments += ["--"] + chunk
            let output: [UInt8]
            do {
                output = try await gitEngine.run(
                    GitCommand(
                        arguments, in: topLevel, kind: .read, timeout: .seconds(120), stdoutLimit: 64 * 1024 * 1024)
                ).stdout
            } catch {
                throw RepositoryDiscovery.classify(error, path: topLevel)
            }
            result.merge(try NumstatParser.parse(output)) { _, new in new }
        }
        return result
    }
}

/// `git diff --numstat -z`: `adds\tdels\tpath\0`, or for renames `adds\tdels\t\0old\0new\0`. Binary files
/// report `-\t-`.
enum NumstatParser {
    static func parse(_ bytes: [UInt8]) throws(GitCoreError) -> [String: LineStats] {
        var result: [String: LineStats] = [:]
        var index = 0
        func field(until terminator: UInt8) throws(GitCoreError) -> ArraySlice<UInt8> {
            guard let end = bytes[index...].firstIndex(of: terminator) else {
                throw .internalError(summary: "Unexpected `git diff --numstat` output")
            }
            defer { index = end + 1 }
            return bytes[index..<end]
        }
        func count(_ slice: ArraySlice<UInt8>) -> Int? {
            slice.elementsEqual("-".utf8) ? nil : Int(String(decoding: slice, as: UTF8.self))
        }
        while index < bytes.count {
            let additions = count(try field(until: UInt8(ascii: "\t")))
            let deletions = count(try field(until: UInt8(ascii: "\t")))
            var path = try field(until: 0)
            if path.isEmpty {
                _ = try field(until: 0)  // rename source
                path = try field(until: 0)
            }
            result[String(decoding: path, as: UTF8.self)] = LineStats(additions: additions, deletions: deletions)
        }
        return result
    }
}
