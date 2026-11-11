import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import Services

@Suite struct AppVersionTests {
    @Test func parsesPlainVersionsWithOrWithoutV() {
        #expect(AppVersion("0.0.4")?.components == [0, 0, 4])
        #expect(AppVersion("v1.2.3")?.description == "1.2.3")
        #expect(AppVersion("2")?.components == [2, 0, 0])
        #expect(AppVersion(" 1.0 ") == AppVersion("1.0.0"))
    }

    @Test func rejectsEverythingElse() {
        for text in ["", "v", "1.0.0-beta.1", "latest", "1..2", "1.2.3.4.5", "-1.0", "1.0.0+7", "١.٢"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumerically() throws {
        let versions = try ["0.0.10", "0.0.9", "1.0.0", "0.1.0"].map { try #require(AppVersion($0)) }
        #expect(versions.sorted().map(\.description) == ["0.0.9", "0.0.10", "0.1.0", "1.0.0"])
        #expect(try #require(AppVersion("1.0.0.1")) > #require(AppVersion("1.0.0")))
    }
}

@Suite struct ReleaseFeedTests {
    static func feed(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries)
    }

    static func entry(
        _ tag: String, draft: Bool = false, prerelease: Bool = true, body: String = "notes",
        assets: [String]? = nil, host: String = "https://github.com/ashkanRmk/jit/releases/download"
    ) -> [String: Any] {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let names = assets ?? ["Jit-\(version).dmg", "Jit-\(version).dmg.sha256"]
        return [
            "tag_name": tag, "name": "Jit \(version) — test build", "body": body, "draft": draft,
            "prerelease": prerelease, "published_at": "2026-11-10T20:27:40Z",
            "html_url": "https://example.com/not-used",
            "assets": names.map { ["name": $0, "browser_download_url": "\(host)/\(tag)/\($0)"] },
        ]
    }

    @Test func newestFirstWithoutDraftsOrOddTags() throws {
        let data = try Self.feed([
            Self.entry("0.0.3"), Self.entry("v0.0.10"), Self.entry("0.0.11", draft: true),
            Self.entry("nightly"), Self.entry("0.0.2", prerelease: false), Self.entry("v0.0.3"),
        ])
        let releases = try ReleaseFeed.parse(data)
        #expect(releases.map(\.version) == ["0.0.10", "0.0.3", "0.0.2"])
        #expect(releases[0].title == "Jit 0.0.10 — test build")
        #expect(releases[0].isPrerelease)
        #expect(releases[0].publishedAt != nil)
        #expect(releases[0].pageURL.absoluteString == "https://github.com/ashkanRmk/jit/releases/tag/v0.0.10")
        #expect(
            releases[0].diskImageURL?.absoluteString
                == "https://github.com/ashkanRmk/jit/releases/download/v0.0.10/Jit-0.0.10.dmg")
        #expect(releases[0].isInstallable)
    }

    @Test func downloadsMustBeThisRepositorysOwnAssets() throws {
        let data = try Self.feed([
            Self.entry("0.0.5", host: "https://evil.example/ashkanRmk/jit/releases/download"),
            Self.entry("0.0.6", host: "http://github.com/ashkanRmk/jit/releases/download"),
            Self.entry("0.0.7", host: "https://github.com/someone/else/releases/download"),
            Self.entry("0.0.8", assets: ["Jit-0.0.8.dmg"]),
            Self.entry("0.0.9", assets: ["Other.dmg", "Other.dmg.sha256"]),
        ])
        let releases = try ReleaseFeed.parse(data)
        #expect(releases.count == 5)
        #expect(releases.allSatisfy { !$0.isInstallable })
        #expect(releases.first { $0.version == "0.0.8" }?.diskImageURL != nil)
    }

    @Test func unreadableFeedThrows() {
        #expect(throws: UpdateError.unreadableFeed) { try ReleaseFeed.parse(Data("{\"message\":\"no\"}".utf8)) }
    }
}

@Suite struct ReleaseNotesTests {
    @Test func headingsParagraphsAndBullets() {
        let notes = """
            # Jit 0.0.3 — test build

            The third test build: a new action bar,
            reworked side panels.

            ## What changed
            **Toolbar**
            - A bar under the tabs holds **Pull, Push** —
              as icons with their names.
              - nested item
            * Second

            ---
            Last words.
            """
        #expect(
            ReleaseNotes.blocks(from: notes) == [
                .paragraph("The third test build: a new action bar, reworked side panels."),
                .heading("What changed", level: 2),
                .paragraph("**Toolbar**"),
                .bullet("A bar under the tabs holds **Pull, Push** — as icons with their names.", indent: 0),
                .bullet("nested item", indent: 1),
                .bullet("Second", indent: 0),
                .paragraph("Last words."),
            ])
        #expect(ReleaseNotes.blocks(from: "# Title", droppingTitle: false) == [.heading("Title", level: 1)])
        #expect(ReleaseNotes.blocks(from: "").isEmpty)
    }
}

/// Counts requests and answers with a fixed feed.
final class FeedStub: Sendable {
    let requests = Mutex<[URL]>([])
    let answer: Mutex<Result<Data, UpdateError>>

    init(_ answer: Result<Data, UpdateError>) { self.answer = Mutex(answer) }

    var requestCount: Int { requests.withLock { $0.count } }
    var hosts: [String?] { requests.withLock { $0.map { $0.host } } }

    var fetcher: @Sendable (URL) async throws -> Data {
        { [self] url in
            requests.withLock { $0.append(url) }
            return try answer.withLock { $0 }.get()
        }
    }
}

final class InstallerStub: UpdateInstalling {
    let staged = Mutex<[String]>([])
    let applied = Mutex<[String]>([])
    let failure: UpdateError?

    init(failure: UpdateError? = nil) { self.failure = failure }

    var stagedVersions: [String] { staged.withLock { $0 } }
    var appliedVersions: [String] { applied.withLock { $0 } }

    func stage(_ release: AppRelease) async throws -> StagedUpdate {
        if let failure { throw failure }
        staged.withLock { $0.append(release.version) }
        return StagedUpdate(version: release.version, app: URL(fileURLWithPath: "/nonexistent/Jit.app"))
    }

    func apply(_ staged: StagedUpdate) throws { applied.withLock { $0.append(staged.version) } }
    func cleanUp() {}
}

@MainActor @Suite struct UpdateServiceTests {
    static func feed(_ versions: [String]) throws -> Data {
        try ReleaseFeedTests.feed(versions.map { ReleaseFeedTests.entry($0) })
    }

    static func service(_ current: String = "0.0.4", directory: URL? = nil) -> UpdateService {
        UpdateService(currentVersion: AppVersion(current), directory: directory)
    }

    static func wait(until condition: () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func withoutAFetcherNothingIsRequested() async {
        let service = Self.service()
        service.isAutomatic = { true }
        await service.check()
        service.checkAutomaticallyIfDue()
        #expect(service.phase == .idle)
        #expect(!service.hasUpdate)
    }

    @Test func manualCheckFindsTheNewerRelease() async throws {
        let service = Self.service()
        let stub = FeedStub(.success(try Self.feed(["0.0.3", "0.0.6", "0.0.5"])))
        service.fetcher = stub.fetcher
        await service.check()
        #expect(service.phase == .available(try #require(service.releases.first)))
        #expect(service.newerRelease?.version == "0.0.6")
        #expect(service.hasUpdate)
        #expect(service.lastChecked != nil)
        #expect(stub.hosts == ["api.github.com"])
        // Off: nothing is downloaded until the user says so.
        #expect(service.staged == nil)
    }

    @Test func manualCheckWhenUpToDateOrFailing() async throws {
        let service = Self.service()
        let stub = FeedStub(.success(try Self.feed(["0.0.4", "0.0.3"])))
        service.fetcher = stub.fetcher
        await service.check()
        #expect(service.phase == .upToDate)
        #expect(!service.hasUpdate)
        #expect(service.releases.first.map(service.isCurrent) == true)

        stub.answer.withLock { $0 = .failure(.http(403)) }
        await service.check()
        #expect(service.phase == .failed(UpdateError.http(403).message))
    }

    @Test func automaticOffNeverChecksByItself() async throws {
        let service = Self.service()
        let stub = FeedStub(.success(try Self.feed(["0.0.9"])))
        service.fetcher = stub.fetcher
        service.installer = InstallerStub()
        await service.start()
        service.checkAutomaticallyIfDue()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(stub.requestCount == 0)
        #expect(service.phase == .idle)
    }

    @Test func automaticChecksDownloadsAndInstallsOnQuit() async throws {
        let service = Self.service()
        let stub = FeedStub(.success(try Self.feed(["0.0.9"])))
        let installer = InstallerStub()
        service.fetcher = stub.fetcher
        service.installer = installer
        service.isAutomatic = { true }
        var relaunches = 0
        service.relaunch = { relaunches += 1 }
        await service.start()
        await Self.wait { service.staged != nil }
        #expect(service.phase == .ready(try #require(service.releases.first)))
        #expect(installer.stagedVersions == ["0.0.9"])
        #expect(relaunches == 0)  // never restarts by itself
        // Not due again, and already staged: no second request.
        service.checkAutomaticallyIfDue()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(stub.requestCount == 1)
        #expect(service.applyStagedUpdate())
        #expect(installer.appliedVersions == ["0.0.9"])
        #expect(!service.applyStagedUpdate())
    }

    @Test func automaticCheckIsAtMostDaily() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jit-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.service(directory: directory)
        let stub = FeedStub(.success(try Self.feed(["0.0.4"])))
        first.fetcher = stub.fetcher
        await first.check()
        await Self.wait {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("releases.json").path)
        }

        // A later run reads the saved list and does not ask again within a day…
        let second = Self.service(directory: directory)
        second.fetcher = stub.fetcher
        second.isAutomatic = { true }
        await second.start()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(second.releases.map(\.version) == ["0.0.4"])
        #expect(stub.requestCount == 1)
        // …but does after it.
        second.checkAutomaticallyIfDue(now: Date().addingTimeInterval(UpdateService.automaticInterval + 1))
        await Self.wait { stub.requestCount == 2 }
        #expect(stub.requestCount == 2)
    }

    @Test func savedListShowsAnUpdateFoundEarlier() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jit-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.service(directory: directory)
        first.fetcher = FeedStub(.success(try Self.feed(["0.0.7"]))).fetcher
        await first.check()
        await Self.wait {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("releases.json").path)
        }
        let second = Self.service(directory: directory)
        await second.start()
        #expect(second.hasUpdate)
        #expect(second.newerRelease?.version == "0.0.7")
    }

    @Test func installAndRestart() async throws {
        let service = Self.service()
        service.fetcher = FeedStub(.success(try Self.feed(["0.0.5"]))).fetcher
        var relaunches = 0
        service.relaunch = { relaunches += 1 }
        await service.check()
        let release = try #require(service.newerRelease)

        // A build without an installer says so instead of pretending.
        await service.install(release, relaunchWhenReady: true)
        #expect(service.phase == .failed(UpdateError.cannotUpdateThisBuild.message))
        #expect(relaunches == 0)

        service.installer = InstallerStub(failure: .checksumMismatch)
        await service.install(release, relaunchWhenReady: true)
        #expect(service.phase == .failed(UpdateError.checksumMismatch.message))
        #expect(service.staged == nil)

        service.installer = InstallerStub()
        await service.install(release, relaunchWhenReady: true)
        #expect(service.phase == .ready(release))
        #expect(relaunches == 1)
    }
}

/// The real thing: a signed app in a real disk image, mounted, copied, checked and swapped in.
@Suite(.serialized) struct DiskImageInstallerTests {
    static let bundleID = "com.example.jit-update-test"

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments)")
    }

    /// An ad-hoc signed `Jit.app` of `version` in `folder`.
    static func makeApp(in folder: URL, version: String, bundleID: String = bundleID, sign: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent("Jit.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Jit"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "Jit", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign { try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
        return app
    }

    struct Fixture {
        let root: URL
        let target: URL
        let image: URL
        let release: AppRelease
        let installer: DiskImageInstaller

        func installedVersion() -> String? {
            let plist = target.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return info["CFBundleShortVersionString"] as? String
        }
    }

    /// An installed 0.0.4 and a disk image holding `version`; `checksum` overrides the published SHA-256.
    static func fixture(
        version: String = "0.0.5", releaseVersion: String? = nil, bundleID: String = bundleID, sign: Bool = true,
        checksum: String? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jit-dmg-\(UUID().uuidString)")
        let installed = root.appendingPathComponent("Applications")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let target = try makeApp(in: installed, version: "0.0.4")
        _ = try makeApp(in: source, version: version, bundleID: bundleID, sign: sign)
        let image = root.appendingPathComponent("Jit.dmg")
        try run(
            "/usr/bin/hdiutil", ["create", "-srcfolder", source.path, "-volname", "Jit", "-format", "UDZO", image.path])
        let sum = try checksum ?? DiskImageInstaller.sha256(of: image)
        let wanted = releaseVersion ?? version
        let base = "https://github.com/ashkanRmk/jit/releases/download/\(wanted)/Jit-\(wanted).dmg"
        let release = AppRelease(
            version: wanted, title: "Jit \(wanted)", notes: "", publishedAt: nil, isPrerelease: true,
            pageURL: URL(string: "https://github.com/ashkanRmk/jit/releases/tag/\(wanted)")!,
            diskImageURL: URL(string: base), checksumURL: URL(string: base + ".sha256"))
        let installer = DiskImageInstaller(
            target: target, bundleIdentifier: Self.bundleID, currentVersion: AppVersion("0.0.4")!,
            directory: root.appendingPathComponent("Updates"), requiredTeam: nil,
            fetch: { _ in Data("\(sum)  Jit-\(wanted).dmg\n".utf8) },
            download: { _, destination in try FileManager.default.copyItem(at: image, to: destination) })
        return Fixture(root: root, target: target, image: image, release: release, installer: installer)
    }

    static func leftovers(_ fixture: Fixture) -> [String] {
        let updates =
            (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Updates").path))
            ?? []
        let beside =
            (try? FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path))
            ?? []
        return (updates + beside).filter { $0 != "Jit.app" }.sorted()
    }

    @Test func stagesAndSwapsTheNewVersionIn() async throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staged = try await fixture.installer.stage(fixture.release)
        #expect(staged.version == "0.0.5")
        // Staging alone leaves the installed app alone.
        #expect(fixture.installedVersion() == "0.0.4")
        #expect(
            !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Updates/staged/mount").path))

        try fixture.installer.apply(staged)
        #expect(fixture.installedVersion() == "0.0.5")
        #expect(DiskImageInstaller.hasValidSignature(fixture.target, team: nil))
        // No old copy, no hidden leftovers beside the app, no disk image kept.
        #expect(Self.leftovers(fixture) == ["staged"])
        fixture.installer.cleanUp()
        #expect(Self.leftovers(fixture).isEmpty)
    }

    @Test func wrongChecksumIsRejectedBeforeMounting() async throws {
        let fixture = try Self.fixture(checksum: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: UpdateError.checksumMismatch) { try await fixture.installer.stage(fixture.release) }
        #expect(fixture.installedVersion() == "0.0.4")
        #expect(Self.leftovers(fixture).isEmpty)
    }

    @Test func anotherApplicationIsRejected() async throws {
        let fixture = try Self.fixture(bundleID: "com.example.other")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: UpdateError.wrongApplication("it is not Jit")) {
            try await fixture.installer.stage(fixture.release)
        }
        #expect(fixture.installedVersion() == "0.0.4")
        #expect(Self.leftovers(fixture).isEmpty)
    }

    @Test func olderOrMislabelledVersionsAreRejected() async throws {
        let older = try Self.fixture(version: "0.0.3")
        defer { try? FileManager.default.removeItem(at: older.root) }
        await #expect(throws: UpdateError.wrongApplication("it is not newer than this Jit")) {
            try await older.installer.stage(older.release)
        }
        let mislabelled = try Self.fixture(version: "0.0.5", releaseVersion: "0.0.6")
        defer { try? FileManager.default.removeItem(at: mislabelled.root) }
        await #expect(throws: UpdateError.wrongApplication("its version is not 0.0.6")) {
            try await mislabelled.installer.stage(mislabelled.release)
        }
    }

    @Test func brokenSignatureIsRejected() async throws {
        let fixture = try Self.fixture(sign: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: UpdateError.wrongApplication("its code signature is not valid")) {
            try await fixture.installer.stage(fixture.release)
        }
        #expect(fixture.installedVersion() == "0.0.4")
    }

    @Test func readOnlyInstallFolderIsRefusedBeforeDownloading() async throws {
        let fixture = try Self.fixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.target.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let folder = fixture.target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        await #expect(throws: UpdateError.cannotReplace(folder.path)) {
            try await fixture.installer.stage(fixture.release)
        }
        #expect(Self.leftovers(fixture).isEmpty)
    }

    @Test func checksumFileFormat() throws {
        let sum = String(repeating: "aB", count: 32)
        #expect(try DiskImageInstaller.checksum(in: Data("\(sum)  Jit-0.0.5.dmg\n".utf8)) == sum.lowercased())
        #expect(throws: UpdateError.checksumMismatch) { try DiskImageInstaller.checksum(in: Data("nope".utf8)) }
        #expect(throws: UpdateError.checksumMismatch) { try DiskImageInstaller.checksum(in: Data()) }
    }
}
