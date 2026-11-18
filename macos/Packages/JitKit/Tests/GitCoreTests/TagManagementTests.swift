import Foundation
import GitTestKit
import Testing

@testable import GitCore

@Suite struct TagManagementTests {
    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(
            action: action, title: "Tag", context: "Test", changes: "Delete", recoverability: "Saved object",
            verb: "Delete"
        ).confirm()
    }

    @Test func tagAnnotatedUsesProfileIdentityAndPreservesMessage() async throws {
        let (_, repo, handle) = try await Ops.single()
        let old = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("Later")
        let message = "Release one\n\n# Keep this line\n  indented notes\n"
        try await handle.createTag(
            "release/v1", at: old, message: message, context: Ops.context, expected: handle.captureState())
        let tag = try await handle.tagDetails(named: "release/v1")
        #expect(tag.isAnnotated && tag.targetOID == old && tag.targetType == "commit")
        #expect(tag.tagger == "Ada Lovelace <ada@profile.example>" && tag.date != nil)
        #expect(tag.message.contains("# Keep this line\n  indented notes"))
        #expect(try await repo.git("show", "-s", "--format=%ce", "HEAD") == "tests@jit.invalid")
        let before = try await RepoFingerprint.capture(repo)
        for value in ["", " \n", "bad\0message"] {
            await #expect(throws: (any Error).self) {
                try await handle.createTag("invalid", at: old, message: value, context: Ops.context, expected: nil)
            }
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test(arguments: [
        "", "-bad", "a..b", "x.lock", "x@y@{1}", "with space", "bad\nname", "x:ref", "refs/tags/../branch",
    ])
    func tagNameValidationRejectsInvalid(_ name: String) async throws {
        let (_, repo, handle) = try await Ops.single()
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) { try await handle.validateTagName(name) }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }

    @Test(arguments: [false, true])
    func tagDeleteLocalReturnsTargetAndRecordsExactObject(_ annotated: Bool) async throws {
        let (_, repo, handle) = try await Ops.single()
        let head = try await repo.git("rev-parse", "HEAD")
        try await handle.createTag(
            "v1", at: head, message: annotated ? "Notes" : nil, context: Ops.context, expected: nil)
        try repo.write("a.txt", "local edits\n"); try repo.write("notes.txt", "untracked\n")
        let tag = try await handle.tagDetails(named: "v1")
        let before = try await RepoFingerprint.capture(repo)
        let deleted = try await handle.deleteTag(
            tag, token: confirm(tag.deletionAction), expected: handle.captureState())
        let after = try await RepoFingerprint.capture(repo)
        #expect(deleted.objectOID == tag.objectOID && deleted.targetOID == head)
        #expect(after.head == before.head && after.index == before.index && after.workingTree == before.workingTree)
        #expect(await handle.recoveryPoints.first?.oldOID == tag.objectOID)
        #expect(await handle.recoveryPoints.first?.refName == "refs/tags/v1")
        try await repo.git("update-ref", "refs/tags/v1", tag.objectOID)
        #expect(try await handle.tagDetails(named: "v1").objectOID == tag.objectOID)
    }

    @Test func localDeleteRejectsChangedObjectStateAndWrongToken() async throws {
        let (_, repo, handle) = try await Ops.single()
        let first = try await repo.git("rev-parse", "HEAD")
        try await handle.createTag("v1", at: first, message: "First", context: Ops.context, expected: nil)
        let tag = try await handle.tagDetails(named: "v1")
        let expected = try await handle.captureState()
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) {
            try await handle.deleteTag(tag, token: confirm(.clearStashes), expected: expected)
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        try await repo.commit("Later"); try await repo.git("tag", "-f", "v1")
        let moved = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) {
            try await handle.deleteTag(tag, token: confirm(tag.deletionAction), expected: expected)
        }
        await #expect(throws: (any Error).self) {
            try await handle.deleteTag(tag, token: confirm(tag.deletionAction), expected: nil)
        }
        #expect(try await RepoFingerprint.capture(repo) == moved)
    }

    @Test func tagDetailsSupportsBlobAndNestedAnnotation() async throws {
        let (_, repo, handle) = try await Ops.single()
        let blob = try await repo.git("rev-parse", "HEAD:a.txt")
        try await repo.git("tag", "blob", blob)
        let plain = try await handle.tagDetails(named: "blob")
        #expect(!plain.isAnnotated && plain.targetType == "blob" && plain.targetOID == blob)
        try await repo.git("tag", "-a", "inner", "-m", "Inner")
        try await repo.git("tag", "-a", "outer", "inner", "-m", "Outer")
        let outer = try await handle.tagDetails(named: "outer")
        #expect(outer.isAnnotated && outer.targetType == "commit" && outer.message == "Outer")
    }

    @Test func tagPushRejectedWhenRemoteDiffersAndNeverFollowsOtherTags() async throws {
        let world = try await Ops.world()
        let head = try await world.a.git("rev-parse", "HEAD")
        try await world.handleA.createTag("v1", at: head, message: "Version one", context: Ops.context, expected: nil)
        try await world.handleA.createTag("private", at: head, message: "Private", context: Ops.context, expected: nil)
        try await world.a.git("config", "push.followTags", "true")
        try await world.a.git("config", "remote.origin.mirror", "true")
        let tag = try await world.handleA.tagDetails(named: "v1")
        try await world.handleA.pushTag("v1", remote: "origin", object: tag.objectOID, context: .anonymous)
        #expect(try await world.a.git("ls-remote", "--refs", "origin", "refs/tags/v1").contains(tag.objectOID))
        #expect(try await world.a.git("ls-remote", "--refs", "origin", "refs/tags/private").isEmpty)
        try await world.a.commit("Later"); try await world.a.git("tag", "-f", "v1")
        await #expect(throws: (any Error).self) {
            try await world.handleA.pushTag("v1", remote: "origin", context: .anonymous)
        }
        #expect(try await world.a.git("ls-remote", "--refs", "origin", "refs/tags/v1").contains(tag.objectOID))
    }

    @Test func remoteDeleteUsesLeaseAndKeepsLocalTag() async throws {
        let world = try await Ops.world()
        let head = try await world.a.git("rev-parse", "HEAD")
        try await world.handleA.createTag("v1", at: head, message: "Notes", context: Ops.context, expected: nil)
        try await world.handleA.pushTag("v1", remote: "origin", context: .anonymous)
        let plan = try await world.handleA.remoteTagDeletionPreview(named: "v1", remote: "origin", context: .anonymous)
        let before = try await RepoFingerprint.capture(world.a)
        try await world.handleA.deleteRemoteTag(plan, token: confirm(plan.confirmationAction), context: .anonymous)
        #expect(try await RepoFingerprint.capture(world.a) == before)
        #expect(try await world.a.git("ls-remote", "--refs", "origin", "refs/tags/v1").isEmpty)
        #expect(try await world.a.git("rev-parse", "refs/tags/v1") == plan.objectOID)
    }

    @Test func remoteDeleteRefusesMovedRemoteAndChangedDestination() async throws {
        let world = try await Ops.world()
        try await world.a.git("tag", "v1"); try await world.a.git("push", "origin", "refs/tags/v1")
        let plan = try await world.handleA.remoteTagDeletionPreview(named: "v1", remote: "origin", context: .anonymous)
        try await world.b.commit("Moved"); try await world.b.git("tag", "v1");
        try await world.b.git("push", "--force", "origin", "refs/tags/v1")
        let moved = try await world.b.git("rev-parse", "v1")
        await #expect(throws: (any Error).self) {
            try await world.handleA.deleteRemoteTag(plan, token: confirm(plan.confirmationAction), context: .anonymous)
        }
        #expect(try await world.a.git("ls-remote", "--refs", "origin", "refs/tags/v1").contains(moved))
        let newPlan = try await world.handleA.remoteTagDeletionPreview(
            named: "v1", remote: "origin", context: .anonymous)
        try await world.a.git("remote", "set-url", "--push", "origin", world.b.path)
        await #expect(throws: (any Error).self) {
            try await world.handleA.deleteRemoteTag(
                newPlan, token: confirm(newPlan.confirmationAction), context: .anonymous)
        }
    }

    @Test func remotePreviewReadsSeparatePushDestination() async throws {
        let world = try await Ops.world()
        let push = try await world.b.bareClone("push.git")
        try await world.a.git("remote", "set-url", "--push", "origin", push)
        try await world.a.git("tag", "push-only");
        try await world.handleA.pushTag("push-only", remote: "origin", context: .anonymous)
        let plan = try await world.handleA.remoteTagDeletionPreview(
            named: "push-only", remote: "origin", context: .anonymous)
        #expect(try await world.a.git("ls-remote", "--refs", world.origin, "refs/tags/push-only").isEmpty)
        try await world.handleA.deleteRemoteTag(plan, token: confirm(plan.confirmationAction), context: .anonymous)
        #expect(try await world.a.git("ls-remote", "--refs", push, "refs/tags/push-only").isEmpty)
        try await world.a.git("remote", "set-url", "--add", "--push", "origin", world.origin)
        await #expect(throws: (any Error).self) {
            try await world.handleA.remoteTagDeletionPreview(named: "push-only", remote: "origin", context: .anonymous)
        }
    }
}

extension TagManagementTests {
    @Test(arguments: ["success", "failure", "cancel"])
    func privateMessageFileIsProtectedAndAlwaysRemoved(_ behavior: String) async throws {
        let (sandbox, repo, _) = try await Ops.single()
        let git = try await sandbox.engine.gitInfo().path
        let wrapper = sandbox.root + "/tag-git"
        let record = sandbox.root + "/message-record"
        let script = """
            #!/bin/sh
            previous=''
            for arg in "$@"; do
                if [ "$previous" = '-F' ]; then
                    printf '%s\\n' "$arg" > '\(record)'
                    stat -f '%Lp' "$arg" >> '\(record)'
                    stat -f '%Lp' "$(dirname "$arg")" >> '\(record)'
                    touch '\(record).ready'
                    if [ '\(behavior)' = failure ]; then echo 'controlled tag failure' >&2; exit 1; fi
                    if [ '\(behavior)' = cancel ]; then sleep 30; fi
                fi
                previous="$arg"
            done
            exec '\(git)' "$@"
            """
        try script.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper)
        var configuration = sandbox.engineConfiguration()
        configuration.locator.userOverridePath = wrapper; configuration.locator.allowsEnvironmentOverride = false
        let handle = try await GitEngine(configuration: configuration).openRepository(
            at: URL(fileURLWithPath: repo.path))
        let head = try await repo.git("rev-parse", "HEAD")
        let task = Task {
            try await handle.createTag("v1", at: head, message: "Private notes", context: Ops.context, expected: nil)
        }
        defer { task.cancel() }
        if behavior == "cancel" {
            for _ in 0..<500 {
                if FileManager.default.fileExists(atPath: record + ".ready") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: record + ".ready"))
            task.cancel()
        }
        if behavior == "success" {
            #expect(try await task.value.count == 40)
        } else {
            await #expect(throws: (any Error).self) { try await task.value }
        }
        let lines = try String(contentsOfFile: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && lines[1] == "600" && lines[2] == "700")
        #expect(!FileManager.default.fileExists(atPath: lines[0]))
        #expect(
            !FileManager.default.fileExists(atPath: URL(fileURLWithPath: lines[0]).deletingLastPathComponent().path))
    }

    @Test func remoteDeleteRejectsWrongPreviewMissingTagAndHookRefusal() async throws {
        let world = try await Ops.world()
        await #expect(throws: (any Error).self) {
            try await world.handleA.remoteTagDeletionPreview(named: "missing", remote: "origin", context: .anonymous)
        }
        try await world.a.git("tag", "v1"); try await world.a.git("push", "origin", "refs/tags/v1")
        let first = try await world.handleA.remoteTagDeletionPreview(named: "v1", remote: "origin", context: .anonymous)
        let second = try await world.handleA.remoteTagDeletionPreview(
            named: "v1", remote: "origin", context: .anonymous)
        await #expect(throws: (any Error).self) {
            try await world.handleA.deleteRemoteTag(
                second, token: confirm(first.confirmationAction), context: .anonymous)
        }
        let hook = world.origin + "/hooks/pre-receive"
        try "#!/bin/sh\necho 'Deletion refused by remote policy' >&2\nexit 1\n".write(
            toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook)
        await #expect(throws: (any Error).self) {
            try await world.handleA.deleteRemoteTag(
                first, token: confirm(first.confirmationAction), context: .anonymous)
        }
        #expect(try await world.a.git("ls-remote", "--refs", "origin", "refs/tags/v1").contains(first.objectOID))
    }

    @Test func credentialsAndReroutingAreRefusedBeforeNetwork() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.git("remote", "add", "unsafe", "https://user:secret@example.invalid/repo")
        await #expect(throws: (any Error).self) {
            try await handle.remoteTagDeletionPreview(named: "v1", remote: "unsafe", context: .anonymous)
        }
        try await repo.git("remote", "add", "rerouted", "https://example.invalid/repo")
        try await repo.git("config", "url.https://second.invalid/.pushInsteadOf", "https://example.invalid/")
        try await repo.git("config", "url.https://third.invalid/.insteadOf", "https://second.invalid/")
        await #expect(throws: (any Error).self) {
            try await handle.remoteTagDeletionPreview(named: "v1", remote: "rerouted", context: .anonymous)
        }
    }

    @Test func sha256TagAndSymbolicRefSafety() async throws {
        let sandbox = try GitSandbox()
        let path = try sandbox.makeDirectory("sha256")
        try await sandbox.git(["init", "-q", "--object-format=sha256"], in: path)
        let repo = TestRepo(sandbox: sandbox, path: path)
        let head = try await repo.commit("Initial")
        let handle = try await Ops.open(repo)
        try await handle.createTag("v1", at: head, message: "SHA256", context: Ops.context, expected: nil)
        let tag = try await handle.tagDetails(named: "v1")
        #expect(tag.objectOID.count == 64 && tag.targetOID == head)
        try await repo.git("symbolic-ref", "refs/tags/symbolic", "refs/heads/main")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: (any Error).self) { try await handle.tagDetails(named: "symbolic") }
        #expect(try await RepoFingerprint.capture(repo) == before)
        try await handle.deleteTag(tag, token: confirm(tag.deletionAction), expected: handle.captureState())
        #expect(try await repo.git("rev-parse", "HEAD") == head)
    }
}

extension TagManagementTests {
    @Test func changedRemoteSymbolicTagCannotDeleteItsTargetBranch() async throws {
        let world = try await Ops.world()
        try await world.a.git("tag", "v1"); try await world.a.git("push", "origin", "refs/tags/v1")
        let preview = try await world.handleA.remoteTagDeletionPreview(
            named: "v1", remote: "origin", context: .anonymous)
        try await world.sandbox.git(["symbolic-ref", "refs/tags/v1", "refs/heads/main"], in: world.origin)
        await #expect(throws: (any Error).self) {
            try await world.handleA.deleteRemoteTag(
                preview, token: confirm(preview.confirmationAction), context: .anonymous)
        }
        #expect(try await world.sandbox.git(["rev-parse", "refs/heads/main"], in: world.origin) == preview.objectOID)
    }
}
