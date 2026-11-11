import Foundation
import Observation

/// A downloaded, verified copy of a newer Jit, waiting to replace the running one.
public struct StagedUpdate: Sendable, Equatable {
    public let version: String
    public let app: URL

    public init(version: String, app: URL) {
        self.version = version
        self.app = app
    }
}

/// Downloads and verifies a release, and swaps it in. The app installs `DiskImageInstaller`; tests use stubs.
public protocol UpdateInstalling: Sendable {
    func stage(_ release: AppRelease) async throws -> StagedUpdate
    func apply(_ staged: StagedUpdate) throws
    /// Removes downloads and staged copies left by an earlier run.
    func cleanUp()
}

/// Updates from Jit's GitHub releases and the change log behind the toolbar bell (ADR-0051).
///
/// Nothing is requested unless a `fetcher` is installed (the app does; tests and tools do not). With
/// "update automatically" off, a request is made only when the user asks. With it on, Jit checks at most once
/// a day — when it starts or becomes the active app, never on a timer — downloads a newer release, and
/// installs it when Jit quits.
@MainActor @Observable
public final class UpdateService {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease)
        /// Downloaded and verified: installed when Jit quits or restarts.
        case ready(AppRelease)
        case failed(String)
    }

    /// The least time between two automatic checks.
    public nonisolated static let automaticInterval: TimeInterval = 86_400

    public private(set) var phase: Phase = .idle
    /// Known releases, newest first (from the last check, kept on disk).
    public private(set) var releases: [AppRelease] = []
    public private(set) var lastChecked: Date?
    public let currentVersion: AppVersion?

    /// Downloads the release list. `nil`: no network at all.
    @ObservationIgnored public var fetcher: (@Sendable (URL) async throws -> Data)?
    /// `nil` in builds that do not replace themselves (development builds).
    @ObservationIgnored public var installer: (any UpdateInstalling)?
    @ObservationIgnored public var isAutomatic: @MainActor () -> Bool = { false }
    /// Quits and reopens Jit (the staged update is applied on the way out); set by the app delegate.
    @ObservationIgnored public var relaunch: (@MainActor () -> Void)?
    @ObservationIgnored public private(set) var staged: StagedUpdate?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let repository: ReleaseFeed.Repository
    @ObservationIgnored private var isLoaded = false
    /// The saved list is read: only then is "when was the last check" known.
    @ObservationIgnored private var didStart = false

    public init(currentVersion: AppVersion?, directory: URL? = nil, repository: ReleaseFeed.Repository = .jit) {
        self.currentVersion = currentVersion
        self.directory = directory
        self.repository = repository
    }

    /// `<Application Support>/Jit/Updates` (or inside `JIT_APP_SUPPORT`).
    public static func defaultDirectory() -> URL {
        StoreLocation.applicationSupport().directory.appendingPathComponent("Updates", isDirectory: true)
    }

    public var releasesPageURL: URL { repository.releasesPageURL }

    /// The newest known release that is newer than the running Jit.
    public var newerRelease: AppRelease? {
        guard let currentVersion else { return nil }
        return releases.first { ($0.parsedVersion ?? currentVersion) > currentVersion }
    }

    /// Whether the bell shows its badge.
    public var hasUpdate: Bool {
        switch phase {
        case .available, .downloading, .ready: true
        case .idle, .checking, .upToDate, .failed: false
        }
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    public func isCurrent(_ release: AppRelease) -> Bool {
        guard let currentVersion, let version = release.parsedVersion else { return false }
        return version == currentVersion
    }

    public func isNewer(_ release: AppRelease) -> Bool {
        guard let currentVersion, let version = release.parsedVersion else { return false }
        return version > currentVersion
    }

    // MARK: - Start

    /// After the first frame: reads the saved release list, removes leftovers of an earlier download, and makes
    /// the automatic check if one is due.
    public func start() async {
        guard !isLoaded else { return }
        isLoaded = true
        let directory = directory
        let installer = installer
        let cache = await Task.detached(priority: .utility) { () -> Cache? in
            installer?.cleanUp()
            guard let directory, let data = try? Data(contentsOf: Self.cacheURL(directory)) else { return nil }
            return try? Self.decoder.decode(Cache.self, from: data)
        }.value
        if let cache, cache.version == Cache.currentVersion, releases.isEmpty {
            releases = cache.releases
            lastChecked = cache.lastChecked
            if phase == .idle, let newer = newerRelease { phase = .available(newer) }
        }
        didStart = true
        checkAutomaticallyIfDue()
    }

    // MARK: - Checking

    /// The user asked: Check for Updates.
    public func check() async {
        await check(userInitiated: true)
    }

    /// Start, app activation and switching the preference on. Does nothing unless "update automatically" is on.
    public func checkAutomaticallyIfDue(now: Date = Date()) {
        guard didStart, isAutomatic(), fetcher != nil, !isBusy else { return }
        if case .ready = phase { return }
        if lastChecked.map({ now.timeIntervalSince($0) >= Self.automaticInterval }) ?? true {
            Task { await check(userInitiated: false) }
        } else if case .available(let release) = phase, installer != nil, release.isInstallable {
            Task { await install(release, relaunchWhenReady: false, userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        guard let fetcher, !isBusy else { return }
        if case .ready = phase { return }
        let before = phase
        phase = .checking
        do {
            let data = try await fetcher(repository.feedURL)
            releases = try ReleaseFeed.parse(data, repository: repository)
            lastChecked = Date()
            save()
            phase = newerRelease.map(Phase.available) ?? .upToDate
        } catch {
            // An automatic check that fails is silent: the next one is due at the next start or activation.
            if userInitiated {
                phase = .failed(Self.message(error))
            } else {
                phase = before
            }
            return
        }
        if !userInitiated, isAutomatic(), case .available(let release) = phase, installer != nil,
            release.isInstallable
        {
            await install(release, relaunchWhenReady: false, userInitiated: false)
        }
    }

    // MARK: - Installing

    /// Downloads and verifies `release`; with `relaunchWhenReady`, restarts Jit into it.
    public func install(_ release: AppRelease, relaunchWhenReady: Bool) async {
        await install(release, relaunchWhenReady: relaunchWhenReady, userInitiated: true)
    }

    private func install(_ release: AppRelease, relaunchWhenReady: Bool, userInitiated: Bool) async {
        guard !isBusy else { return }
        if case .ready = phase {
            if relaunchWhenReady { relaunch?() }
            return
        }
        guard let installer else {
            if userInitiated { phase = .failed(UpdateError.cannotUpdateThisBuild.message) }
            return
        }
        guard release.isInstallable else {
            if userInitiated { phase = .failed(UpdateError.notInstallable.message) }
            return
        }
        phase = .downloading(release)
        do {
            staged = try await installer.stage(release)
            phase = .ready(release)
            if relaunchWhenReady { relaunch?() }
        } catch {
            phase = userInitiated ? .failed(Self.message(error)) : .available(release)
        }
    }

    /// Restart to Update.
    public func relaunchToUpdate() {
        guard staged != nil else { return }
        relaunch?()
    }

    /// Swaps the staged update in. Called once, when Jit is about to exit. Returns whether Jit was replaced.
    @discardableResult
    public func applyStagedUpdate() -> Bool {
        guard let staged, let installer else { return false }
        self.staged = nil
        do {
            try installer.apply(staged)
            return true
        } catch {
            persistenceLog.error("update: applying \(staged.version, privacy: .public) failed")
            return false
        }
    }

    // MARK: - Cache

    private struct Cache: Codable {
        static let currentVersion = 1
        var version = Cache.currentVersion
        let lastChecked: Date?
        let releases: [AppRelease]
    }

    private nonisolated static func cacheURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("releases.json")
    }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func save() {
        guard let directory else { return }
        let cache = Cache(lastChecked: lastChecked, releases: releases)
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(cache) else { return }
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: Self.cacheURL(directory), options: .atomic)
        }
    }

    private nonisolated static func message(_ error: any Error) -> String {
        if let error = error as? UpdateError { return error.message }
        if error is URLError { return UpdateError.offline.message }
        return "The update didn't finish: \(error.localizedDescription)"
    }
}
