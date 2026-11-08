import Darwin
import Foundation
import os

let persistenceLog = Logger(subsystem: "jit.app", category: "persistence")

/// Where Jit keeps its small JSON files: `~/Library/Application Support/Jit` (`0700`).
public struct StoreLocation: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The real location. `JIT_APP_SUPPORT=<dir>` (set by tests, screenshot and benchmark scripts)
    /// points it elsewhere so they never touch the user's own state; release benchmarks need it too.
    public static func applicationSupport() -> StoreLocation {
        if let override = ProcessInfo.processInfo.environment["JIT_APP_SUPPORT"], !override.isEmpty {
            return StoreLocation(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        return StoreLocation(directory: base.appendingPathComponent("Jit", isDirectory: true))
    }

    public func url(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    func ensureDirectory() throws {
        let path = directory.path
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// Versioned JSON files: atomic `0600` writes, corrupt or unknown-version files backed up and reset.
public enum JSONFile {
    public enum LoadOutcome<Value> {
        case loaded(Value)
        case missing
        /// The file was unreadable or from an unknown version; it was moved to `backup`.
        case reset(backup: URL?)

        public var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    private struct VersionProbe: Decodable {
        let version: Int?
    }

    public static func load<Value: Decodable>(
        _ type: Value.Type, at url: URL, version: Int
    ) -> LoadOutcome<Value> {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .missing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let probe = try? decoder.decode(VersionProbe.self, from: data), probe.version == version,
            let value = try? decoder.decode(Value.self, from: data)
        {
            return .loaded(value)
        }
        return .reset(backup: backUp(url))
    }

    /// Moves an unusable file aside as `<name>.bak-<timestamp>` so nothing is silently lost.
    static func backUp(_ url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = URL(fileURLWithPath: url.path + ".bak-" + formatter.string(from: Date()))
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            persistenceLog.error("Unreadable \(url.lastPathComponent, privacy: .public); backed up and reset")
            return backup
        } catch {
            return nil
        }
    }

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// Writes `data` to a new `0600` temporary file in the same directory and renames it over `url`, so
    /// readers see the old or the new file, never a partial one.
    public static func write(_ data: Data, to url: URL) throws {
        try StoreLocation(directory: url.deletingLastPathComponent()).ensureDirectory()
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var ok = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    ok = false
                    return
                }
                offset += written
            }
        }
        if ok, fsync(descriptor) != 0 { ok = false }
        close(descriptor)
        guard ok, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Coalesces bursts of changes into one write, 500 ms after the last change, using a single cancellable
/// one-shot task (never a repeating timer). Encoding happens on the main actor (small values); the
/// file write happens off it. `flush()` writes synchronously (app termination).
@MainActor
public final class DebouncedWriter {
    public let url: URL
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var makeData: (@MainActor () -> Data?)?

    public init(url: URL, delay: Duration = .milliseconds(500)) {
        self.url = url
        self.delay = delay
    }

    public var hasPendingWrite: Bool { makeData != nil }

    public func schedule(_ makeData: @escaping @MainActor () -> Data?) {
        self.makeData = makeData
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let data = self.makeData?()
            self.makeData = nil
            self.pending = nil
            if let data { await Self.write(data, to: self.url) }
        }
    }

    public func flush() {
        pending?.cancel()
        pending = nil
        guard let data = makeData?() else { return }
        makeData = nil
        do {
            try JSONFile.write(data, to: url)
        } catch {
            persistenceLog.error("Failed to write \(self.url.lastPathComponent, privacy: .public)")
        }
    }

    @concurrent
    private static func write(_ data: Data, to url: URL) async {
        do {
            try JSONFile.write(data, to: url)
        } catch {
            persistenceLog.error("Failed to write \(url.lastPathComponent, privacy: .public)")
        }
    }
}
