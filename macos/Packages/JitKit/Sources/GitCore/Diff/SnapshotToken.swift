import Darwin
import Foundation

/// Exactly which versions of one path a `DiffDocument` shows (design §4.2): HEAD, the index record and
/// the working-tree file (fingerprint plus Git blob id of its raw bytes), and the repository revision.
/// Line actions (P3.4) re-read it inside the write gate and refuse when anything differs.
public struct SnapshotToken: Sendable, Hashable {
    public let path: String
    public let headID: String?
    /// `git ls-files -s -z` record (mode, blob, stage); empty when untracked.
    public let indexEntry: [UInt8]
    public let worktree: WorktreeFingerprint?
    /// `git hash-object --no-filters` of the working-tree bytes (link target for a symlink).
    public let worktreeBlobID: String?
    public let repoRevision: RepoRevision

    /// Equal file state; the revision only says when the token was taken.
    public func sameState(as other: SnapshotToken) -> Bool {
        path == other.path && headID == other.headID && indexEntry == other.indexEntry
            && worktree == other.worktree && worktreeBlobID == other.worktreeBlobID
    }
}

extension RepositoryHandle {
    /// Reads the token for `path` (read-only).
    ///
    /// The three Git reads (index record, HEAD, blob id of the working-tree bytes) are independent and run
    /// concurrently (P6.4: diff switch spent most of its time in seven sequential Git processes). The
    /// working-tree fingerprint is read once, before the content that is hashed.
    public func snapshotToken(for path: String) async throws(GitCoreError) -> SnapshotToken {
        let topLevel = try requireWorkingTree()
        let engine = gitEngine
        let url = URL(fileURLWithPath: topLevel).appendingPathComponent(path)
        let fingerprint = try Fingerprint.read(url.path)
        let content = fingerprint.flatMap { Self.worktreeContent(url, type: $0.type) }
        async let index = Self.capture { () async throws(GitCoreError) in
            try await Self.readIndexEntry(path, engine: engine, topLevel: topLevel)
        }
        async let head = Self.capture { () async throws(GitCoreError) in
            try await Self.readHead(engine: engine, in: topLevel)
        }
        async let blob = Self.capture { () async throws(GitCoreError) -> String? in
            guard let content else { return nil }
            return try await Self.hashObject(content, engine: engine, in: topLevel)
        }
        // One fingerprint per token (read before the content): a change after it shows up as a different
        // fingerprint or blob in the token taken after the diff, and the read is repeated.
        return SnapshotToken(
            path: path, headID: try await head.get(), indexEntry: try await index.get(), worktree: fingerprint,
            worktreeBlobID: try await blob.get(), repoRevision: repoRevision)
    }

    private static func capture<T: Sendable>(_ body: () async throws(GitCoreError) -> T) async -> Result<
        T, GitCoreError
    > {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    static func readHead(engine: GitEngine, in directory: String) async throws(GitCoreError) -> String? {
        do {
            let output = try await engine.run(
                GitCommand(
                    ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"], in: directory,
                    kind: .read, stdoutLimit: 256, acceptedExitCodes: [0, 1]))
            let text = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
    }

    /// Raw bytes Git would store for the path: file contents, or a symlink's target. `nil` otherwise.
    static func worktreeContent(_ url: URL, type: UInt16) -> [UInt8]? {
        switch type {
        case UInt16(S_IFREG):
            return (try? Data(contentsOf: url)).map { Array($0) }
        case UInt16(S_IFLNK):
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map { Array($0.utf8) }
        default:
            return nil
        }
    }

    static func hashObject(_ content: [UInt8], engine: GitEngine, in directory: String) async throws(GitCoreError)
        -> String
    {
        do {
            let output = try await engine.run(
                GitCommand(
                    ["hash-object", "--no-filters", "--stdin"], in: directory, kind: .read, stdoutLimit: 256,
                    stdin: content))
            return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
    }
}

// MARK: - Opening diffs

extension RepositoryHandle {
    /// Reads, parses and lays out a diff (ADR-0026). Working-tree path targets carry a `SnapshotToken`
    /// taken before and after Git ran; if the file changed meanwhile the read is repeated (up to three
    /// times), so the token always describes exactly what the document shows.
    public func openDiff(_ target: DiffTarget, options: DiffOptions = DiffOptions()) async throws(GitCoreError)
        -> DiffDocument
    {
        let topLevel = try requireWorkingTreeOrBare()
        let format = try await objectFormat()
        let engine = gitEngine
        switch target {
        case .unstaged(let path), .staged(let path, _):
            for _ in 0..<3 {
                if Task.isCancelled { throw .cancelled }
                let before = try await snapshotToken(for: path)
                let bytes: [UInt8]
                if case .unstaged = target, before.indexEntry.isEmpty, before.worktree != nil {
                    bytes = try Self.untrackedPatch(path: path, topLevel: topLevel, token: before, format: format)
                } else {
                    bytes = try await Self.runDiff(
                        DiffInvocation.arguments(target, options: options, format: format), engine: engine, in: topLevel
                    )
                }
                let after = try await snapshotToken(for: path)
                guard before.sameState(as: after) else { continue }
                return DiffDocument(
                    storage: try PatchParser.parse(bytes), target: target, options: options, token: after)
            }
            throw .staleSnapshot(summary: "“\(path)” kept changing while Jit read it. Try again when it settles.")
        case .commit(let oid, _):
            let parent = try await Self.firstParent(of: oid, format: format, engine: engine, in: topLevel)
            let arguments = DiffInvocation.arguments(target, options: options, format: format, firstParent: parent)
            let bytes = try await Self.runDiff(arguments, engine: engine, in: topLevel)
            return DiffDocument(storage: try PatchParser.parse(bytes), target: target, options: options)
        case .commits, .commitToWorktree:
            let bytes = try await Self.runDiff(
                DiffInvocation.arguments(target, options: options, format: format), engine: engine, in: topLevel)
            return DiffDocument(storage: try PatchParser.parse(bytes), target: target, options: options)
        }
    }

    func requireWorkingTreeOrBare() throws(GitCoreError) -> String { info.topLevel ?? info.gitDirectory }

    static func runDiff(_ arguments: [String], engine: GitEngine, in directory: String) async throws(GitCoreError)
        -> [UInt8]
    {
        do {
            return try await engine.run(
                GitCommand(
                    arguments, in: directory, kind: .read, timeout: .seconds(120), stdoutLimit: 256 * 1024 * 1024)
            ).stdout
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
    }

    static func firstParent(of oid: ObjectID, format: ObjectFormat, engine: GitEngine, in directory: String)
        async throws(GitCoreError) -> ObjectID?
    {
        do {
            let output = try await engine.run(
                GitCommand(
                    ["rev-parse", "--verify", "--quiet", "--end-of-options", oid.hex(format) + "^1"], in: directory,
                    kind: .read, stdoutLimit: 256, acceptedExitCodes: [0, 1]))
            return ObjectID(hex: output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
    }

    /// A new-file patch built from the raw bytes, in Git's own format (no `git add -N`: that would change
    /// the index as a side effect).
    static func untrackedPatch(path: String, topLevel: String, token: SnapshotToken, format: ObjectFormat)
        throws(GitCoreError)
        -> [UInt8]
    {
        guard let worktree = token.worktree else { return [] }
        let url = URL(fileURLWithPath: topLevel).appendingPathComponent(path)
        guard let content = worktreeContent(url, type: worktree.type) else {
            throw .io(summary: "“\(path)” is not a regular file or symbolic link.")
        }
        let mode: String
        if worktree.type == UInt16(S_IFLNK) {
            mode = "120000"
        } else {
            var info = stat()
            mode = lstat(url.path, &info) == 0 && info.st_mode & 0o100 != 0 ? "100755" : "100644"
        }
        let zero = String(repeating: "0", count: format.byteCount * 2)
        let a = quoted("a/" + path)
        let b = quoted("b/" + path)
        var out = Array(
            "diff --git \(a) \(b)\nnew file mode \(mode)\nindex \(zero)..\(token.worktreeBlobID ?? zero)\n".utf8)
        if content.isEmpty { return out }
        if content.prefix(8000).contains(0) {
            out += Array("Binary files /dev/null and \(b) differ\n".utf8)
            return out
        }
        var lines = content.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let endsWithNewline = content.last == UInt8(ascii: "\n")
        if endsWithNewline { lines.removeLast() }
        // Git ends an unquoted name containing a space with a tab (for GNU patch).
        let tab = b.first != "\"" && b.contains(" ") ? "\t" : ""
        out += Array("--- /dev/null\n+++ \(b)\(tab)\n@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@\n".utf8)
        for (index, line) in lines.enumerated() {
            out.append(UInt8(ascii: "+"))
            out += line
            out.append(UInt8(ascii: "\n"))
            if index == lines.count - 1, !endsWithNewline { out += Array("\\ No newline at end of file\n".utf8) }
        }
        return out
    }

    /// Git's path quoting with `core.quotePath=off`: quote only for `"`, `\` and control bytes.
    static func quoted(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard bytes.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || $0 == 0x7F }) else { return path }
        var out: [UInt8] = [UInt8(ascii: "\"")]
        for byte in bytes {
            switch byte {
            case 7: out += Array("\\a".utf8)
            case 8: out += Array("\\b".utf8)
            case 9: out += Array("\\t".utf8)
            case 10: out += Array("\\n".utf8)
            case 11: out += Array("\\v".utf8)
            case 12: out += Array("\\f".utf8)
            case 13: out += Array("\\r".utf8)
            case 0x22: out += Array("\\\"".utf8)
            case 0x5C: out += Array("\\\\".utf8)
            case 0..<0x20, 0x7F: out += Array(String(format: "\\%03o", byte).utf8)
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
        return String(decoding: out, as: UTF8.self)
    }
}
