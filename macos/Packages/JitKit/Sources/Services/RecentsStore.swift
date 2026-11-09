import Foundation
import GitCore
import Observation

/// Recently opened repositories (`recents.json`), newest first, at most 20, de-duplicated by
/// resolved path.
@MainActor @Observable
public final class RecentsStore {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var path: String
        public var name: String
        public var lastOpened: Date
        public var lastBranch: String?

        public var id: String { path }

        public init(path: String, name: String, lastOpened: Date, lastBranch: String? = nil) {
            self.path = path
            self.name = name
            self.lastOpened = lastOpened
            self.lastBranch = lastBranch
        }
    }

    private struct File: Codable {
        var version = RecentsStore.fileVersion
        var entries: [Entry]
    }

    nonisolated static let fileVersion = 1
    public static let capacity = CacheLimits.recentRepositories

    public private(set) var entries: [Entry] = []
    /// Paths that no longer exist (checked off the main actor by `refreshMissing()`).
    public private(set) var missingPaths: Set<String> = []

    @ObservationIgnored private let writer: DebouncedWriter

    public init(location: StoreLocation = .applicationSupport(), fileName: String = "recents.json") {
        let url = location.url(fileName)
        writer = DebouncedWriter(url: url)
        entries = JSONFile.load(File.self, at: url, version: Self.fileVersion).value?.entries ?? []
    }

    /// Records an opened repository (moves it to the front).
    public func noteOpened(path: String, name: String, branch: String?, at date: Date = Date()) {
        let key = Self.resolvedPath(path)
        entries.removeAll { Self.resolvedPath($0.path) == key }
        entries.insert(Entry(path: path, name: name, lastOpened: date, lastBranch: branch), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        missingPaths.remove(path)
        save()
    }

    /// Updates the remembered branch without reordering.
    public func updateBranch(path: String, branch: String?) {
        guard let index = entries.firstIndex(where: { $0.path == path }), entries[index].lastBranch != branch else {
            return
        }
        entries[index].lastBranch = branch
        save()
    }

    /// Removes an entry; returns it with its position for undo.
    @discardableResult
    public func remove(path: String) -> (entry: Entry, index: Int)? {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return nil }
        let entry = entries.remove(at: index)
        missingPaths.remove(path)
        save()
        return (entry, index)
    }

    /// Undo of `remove(path:)`.
    public func restore(_ entry: Entry, at index: Int) {
        guard !entries.contains(where: { $0.path == entry.path }) else { return }
        entries.insert(entry, at: min(index, entries.count))
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        save()
    }

    /// Replaces a missing entry's location (Locate…).
    public func relocate(path: String, to newPath: String, name: String) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].path = newPath
        entries[index].name = name
        missingPaths.remove(path)
        save()
    }

    public func clear() {
        entries.removeAll()
        missingPaths.removeAll()
        save()
    }

    /// Checks which entries no longer exist. File-system calls run off the main actor so a slow or
    /// unreachable volume never blocks the UI.
    public func refreshMissing() async {
        let paths = entries.map(\.path)
        let missing = await Self.missing(paths)
        missingPaths = missing.intersection(entries.map(\.path))
    }

    @concurrent
    private static func missing(_ paths: [String]) async -> Set<String> {
        Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
    }

    public func flush() { writer.flush() }

    private func save() {
        writer.schedule { [weak self] in
            guard let self else { return nil }
            return try? JSONFile.encode(File(entries: self.entries))
        }
    }

    /// Symlinks resolved and Unicode-normalized; the path itself if it doesn't exist.
    nonisolated public static func resolvedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else {
            return standardized.precomposedStringWithCanonicalMapping
        }
        defer { free(resolved) }
        return String(cString: resolved).precomposedStringWithCanonicalMapping
    }
}
