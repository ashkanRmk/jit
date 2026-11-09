import Foundation
import GitCore
import os

/// Copies of files Jit discarded (ADR-0025): `<App Support>/Jit/Recovery/<repo-id>/<yyyyMMdd-HHmmss>-<n>/`
/// holding `meta.json` and the file as it was. Directories `0700`, files `0600`. Kept 7 days or until
/// the store exceeds 500 MB (oldest first), pruned once at launch — no timer. Restoring is a manual
/// copy in V1.
public struct RecoveryStore: Sendable {
    public struct Meta: Codable, Sendable, Equatable {
        public var version = 1
        public var repository: String
        public var branch: String?
        public var path: String
        public var operation: String
        public var created: Date
        public var bytes: Int64
        public var fileName: String
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { directory.path }
        public let directory: URL
        public let meta: Meta
        /// The preserved copy.
        public var file: URL { directory.appendingPathComponent(meta.fileName) }
    }

    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maxBytes: Int64 = 500 * 1024 * 1024

    public let root: URL

    public init(location: StoreLocation = .applicationSupport()) {
        root = location.directory.appendingPathComponent("Recovery", isDirectory: true)
    }

    private static let log = Logger(subsystem: "jit.app", category: "recovery")

    /// A stable folder name per repository (no path in clear text).
    public static func repositoryID(_ topLevel: String) -> String {
        var hash = StableHash()
        hash.combine(topLevel)
        return String(hash.value, radix: 16)
    }

    /// Copies `url` (file or symlink, as is) into a new entry and writes its metadata. Returns the entry
    /// directory's path, which is the recovery identifier.
    public func preserve(
        _ url: URL, path: String, repository: String, branch: String?, operation: String = "discard",
        now: Date = Date()
    ) throws -> String {
        let fm = FileManager.default
        let repoDirectory = root.appendingPathComponent(Self.repositoryID(repository), isDirectory: true)
        for directory in [root.deletingLastPathComponent(), root, repoDirectory]
        where !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var entry: URL
        var n = 1
        repeat {
            entry = repoDirectory.appendingPathComponent("\(stamp)-\(n)", isDirectory: true)
            n += 1
        } while fm.fileExists(atPath: entry.path)
        try fm.createDirectory(at: entry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fileName = (path as NSString).lastPathComponent
        let copy = entry.appendingPathComponent(fileName)
        do {
            try fm.copyItem(at: url, to: copy)
            let attributes = try fm.attributesOfItem(atPath: copy.path)
            if attributes[.type] as? FileAttributeType != .typeSymbolicLink {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            let meta = Meta(
                repository: repository, branch: branch, path: path, operation: operation, created: now,
                bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0, fileName: fileName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let metaURL = entry.appendingPathComponent("meta.json")
            try encoder.encode(meta).write(to: metaURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
        } catch {
            try? fm.removeItem(at: entry)
            throw error
        }
        return entry.path
    }

    /// Entries, newest first; only `repository`'s when given.
    public func entries(repository: String? = nil) -> [Entry] {
        let fm = FileManager.default
        let repoDirectories: [URL]
        if let repository {
            repoDirectories = [root.appendingPathComponent(Self.repositoryID(repository), isDirectory: true)]
        } else {
            repoDirectories = Self.children(of: root)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [Entry] = []
        for repoDirectory in repoDirectories {
            for entry in Self.children(of: repoDirectory) {
                guard let data = fm.contents(atPath: entry.appendingPathComponent("meta.json").path),
                    let meta = try? decoder.decode(Meta.self, from: data)
                else { continue }
                result.append(Entry(directory: entry, meta: meta))
            }
        }
        return result.sorted { $0.meta.created > $1.meta.created }
    }

    /// Children built from `directory` itself, so paths keep the spelling `preserve` returned (listing
    /// URLs would turn `/var/…` into `/private/var/…`).
    private static func children(of directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            .map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Removes entries older than `maxAge`, then the oldest until the total is under `maxBytes`, then
    /// empty repository folders. Entries without readable metadata are left alone (never guess).
    @discardableResult
    public func prune(now: Date = Date(), maxAge: TimeInterval = maxAge, maxBytes: Int64 = maxBytes) -> Int {
        let fm = FileManager.default
        var removed = 0
        var kept: [Entry] = []
        for entry in entries() {
            if now.timeIntervalSince(entry.meta.created) > maxAge {
                if (try? fm.removeItem(at: entry.directory)) != nil { removed += 1 }
            } else {
                kept.append(entry)
            }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.meta.bytes }
        for entry in kept.reversed() where total > maxBytes {
            if (try? fm.removeItem(at: entry.directory)) != nil {
                removed += 1
                total -= entry.meta.bytes
            }
        }
        for repoDirectory in Self.children(of: root)
        where (try? fm.contentsOfDirectory(atPath: repoDirectory.path))?.isEmpty == true {
            try? fm.removeItem(at: repoDirectory)
        }
        if removed > 0 { Self.log.info("Pruned \(removed, privacy: .public) recovery entries") }
        return removed
    }

    /// Discard side effects for `GitCore`: copies into this store; untracked paths go to the Trash.
    public func discardHooks(repository: String, branch: String?) -> DiscardHooks {
        DiscardHooks(
            preserve: { path, url in
                try self.preserve(url, path: path, repository: repository, branch: branch)
            },
            trash: { url in
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            })
    }
}
