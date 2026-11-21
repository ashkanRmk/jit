import CryptoKit
import Darwin
import Foundation
import Security

/// Verifies the signed release manifest and image digest before mounting, then validates and stages Jit.app.
/// `apply` then swaps the two bundles with one atomic rename.
public struct DiskImageInstaller: UpdateInstalling {
    /// The installed Jit that gets replaced.
    public let target: URL
    public let bundleIdentifier: String
    public let currentVersion: AppVersion
    /// Downloads and the staged copy live here.
    public let directory: URL
    private let signingKey: UpdateSigningKey
    /// The Team ID the new app must be signed with; `nil` for ad-hoc builds (no team to compare).
    public let requiredTeam: String?
    public let fetch: @Sendable (URL) async throws -> Data
    public let download:
        @Sendable (_ from: URL, _ to: URL, _ reportPercent: @escaping @Sendable (Int) -> Void)
            async throws -> Void

    public static let maxImageBytes: UInt64 = 1_000_000_000
    /// The Team ID the running Jit is signed with (`nil`: ad-hoc or development build).
    public static var runningTeam: String? { PeerCodeSignature.ownTeam }

    public init(
        target: URL, bundleIdentifier: String, currentVersion: AppVersion, directory: URL,
        signingKey: UpdateSigningKey,
        requiredTeam: String? = DiskImageInstaller.runningTeam,
        fetch: @escaping @Sendable (URL) async throws -> Data = UpdateNetwork.fetch,
        download: @escaping @Sendable (URL, URL, @escaping @Sendable (Int) -> Void) async throws -> Void =
            UpdateNetwork.download
    ) {
        self.target = target
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.directory = directory
        self.signingKey = signingKey
        self.requiredTeam = requiredTeam
        self.fetch = fetch
        self.download = download
    }

    private var stagingDirectory: URL { directory.appendingPathComponent("staged", isDirectory: true) }

    public func cleanUp() {
        let manager = FileManager.default
        try? manager.removeItem(at: stagingDirectory)
        for item in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "dmg" {
            try? manager.removeItem(at: item)
        }
    }

    public func stage(
        _ release: AppRelease, progress: @escaping @Sendable (UpdateInstallProgress) -> Void = { _ in }
    ) async throws -> StagedUpdate {
        guard let imageURL = release.diskImageURL, let manifestURL = release.manifestURL,
            let signatureURL = release.signatureURL, let version = release.parsedVersion
        else {
            throw UpdateError.notInstallable
        }
        guard version > currentVersion else { throw UpdateError.wrongApplication("it is not newer than this Jit") }
        try checkTargetIsReplaceable()
        let manifest: Data
        let signature: Data
        do {
            manifest = try await fetch(manifestURL)
            signature = try await fetch(signatureURL)
        } catch UpdateError.http(404) {
            throw UpdateError.invalidUpdateSignature
        }
        let expected = try signingKey.verifiedChecksum(manifest: manifest, signature: signature, version: version)
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let image = directory.appendingPathComponent("Jit-\(version).dmg")
        try? manager.removeItem(at: image)
        defer { try? manager.removeItem(at: image) }
        try await download(imageURL, image) { progress(.downloading(percent: $0)) }
        progress(.verifying)

        let staging = stagingDirectory
        let app = try await Task.detached(priority: .utility) { () -> URL in
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: image.path)[.size] as? UInt64) ?? 0
            guard size > 0, size <= Self.maxImageBytes else { throw UpdateError.tooLarge }
            guard try Self.sha256(of: image) == expected else { throw UpdateError.checksumMismatch }
            try? manager.removeItem(at: staging)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            let app = staging.appendingPathComponent(target.lastPathComponent)
            do {
                try Self.copyApplication(from: image, to: app, workDirectory: staging)
                try validate(app, version: version)
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
            return app
        }.value
        return StagedUpdate(version: release.version, app: app)
    }

    public func apply(_ staged: StagedUpdate) throws {
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        let token = UUID().uuidString
        // Next to the target first, so the swap itself is a rename on one volume.
        let incoming = parent.appendingPathComponent(".Jit-update-\(token).app")
        try manager.moveItem(at: staged.app, to: incoming)
        if renamex_np(incoming.path, target.path, UInt32(RENAME_SWAP)) == 0 {
            // `incoming` now holds the old version.
            try? manager.removeItem(at: incoming)
            return
        }
        // No atomic swap on this volume: two renames, undone if the second fails.
        let old = parent.appendingPathComponent(".Jit-old-\(token).app")
        do {
            try manager.moveItem(at: target, to: old)
        } catch {
            try? manager.removeItem(at: incoming)
            throw error
        }
        do {
            try manager.moveItem(at: incoming, to: target)
        } catch {
            try? manager.moveItem(at: old, to: target)
            try? manager.removeItem(at: incoming)
            throw error
        }
        try? manager.removeItem(at: old)
    }

    // MARK: - Checks

    private func checkTargetIsReplaceable() throws {
        guard target.pathExtension == "app" else { throw UpdateError.cannotUpdateThisBuild }
        if target.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
            FileManager.default.isWritableFile(atPath: target.path)
        else { throw UpdateError.cannotReplace(parent.path) }
    }

    private func validate(_ app: URL, version: AppVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.wrongApplication("it is not an application") }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.wrongApplication("it is not Jit")
        }
        guard let found = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), found == version
        else { throw UpdateError.wrongApplication("its version is not \(version)") }
        guard Self.hasValidSignature(app, team: requiredTeam) else {
            throw UpdateError.wrongApplication("its code signature is not valid")
        }
        guard info[UpdateSigningKey.bundleKey] as? String == signingKey.hex else {
            throw UpdateError.wrongApplication("its update signing key differs from the installed app")
        }
    }

    /// The whole bundle matches its seal (nested code included); with `team`, it is also Developer ID code of that team.
    static func hasValidSignature(_ app: URL, team: String?) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        if let team {
            guard let text = PeerCodeSignature.requirement(team: team),
                SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
            else { return false }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Disk image

    /// Mounts `image` at a private mount point (read-only, hidden from Finder), copies its one application to
    /// `destination`, and unmounts it again.
    static func copyApplication(from image: URL, to destination: URL, workDirectory: URL) throws {
        let manager = FileManager.default
        let mount = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        guard
            hdiutil([
                "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path,
            ])
        else { throw UpdateError.unreadableDiskImage }
        defer {
            if !hdiutil(["detach", mount.path]) { _ = hdiutil(["detach", mount.path, "-force"]) }
            try? manager.removeItem(at: mount)
        }
        let name = destination.lastPathComponent
        let items = (try? manager.contentsOfDirectory(atPath: mount.path)) ?? []
        guard let found = items.first(where: { $0 == name }) ?? items.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.wrongApplication("the disk image has no application")
        }
        let source = mount.appendingPathComponent(found)
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw UpdateError.wrongApplication("the disk image has no application")
        }
        try manager.copyItem(at: source, to: destination)
    }

    private static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// The updater's two requests (ADR-0051): the release list from api.github.com and the release's files from
/// github.com. Ephemeral sessions have no cookies, credentials or cache, and redirects stay on HTTPS.
public enum UpdateNetwork {
    public static let fetch: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        request.setValue("Jit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: HTTPSRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.offline }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        guard data.count <= 4_000_000 else { throw UpdateError.tooLarge }
        return data
    }

    public static func download(
        _ url: URL, _ destination: URL, _ reportPercent: @escaping @Sendable (Int) -> Void
    ) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("Jit", forHTTPHeaderField: "User-Agent")
        let (result, completion) = AsyncThrowingStream<Void, any Error>.makeStream()
        let delegate = UpdateDownload(destination: destination, reportPercent: reportPercent, completion: completion)
        let downloadSession = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
        defer { downloadSession.finishTasksAndInvalidate() }
        let task = downloadSession.downloadTask(with: request)
        let finished = Task.detached {
            for try await _ in result {}
        }
        try await withTaskCancellationHandler {
            task.resume()
            try await finished.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    private static let session = URLSession(configuration: configuration())

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 900
        return configuration
    }
}

private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    let destination: URL
    let reportPercent: @Sendable (Int) -> Void
    let completion: AsyncThrowingStream<Void, any Error>.Continuation

    init(
        destination: URL, reportPercent: @escaping @Sendable (Int) -> Void,
        completion: AsyncThrowingStream<Void, any Error>.Continuation
    ) {
        self.destination = destination
        self.reportPercent = reportPercent
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
            (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        reportPercent(Int(min(1, max(0, fraction)) * 100))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse else { throw UpdateError.offline }
            guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            completion.finish()
        } catch {
            completion.finish(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { completion.finish(throwing: error) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        await HTTPSRedirects.shared.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request)
    }
}

private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = HTTPSRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}
