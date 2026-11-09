import Darwin
import Foundation

/// What a file looked like when the user chose to discard it (design §4.2 snapshot token, file-level
/// form). `discard` re-reads it inside the write gate and refuses if anything differs, so a file edited
/// after the confirmation sheet opened is never thrown away.
public struct DiscardToken: Sendable, Hashable {
    public let path: String
    /// `git ls-files -s -z` record for the path (mode, blob, stage); empty when untracked.
    public let indexEntry: [UInt8]
    /// `nil` when nothing exists at the path in the working tree.
    public let worktree: WorktreeFingerprint?

    public var isUntracked: Bool { indexEntry.isEmpty }
}

/// File type, size, inode, modification time and a content hash (FNV-1a 64 over the bytes, or over the
/// entry list for a directory, or the link target for a symlink).
public struct WorktreeFingerprint: Sendable, Hashable {
    public let type: UInt16
    public let size: Int64
    public let inode: UInt64
    public let modifiedNanoseconds: Int64
    public let contentHash: UInt64
}

public struct DiscardItem: Sendable, Hashable {
    public let token: DiscardToken
    public init(token: DiscardToken) { self.token = token }
    public var path: String { token.path }
}

/// Side effects that belong to the app, run inside the write gate in this order: `preserve` for every
/// tracked file that exists, then `trash` for untracked paths, then Git restores tracked files.
public struct DiscardHooks: Sendable {
    /// Copies the current working-tree file aside; returns a recovery identifier. Throwing stops the
    /// discard before anything was changed.
    public var preserve: @Sendable (_ path: String, _ url: URL) throws -> String
    /// Moves an untracked file or directory to the Trash.
    public var trash: @Sendable (_ url: URL) throws -> Void

    public init(
        preserve: @escaping @Sendable (_ path: String, _ url: URL) throws -> String,
        trash: @escaping @Sendable (_ url: URL) throws -> Void
    ) {
        self.preserve = preserve
        self.trash = trash
    }
}

public struct DiscardOutcome: Sendable, Equatable {
    public var revision: RepoRevision
    /// Recovery identifier per tracked path that had a working-tree file.
    public var recovered: [String: String]
    public var trashed: [String]
}

/// Lines a discard would throw away, for the confirmation sheet's preview (design §3.2).
public struct DiscardPreview: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case removed, restored }
    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String
    }

    public var lines: [Line]
    /// Lines the working tree loses (`+` lines of the unstaged diff, or every line of an untracked file).
    public var removedCount: Int
    /// Lines that come back from the index (`-` lines of the unstaged diff).
    public var restoredCount: Int
    public var isBinary: Bool
    /// More lines exist than `lines` shows.
    public var isTruncated: Bool
}

extension RepositoryHandle {
    // MARK: Token

    /// Reads the current state of `path` for a later `discard`. Read-only.
    public func discardToken(for path: String) async throws(GitCoreError) -> DiscardToken {
        let topLevel = try requireWorkingTree()
        return try await Self.readToken(path, engine: gitEngine, topLevel: topLevel)
    }

    static func readToken(_ path: String, engine: GitEngine, topLevel: String) async throws(GitCoreError)
        -> DiscardToken
    {
        let output: [UInt8]
        do {
            output = try await engine.run(
                GitCommand(
                    ["--literal-pathspecs", "ls-files", "-s", "-z", "--", path], in: topLevel, kind: .read,
                    timeout: .seconds(60), stdoutLimit: 16 * 1024 * 1024)
            ).stdout
        } catch {
            throw RepositoryDiscovery.classify(error, path: topLevel)
        }
        let url = URL(fileURLWithPath: topLevel).appendingPathComponent(path)
        return DiscardToken(path: path, indexEntry: output, worktree: try Fingerprint.read(url.path))
    }

    // MARK: Preview

    /// The first `limit` lines a discard of `token.path` would remove or restore.
    public func discardPreview(for token: DiscardToken, limit: Int = 20) async throws(GitCoreError)
        -> DiscardPreview
    {
        let topLevel = try requireWorkingTree()
        let url = URL(fileURLWithPath: topLevel).appendingPathComponent(token.path)
        if token.isUntracked {
            return Self.untrackedPreview(url, limit: limit)
        }
        let output: [UInt8]
        do {
            output = try await gitEngine.run(
                GitCommand(
                    ReadOnlyPolicy.configOverrides + [
                        "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "-U0", "--",
                        token.path,
                    ], in: topLevel, kind: .read, timeout: .seconds(60), stdoutLimit: 64 * 1024 * 1024)
            ).stdout
        } catch {
            throw RepositoryDiscovery.classify(error, path: topLevel)
        }
        var preview = DiscardPreview(lines: [], removedCount: 0, restoredCount: 0, isBinary: false, isTruncated: false)
        var inHunk = false
        for line in output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if line.starts(with: "@@".utf8) {
                inHunk = true
                continue
            }
            if line.starts(with: "diff --git".utf8) { inHunk = false }
            if !inHunk {
                if line.starts(with: "Binary files".utf8) || line.starts(with: "GIT binary patch".utf8) {
                    preview.isBinary = true
                }
                continue
            }
            guard let first = line.first else { continue }
            let kind: DiscardPreview.Kind
            switch first {
            case UInt8(ascii: "+"):
                kind = .removed
                preview.removedCount += 1
            case UInt8(ascii: "-"):
                kind = .restored
                preview.restoredCount += 1
            default:
                continue
            }
            if preview.lines.count < limit {
                preview.lines.append(.init(kind: kind, text: String(decoding: line.dropFirst(), as: UTF8.self)))
            } else {
                preview.isTruncated = true
            }
        }
        return preview
    }

    static func untrackedPreview(_ url: URL, limit: Int) -> DiscardPreview {
        var preview = DiscardPreview(lines: [], removedCount: 0, restoredCount: 0, isBinary: false, isTruncated: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return preview }
        defer { try? handle.close() }
        // At most 1 MB is read: enough for the count of most source files; larger files say "truncated".
        let data = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
        if data.prefix(8000).contains(0) {
            preview.isBinary = true
            return preview
        }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        preview.removedCount = lines.count
        preview.isTruncated = lines.count > limit || data.count == 1024 * 1024
        preview.lines = lines.prefix(limit).map { .init(kind: .removed, text: String(decoding: $0, as: UTF8.self)) }
        return preview
    }

    // MARK: Discard

    /// Throws away working-tree changes of whole files (P3.2, ADR-0025). Staged changes are kept: tracked
    /// files are restored from the index (`git restore --worktree`) after `hooks.preserve` copied them
    /// aside; untracked paths go to the Trash through `hooks.trash`. Every token is re-checked first, inside
    /// the write gate; if any differs nothing is changed and `.staleSnapshot` is thrown.
    public func discard(_ items: [DiscardItem], hooks: DiscardHooks) async throws(GitCoreError) -> DiscardOutcome {
        let topLevel = try requireWorkingTree()
        guard !items.isEmpty else { return DiscardOutcome(revision: repoRevision, recovered: [:], trashed: []) }
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let paths = items.map(\.path)
        let result = try await performExclusive("Discard \(Self.describe(paths))") {
            () throws(GitCoreError) -> ([String: String], [String]) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            for item in items {
                let current = try await Self.readToken(item.path, engine: engine, topLevel: topLevel)
                guard current == item.token else {
                    throw .staleSnapshot(
                        summary: "“\(item.path)” changed since you chose to discard it. Nothing was discarded.")
                }
            }
            let root = URL(fileURLWithPath: topLevel)
            let tracked = items.filter { !$0.token.isUntracked }
            let untracked = items.filter { $0.token.isUntracked && $0.token.worktree != nil }
            var recovered: [String: String] = [:]
            for item in tracked where item.token.worktree != nil {
                do {
                    recovered[item.path] = try hooks.preserve(item.path, root.appendingPathComponent(item.path))
                } catch {
                    throw .io(summary: "Couldn’t keep a recovery copy of “\(item.path)”, so nothing was discarded.")
                }
            }
            var trashed: [String] = []
            for item in untracked {
                do {
                    try hooks.trash(root.appendingPathComponent(item.path))
                    trashed.append(item.path)
                } catch {
                    throw .io(summary: "Couldn’t move “\(item.path)” to the Trash.")
                }
            }
            if !tracked.isEmpty {
                try await Self.runPathspecCommand(
                    ["restore", "--worktree"], paths: tracked.map(\.path), engine: engine, in: topLevel,
                    gitDirectory: gitDirectory)
            }
            return (recovered, trashed)
        }
        return DiscardOutcome(revision: repoRevision, recovered: result.0, trashed: result.1)
    }
}

enum Fingerprint {
    static func read(_ path: String) throws(GitCoreError) -> WorktreeFingerprint? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw .io(
                summary:
                    "Couldn’t read “\((path as NSString).lastPathComponent)” (\(String(cString: strerror(errno)))).")
        }
        let type = UInt16(info.st_mode) & UInt16(S_IFMT)
        var hash = StableHash()
        switch type {
        case UInt16(S_IFREG):
            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw .io(summary: "Couldn’t read “\((path as NSString).lastPathComponent)”.")
            }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                chunk.withUnsafeBytes { hash.combine($0) }
            }
        case UInt16(S_IFLNK):
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                hash.combine(target)
            }
        case UInt16(S_IFDIR):
            // Untracked directory: every entry's relative path, type, size and modification time.
            let base = URL(fileURLWithPath: path)
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            let entries = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [])
            var lines: [String] = []
            while let url = entries?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let relative = String(url.path.dropFirst(base.path.count))
                let time = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                lines.append("\(relative)\t\(values?.isDirectory == true)\t\(values?.fileSize ?? -1)\t\(time)")
            }
            for line in lines.sorted() { hash.combine(line + "\n") }
        default:
            break
        }
        return WorktreeFingerprint(
            type: type, size: Int64(info.st_size), inode: UInt64(info.st_ino),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            contentHash: hash.value)
    }
}
