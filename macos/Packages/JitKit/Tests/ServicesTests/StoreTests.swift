import Foundation
import GitCore
import Testing

@testable import Services

/// A throwaway Application Support directory.
final class TempLocation: Sendable {
    let location: StoreLocation

    init() {
        location = StoreLocation(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("jit-store-\(UUID().uuidString)"))
    }

    deinit { try? FileManager.default.removeItem(at: location.directory) }

    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: location.directory.path)) ?? [] }
}

@MainActor @Suite struct SessionStoreTests {
    func sample() -> SessionState {
        let id = UUID()
        return SessionState(
            windowFrame: .init(x: 10, y: 20, width: 1200, height: 800),
            layout: .init(sidebarWidth: 260, inspectorWidth: 400),
            tabs: [
                .init(
                    id: id, kind: .repository, path: "/Users/me/src/jit", titleCache: "jit", branchCache: "main",
                    sidebarCollapsed: true, inspectorCollapsed: false,
                    ui: [
                        "graph": .object([
                            "anchor": .string("abc"), "zoom": .number(1.5), "pins": .array([.bool(true)]),
                        ])
                    ]),
                .init(id: UUID(), kind: .newTab, titleCache: "New Tab"),
            ],
            activeTabID: id)
    }

    @Test func testRoundTrip() async throws {
        let temp = TempLocation()
        let store = SessionStore(location: temp.location)
        let state = sample()
        store.save { state }
        store.flush()
        #expect(store.load().value == state)
        // The per-feature `ui` blob round-trips untouched.
        #expect(SessionStore(location: temp.location).load().value?.tabs.first?.ui == state.tabs.first?.ui)
    }

    @Test func testDebouncedSaveWritesOnceAfterBurst() async throws {
        let temp = TempLocation()
        let store = SessionStore(location: temp.location)
        var evaluations = 0
        for index in 0..<50 {
            store.save {
                evaluations += 1
                return SessionState(activeTabID: index == 49 ? UUID() : nil)
            }
        }
        #expect(store.load().value == nil)  // nothing written yet
        // Wait for the debounced write. It runs on the main actor, which other suites in this process can keep
        // busy for seconds on a loaded CI runner; this test is about coalescing, not latency.
        let deadline = ContinuousClock.now + .seconds(30)
        while store.load().value == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(evaluations == 1)
        #expect(store.load().value?.activeTabID != nil)
    }

    @Test func testFlushAfterInFlightWriteKeepsNewestState() async throws {
        let temp = TempLocation()
        let store = SessionStore(location: temp.location)
        let old = SessionState(activeTabID: UUID())
        let new = SessionState(activeTabID: UUID())
        store.save { old }
        try await Task.sleep(for: .milliseconds(520))  // the debounced write is now starting off the main actor
        store.save { new }
        store.flush()  // quit: waits for the in-flight write, then writes the newest state
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.load().value == new)
    }

    @Test func testUnknownVersionBacksUpAndResets() throws {
        let temp = TempLocation()
        let store = SessionStore(location: temp.location)
        try StoreLocation(directory: temp.location.directory).ensureDirectory()
        try Data(#"{"version": 99, "tabs": []}"#.utf8).write(to: store.url)
        guard case .reset(let backup?) = store.load() else {
            Issue.record("expected reset")
            return
        }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(backup.lastPathComponent.hasPrefix("session.json.bak-"))
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        if case .missing = store.load() {} else { Issue.record("expected fresh start") }
    }

    @Test func testCorruptFileBacksUpAndResets() throws {
        let temp = TempLocation()
        let store = SessionStore(location: temp.location)
        try StoreLocation(directory: temp.location.directory).ensureDirectory()
        try Data(#"{"version": 1, "tabs": [{"id": "#.utf8).write(to: store.url)  // truncated (power loss)
        guard case .reset(let backup?) = store.load() else {
            Issue.record("expected reset")
            return
        }
        #expect(try Data(contentsOf: backup) == Data(#"{"version": 1, "tabs": [{"id": "#.utf8))
    }

    @Test func testAtomicWriteLeavesNoPartialFile() throws {
        let temp = TempLocation()
        let url = temp.location.url("session.json")
        let first = try JSONFile.encode(sample())
        try JSONFile.write(first, to: url)
        let second = try JSONFile.encode(SessionState())
        try JSONFile.write(second, to: url)
        #expect(try Data(contentsOf: url) == second)
        #expect(temp.files == ["session.json"])  // no temporary files left behind
        // A failed write (target is a directory now) leaves no temporary file either.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("blocker"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try JSONFile.write(first, to: url) }
        #expect(temp.files == ["session.json"])
    }

    @Test func testFilePermissions0600() throws {
        let temp = TempLocation()
        let url = temp.location.url("session.json")
        try JSONFile.write(Data("{}".utf8), to: url)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let directory =
            try FileManager.default.attributesOfItem(atPath: temp.location.directory.path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(directory == 0o700)
    }
}

@MainActor @Suite struct RecentsStoreTests {
    @Test func testDedupesByResolvedPath() throws {
        let temp = TempLocation()
        let real = temp.location.directory.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let link = temp.location.directory.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let store = RecentsStore(location: temp.location)
        store.noteOpened(path: real, name: "repo", branch: "main")
        store.noteOpened(path: link, name: "repo", branch: "dev")
        store.noteOpened(path: real + "/./", name: "repo", branch: "x")
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.lastBranch == "x")
    }

    @Test func testCapsAt20() {
        let temp = TempLocation()
        let store = RecentsStore(location: temp.location)
        for index in 0..<25 { store.noteOpened(path: "/tmp/jit-recent-\(index)", name: "r\(index)", branch: nil) }
        #expect(store.entries.count == 20)
        #expect(store.entries.first?.name == "r24")  // newest first
        #expect(store.entries.last?.name == "r5")
    }

    @Test func testMarksMissing() async throws {
        let temp = TempLocation()
        let present = temp.location.directory.appendingPathComponent("present").path
        try FileManager.default.createDirectory(atPath: present, withIntermediateDirectories: true)
        let store = RecentsStore(location: temp.location)
        store.noteOpened(path: "/nonexistent/jit/\(UUID().uuidString)", name: "gone", branch: nil)
        store.noteOpened(path: present, name: "present", branch: nil)
        await store.refreshMissing()
        #expect(store.missingPaths.count == 1)
        #expect(!store.missingPaths.contains(present))
    }

    @Test func testRemoveAndUndoRestorePositionAndPersist() async throws {
        let temp = TempLocation()
        let store = RecentsStore(location: temp.location)
        for name in ["a", "b", "c"] { store.noteOpened(path: "/tmp/jit-\(name)", name: name, branch: nil) }
        let removed = try #require(store.remove(path: "/tmp/jit-b"))
        #expect(store.entries.map(\.name) == ["c", "a"])
        store.restore(removed.entry, at: removed.index)
        #expect(store.entries.map(\.name) == ["c", "b", "a"])
        store.flush()
        #expect(RecentsStore(location: temp.location).entries.map(\.name) == ["c", "b", "a"])
    }
}

@MainActor @Suite struct PreferencesStoreTests {
    @Test func testAppearancePersists() throws {
        let suite = "jit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.appearance == .system)
        #expect(store.restoreTabsOnLaunch)
        store.appearance = .dark
        store.restoreTabsOnLaunch = false
        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.appearance == .dark)
        #expect(!reloaded.restoreTabsOnLaunch)
    }
}

@MainActor @Suite struct ProfileStoreTests {
    func profile(_ name: String, _ email: String = "a@example.com") -> GitProfile {
        GitProfile(displayName: name, colorIndex: 0, author: GitIdentity(name: name, email: email))
    }

    @Test func testCreateEditDeletePersist() {
        let temp = TempLocation()
        let store = ProfileStore(location: temp.location)
        var work = profile("Work", "me@work.example")
        store.create(profile("Personal"))
        store.create(work)
        #expect(store.activeProfile?.displayName == "Personal")  // first profile becomes active
        work.committer = GitIdentity(name: "CI", email: "ci@work.example")
        store.update(work)
        store.setActive(work.id)
        store.flush()
        let reloaded = ProfileStore(location: temp.location)
        #expect(reloaded.profiles.count == 2)
        #expect(reloaded.activeProfile == work)
        reloaded.delete(id: store.profiles[0].id)
        reloaded.flush()
        #expect(ProfileStore(location: temp.location).profiles.map(\.displayName) == ["Work"])
    }

    @Test func testDeleteActiveLeavesNoneSelected() {
        let temp = TempLocation()
        let store = ProfileStore(location: temp.location)
        let a = profile("A")
        let b = profile("B")
        store.create(a)
        store.create(b, activate: true)
        store.delete(id: b.id)
        #expect(store.activeProfileID == nil)
        #expect(store.snapshot() == nil)
        #expect(store.profiles == [a])  // never silently switches to another identity
    }

    @Test func testSnapshotIsImmutableAfterSwitch() throws {
        let temp = TempLocation()
        let store = ProfileStore(location: temp.location)
        var a = profile("A", "a@example.com")
        let b = profile("B", "b@example.com")
        store.create(a)
        store.create(b)
        let captured = try #require(store.snapshot())
        store.setActive(b.id)
        a.author.email = "changed@example.com"
        store.update(a)
        #expect(captured.author.email == "a@example.com")
        #expect(captured.committer == captured.author)  // committer defaults to author
        #expect(store.snapshot()?.profileID == b.id)
    }

    @Test func testValidation() {
        func issues(_ name: String, _ authorName: String, _ email: String) -> [ProfileValidation.Issue] {
            ProfileValidation.validate(
                displayName: name, author: GitIdentity(name: authorName, email: email), committer: nil)
        }
        #expect(issues("Work", "Ada", "ada@example.com").isEmpty)
        #expect(issues(" ", "Ada", "ada@example.com").map(\.field) == [.displayName])
        #expect(issues("W", "", "ada@example.com").map(\.field) == [.authorName])
        #expect(issues("W", "A<b>", "ada@example.com").first?.severity == .error)
        #expect(issues("W", "Ada", "").first?.severity == .error)
        #expect(issues("W", "Ada", "a b@example.com").first?.severity == .error)
        // Unusual but possible addresses warn without blocking.
        let warning = issues("W", "Ada", "ada@localhost")
        #expect(warning.map(\.severity) == [.warning])
        #expect(ProfileValidation.canSave(warning))
        #expect(!ProfileValidation.canSave(issues("", "Ada", "ada@example.com")))
        let committer = ProfileValidation.validate(
            displayName: "W", author: GitIdentity(name: "Ada", email: "ada@example.com"),
            committer: GitIdentity(name: "", email: "x@example.com"))
        #expect(committer.map(\.field) == [.committerName])
    }

    @Test func testNextColorAndInitials() {
        let temp = TempLocation()
        let store = ProfileStore(location: temp.location)
        store.create(
            GitProfile(displayName: "Work Account", colorIndex: 0, author: GitIdentity(name: "a", email: "a@b.c")))
        #expect(store.nextColorIndex() == 1)
        #expect(store.profiles[0].initials == "WA")
        #expect(GitProfile(displayName: "", colorIndex: 0, author: .init(name: "", email: "")).initials == "?")
    }
}

@Suite struct ProfileJSONTests {
    @Test func testNoSecretFieldsSerialized() throws {
        let profile = GitProfile(
            displayName: "Work", colorIndex: 2, author: GitIdentity(name: "Ada", email: "ada@example.com"),
            committer: GitIdentity(name: "Bot", email: "bot@example.com"))
        let file = ProfileStore.File(profiles: [profile], activeProfileID: profile.id)
        let data = try JSONFile.encode(file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "profiles", "activeProfileID"])
        let encoded = try #require((object["profiles"] as? [[String: Any]])?.first)
        #expect(Set(encoded.keys) == ["id", "displayName", "colorIndex", "author", "committer"])
        #expect(Set((encoded["author"] as? [String: Any])?.keys ?? [:].keys) == ["name", "email"])
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["token", "password", "secret", "key", "credential"] {
            #expect(!text.contains(forbidden), "profiles.json mentions \(forbidden)")
        }
    }
}
