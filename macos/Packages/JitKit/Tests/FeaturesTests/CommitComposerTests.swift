import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// Commit composer (P3.10) with a real session, profiles and drafts in a temporary store.
@Suite @MainActor struct CommitComposerTests {
    struct World {
        let sandbox: GitSandbox
        let repo: TestRepo
        let session: RepositorySession
        let profiles: ProfileStore
        let location: StoreLocation
    }

    func world() async throws -> World {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial commit\n\nWith a body.")
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false)
        session.activate()
        let location = StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/AppSupport"))
        let profiles = ProfileStore(location: location)
        return World(sandbox: sandbox, repo: repo, session: session, profiles: profiles, location: location)
    }

    func waitUntil(_ timeout: Duration = .seconds(8), _ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func profile(_ name: String, _ email: String) -> GitProfile {
        GitProfile(displayName: name, colorIndex: 0, author: GitIdentity(name: name, email: email))
    }

    @Test func disabledReasonsAndTitle() async throws {
        let w = try await world()
        let model = CommitComposerModel(
            session: w.session, profiles: w.profiles, drafts: CommitDrafts(location: w.location))
        #expect(try await waitUntil { w.session.status != nil })
        #expect(model.disabledReason == "Choose a profile to commit.")
        w.profiles.create(profile("Ana", "ana@work.example"), activate: true)
        #expect(model.disabledReason == "Write a summary.")
        model.summary = "Add b"
        #expect(model.disabledReason == "Stage the changes to commit first.")
        try w.repo.write("b.txt", "b\n")
        try await w.repo.git("add", "b.txt")
        w.session.reload()
        #expect(try await waitUntil { model.disabledReason == nil })
        #expect(model.commitTitle == "Commit 1 File")
    }

    @Test func profileSwitchDuringCommitUsesSnapshot() async throws {
        let w = try await world()
        let hook = w.repo.path + "/.git/hooks/pre-commit"
        try "#!/bin/sh\nsleep 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let ana = profile("Ana", "ana@work.example")
        let kenji = profile("Kenji", "kenji@home.example")
        w.profiles.create(ana, activate: true)
        w.profiles.create(kenji)
        try w.repo.write("b.txt", "b\n")
        try await w.repo.git("add", "b.txt")
        w.session.reload()
        let model = CommitComposerModel(
            session: w.session, profiles: w.profiles, drafts: CommitDrafts(location: w.location))
        var committed: String?
        model.onCommitted = { committed = $0 }
        model.summary = "Snapshot test"
        #expect(try await waitUntil { model.disabledReason == nil })
        model.commit()
        try await Task.sleep(for: .milliseconds(200))
        w.profiles.setActive(kenji.id)  // switched while the hook runs
        #expect(try await waitUntil { committed != nil })
        #expect(try await w.repo.git("log", "-1", "--format=%an <%ae>") == "Ana <ana@work.example>")
        #expect(model.summary.isEmpty && model.error == nil)
    }

    @Test func draftsPersistAndAmendRestoresThem() async throws {
        let w = try await world()
        w.profiles.create(profile("Ana", "ana@work.example"), activate: true)
        let model = CommitComposerModel(
            session: w.session, profiles: w.profiles, drafts: CommitDrafts(location: w.location))
        model.activate()
        model.summary = "Work in progress"
        model.details = "Second paragraph"
        try await Task.sleep(for: .milliseconds(700))
        let reopened = CommitComposerModel(
            session: w.session, profiles: w.profiles, drafts: CommitDrafts(location: w.location))
        reopened.activate()
        #expect(reopened.summary == "Work in progress" && reopened.details == "Second paragraph")

        #expect(try await waitUntil { reopened.context.headMessage != nil })
        reopened.amend = true
        #expect(reopened.summary == "Initial commit" && reopened.details == "With a body.")
        #expect(reopened.commitTitle == "Amend Commit" && reopened.disabledReason == nil)
        #expect(reopened.showsResetAuthor)  // HEAD was authored by "Jit Tests"
        reopened.amend = false
        #expect(reopened.summary == "Work in progress")
        w.session.close()
    }
}
