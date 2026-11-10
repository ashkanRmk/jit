import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Observation

/// Author pictures from Gravatar (post-v1). An author's picture is looked up once by the SHA-256 of their
/// email address, kept in memory and in a small disk cache, and never asked for again in the same run when
/// the lookup failed. Authors without a picture keep their initials avatar.
///
/// Nothing is fetched unless a `fetcher` is installed (the app does; tests and tools do not) and the
/// preference is on. Only rows on screen ask, so a repository is never crawled; there is no timer and no retry.
@MainActor @Observable
public final class AvatarStore {
    /// Posted on the main thread when a picture arrived (custom-drawn views redraw their visible rows).
    public static let didLoad = Notification.Name("JitAvatarStoreDidLoad")

    public nonisolated static let maxCached = 256
    public nonisolated static let maxConcurrent = 4
    public nonisolated static let pixelSize = 96
    /// How long a disk entry (a picture, or "no picture") is trusted.
    nonisolated static let diskLifetime: TimeInterval = 7 * 86_400

    private enum Entry {
        case loading
        case image(CGImage)
        case missing
    }

    /// Bumped with every arrival; SwiftUI views read it to refresh.
    public private(set) var revision = 0

    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var inFlight = 0
    /// Downloads one URL; `nil` data with `true` means "no picture" (HTTP 404), `false` a failure.
    @ObservationIgnored public var fetcher: (@Sendable (URL) async -> (data: Data?, definitive: Bool))?
    @ObservationIgnored public var isEnabled: @MainActor () -> Bool = { true }
    @ObservationIgnored private let cacheDirectory: URL?

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Caches/<bundle id>/avatars`, or a folder inside `JIT_APP_SUPPORT` when that is set.
    public static func defaultCacheDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["JIT_APP_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("avatars")
        }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "jit", isDirectory: true)
            .appendingPathComponent("avatars", isDirectory: true)
    }

    /// Gravatar's key for an address: SHA-256 of the trimmed, lowercased email, in hex.
    public nonisolated static func hash(email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func url(email: String, pixels: Int = pixelSize) -> URL? {
        URL(string: "https://gravatar.com/avatar/\(hash(email: email))?s=\(pixels)&d=404")
    }

    /// The author's picture if it is known. Unknown authors are looked up in the background; `didLoad` and
    /// `revision` announce the arrival.
    public func image(for email: String) -> CGImage? {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.contains("@") else { return nil }
        switch entries[key] {
        case .image(let image): return image
        case .loading, .missing: return nil
        case nil: break
        }
        guard fetcher != nil, isEnabled() else { return nil }
        if entries.count >= Self.maxCached {
            // Keep lookups in flight; everything else can be read again from the disk cache.
            entries = entries.filter { if case .loading = $0.value { true } else { false } }
        }
        entries[key] = .loading
        queue.append(key)
        pump()
        return nil
    }

    /// Forgets everything in memory (the preference was switched off).
    public func reset() {
        entries = entries.filter { if case .loading = $0.value { true } else { false } }
        revision += 1
        NotificationCenter.default.post(name: Self.didLoad, object: self)
    }

    private func pump() {
        while inFlight < Self.maxConcurrent, !queue.isEmpty, let fetcher {
            let key = queue.removeFirst()
            inFlight += 1
            let directory = cacheDirectory
            Task.detached(priority: .utility) { [weak self] in
                let result = await Self.load(key: key, directory: directory, fetcher: fetcher)
                await self?.finish(key: key, result: result)
            }
        }
    }

    private func finish(key: String, result: CGImage??) {
        inFlight -= 1
        switch result {
        case .some(.some(let image)):
            entries[key] = .image(image)
            revision += 1
            NotificationCenter.default.post(name: Self.didLoad, object: self)
        case .some(.none), .none:
            // No picture, or the lookup failed: initials for the rest of this run either way.
            entries[key] = .missing
        }
        pump()
    }

    /// `.some(image)`: a picture; `.some(nil)`: the author has none; `nil`: the lookup failed.
    private nonisolated static func load(
        key: String, directory: URL?, fetcher: @Sendable (URL) async -> (data: Data?, definitive: Bool)
    ) async -> CGImage?? {
        let name = hash(email: key)
        let picture = directory?.appendingPathComponent(name + ".img")
        let missing = directory?.appendingPathComponent(name + ".none")
        if let picture, isFresh(picture), let data = try? Data(contentsOf: picture), let image = decode(data) {
            return .some(image)
        }
        if let missing, isFresh(missing) { return .some(nil) }
        guard let url = url(email: key) else { return nil }
        let (data, definitive) = await fetcher(url)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let data, let image = decode(data) {
            if let picture {
                try? data.write(to: picture, options: .atomic)
                if let missing { try? FileManager.default.removeItem(at: missing) }
            }
            return .some(image)
        }
        guard definitive else { return nil }
        if let missing { try? Data().write(to: missing, options: .atomic) }
        return .some(nil)
    }

    private nonisolated static func isFresh(_ url: URL) -> Bool {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return false }
        return Date().timeIntervalSince(date) < diskLifetime
    }

    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The app's fetcher: one short HTTPS GET without cookies or credentials; 404 means "no picture".
    public nonisolated static let networkFetcher: @Sendable (URL) async -> (data: Data?, definitive: Bool) = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return (nil, false) }
        if http.statusCode == 200, data.count < 1_000_000 { return (data, true) }
        return (nil, http.statusCode == 404)
    }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = maxConcurrent
        return URLSession(configuration: configuration)
    }()
}
