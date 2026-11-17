import Darwin
import Foundation

public enum ReflogAction: String, Sendable, CaseIterable {
    case commit, amend, checkout, reset, merge, rebase, pull, branch, other

    public var title: String { rawValue.capitalized }

    init(message: String) {
        if message.hasPrefix("commit (amend):") {
            self = .amend
        } else if message.hasPrefix("commit") {
            self = .commit
        } else if message.hasPrefix("checkout:") {
            self = .checkout
        } else if message.hasPrefix("reset:") {
            self = .reset
        } else if message.hasPrefix("merge") {
            self = .merge
        } else if message.hasPrefix("rebase") {
            self = .rebase
        } else if message.hasPrefix("pull") {
            self = .pull
        } else if message.hasPrefix("branch:") {
            self = .branch
        } else {
            self = .other
        }
    }
}

public struct ReflogEntry: Sendable, Identifiable, Equatable {
    public let oid: ObjectID
    public let selector: String
    public let message: String
    /// The reflog event's time (which can differ from the commit's timestamp).
    public let timestamp: Int64
    public let action: ReflogAction
    public var isUnreachable: Bool
    public var id: String { selector }
}

public struct ReflogCursor: Sendable, Equatable {
    public let ref: String
    public let offset: Int
    let stamp: ReflogStamp
    let state: RepoStateToken
}

public struct ReflogPage: Sendable {
    public let entries: [ReflogEntry]
    public let next: ReflogCursor?
    public let state: RepoStateToken
}

struct ReflogStamp: Sendable, Equatable {
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64

    @concurrent static func read(_ path: String) async throws(GitCoreError) -> Self? {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw .permissionDenied(path: path)
        }
        return Self(
            inode: UInt64(value.st_ino), size: value.st_size,
            seconds: Int64(value.st_mtimespec.tv_sec), nanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
}

extension RepositoryHandle {
    /// Exact HEAD/local-branch reflog, with bounded page-only reachability checks. A changed log or ref
    /// snapshot invalidates the cursor. The caller may refresh; it must never silently append stale rows.
    public func reflogPage(ref: String = "HEAD", cursor: ReflogCursor? = nil, limit: Int = 50)
        async throws(GitCoreError) -> ReflogPage
    {
        guard (1...50).contains(limit), cursor == nil || cursor?.ref == ref else {
            throw .refused(summary: "Choose a reflog page size between 1 and 50 and use its matching cursor.")
        }
        if ref != "HEAD" {
            guard ref.hasPrefix("refs/heads/") else { throw .refused(summary: "Choose HEAD or a local branch.") }
            try await requireValidBranchRef(String(ref.dropFirst("refs/heads/".count)))
            guard try await Self.readRef(engine: gitEngine, in: workingDirectory, ref) != nil else {
                throw .refused(summary: "This local branch no longer exists. Refresh the reflog.")
            }
        }
        let state = try await captureState()
        let rawPath = try await runRead(["rev-parse", "--git-path", "logs/\(ref)"], limit: 64 * 1024)
        let logPath = String(decoding: rawPath, as: UTF8.self).trimmingCharacters(in: .newlines)
        let absolute = logPath.hasPrefix("/") ? logPath : workingDirectory + "/" + logPath
        let stamp = try await ReflogStamp.read(absolute)
        if let cursor, cursor.state != state || cursor.stamp != stamp {
            throw .staleSnapshot(summary: "The reflog changed. Refresh to read the latest entries.")
        }
        guard let stamp else { return ReflogPage(entries: [], next: nil, state: state) }
        let offset = cursor?.offset ?? 0
        // %gD with --date=raw carries the EVENT time. %ct is the commit's time and is incorrect here.
        let bytes = try await runRead(
            ReadOnlyPolicy.configOverrides + [
                "reflog", "show", "--no-color", "--no-decorate", "--no-show-signature", "--date=raw", "-z",
                "--format=%H%x00%gD%x00%gs", "--skip=\(offset)", "-n", "\(limit + 1)", "--end-of-options", ref, "--",
            ], limit: 8 * 1024 * 1024)
        var entries = try ReflogParser.parse(bytes, ref: ref, offset: offset)
        let hasMore = entries.count > limit
        if hasMore { entries.removeLast() }
        let format = try await objectFormat()
        let reachability = try await pageReachability(Set(entries.map(\.oid)), head: state.head, format: format)
        for index in entries.indices { entries[index].isUnreachable = reachability[entries[index].oid] != true }
        guard try await ReflogStamp.read(absolute) == stamp, try await captureState() == state else {
            throw .staleSnapshot(summary: "The repository changed while reading its reflog. Refresh and try again.")
        }
        let next = hasMore ? ReflogCursor(ref: ref, offset: offset + entries.count, stamp: stamp, state: state) : nil
        return ReflogPage(entries: entries, next: next, state: state)
    }

    /// Four in flight at most: bounded process/memory pressure, with no per-commit serial spawn delay.
    private nonisolated func pageReachability(_ ids: Set<ObjectID>, head: String?, format: ObjectFormat)
        async throws(GitCoreError) -> [ObjectID: Bool]
    {
        // One exact reachability proof for the common case: if HEAD is the only independent tip
        // among HEAD and this page, every page commit is its ancestor. With multiple independent
        // tips we cannot infer which older entries belong to which history, so check them separately.
        if let head, !ids.isEmpty {
            let independent = try await runRead(
                ["merge-base", "--independent", head] + ids.map { $0.hex(format) },
                limit: 64 * 1024)
            let roots = independent.split(separator: 0x0A)
            if roots.count == 1, roots[0].elementsEqual(head.utf8) {
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, true) })
            }
        }
        do {
            return try await withThrowingTaskGroup(of: (ObjectID, Bool).self) { group in
                var iterator = ids.makeIterator()
                func enqueue(_ oid: ObjectID) {
                    group.addTask { (oid, try await self.commitIsReachable(oid, head: head, format: format)) }
                }
                for _ in 0..<4 { if let oid = iterator.next() { enqueue(oid) } }
                var result: [ObjectID: Bool] = [:]
                while let (oid, reachable) = try await group.next() {
                    result[oid] = reachable
                    if let next = iterator.next() { enqueue(next) }
                }
                return result
            }
        } catch let error as GitCoreError { throw error } catch {
            throw .internalError(summary: "Couldn't check reflog reachability.")
        }
    }

    private nonisolated func commitIsReachable(_ oid: ObjectID, head: String?, format: ObjectFormat)
        async throws(GitCoreError) -> Bool
    {
        let hex = oid.hex(format)
        // HEAD's ancestry answers most entries without scanning hundreds of refs. This also keeps
        // detached HEAD commits reachable. Fall back to ref containment only for the remaining OIDs.
        if let head {
            if head == hex { return true }
            let output = try await gitEngine.run(
                GitCommand(
                    ["merge-base", "--is-ancestor", hex, head],
                    in: workingDirectory, kind: .read, acceptedExitCodes: [0, 1]))
            if output.exitCode == 0 { return true }
        }
        let refs = try await runRead(
            ["for-each-ref", "--count=1", "--format=%(refname)", "--contains=\(hex)"], limit: 64 * 1024)
        return !refs.isEmpty
    }
}

enum ReflogParser {
    static func parse(_ bytes: [UInt8], ref: String, offset: Int) throws(GitCoreError) -> [ReflogEntry] {
        guard !bytes.isEmpty else { return [] }
        var fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 3 == 0 else { throw .internalError(summary: "Git returned an incomplete reflog page.") }
        var result: [ReflogEntry] = []
        for index in stride(from: 0, to: fields.count, by: 3) {
            guard let oid = ObjectID(hex: fields[index]) else {
                throw .internalError(summary: "Git returned an invalid reflog commit.")
            }
            let datedSelector = String(decoding: fields[index + 1], as: UTF8.self)
            guard let start = datedSelector.range(of: "@{", options: .backwards),
                let seconds = datedSelector[start.upperBound...].split(separator: " ").first,
                let timestamp = Int64(seconds)
            else { throw .internalError(summary: "Git returned an invalid reflog event date.") }
            let message = String(decoding: fields[index + 2], as: UTF8.self)
            result.append(
                ReflogEntry(
                    oid: oid, selector: "\(ref)@{\(offset + result.count)}", message: message,
                    timestamp: timestamp, action: ReflogAction(message: message), isUnreachable: false))
        }
        return result
    }
}
