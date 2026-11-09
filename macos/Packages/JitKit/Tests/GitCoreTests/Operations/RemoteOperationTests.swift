import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// P4.4–P4.7 — fetch, pull, push, clone against local bare remotes and a local HTTP stub.
@Suite struct RemoteOperationTests {
    // MARK: Fetch

    @Test func fetchUpdatesRemoteRefs() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "from b\n")
        let pushed = try await world.b.commit("From B")
        try await world.b.git("push", "-q", "origin", "main")
        let outcome = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: false))
        #expect(outcome.changedRefs == 1)
        #expect(!outcome.cancelled)
        #expect(try await world.a.git("rev-parse", "origin/main") == pushed)
    }

    @Test func fetchPruneExplicit() async throws {
        let world = try await Ops.world()
        try await world.b.git("push", "-q", "origin", "HEAD:refs/heads/temp")
        _ = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: false))
        #expect(try await world.a.git("branch", "-r", "--list", "origin/temp") == "origin/temp")
        try await world.b.git("push", "-q", "origin", "--delete", "temp")
        // Prune off (explicit), even if config says otherwise.
        try await world.a.git("config", "fetch.prune", "true")
        _ = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: false))
        #expect(try await world.a.git("branch", "-r", "--list", "origin/temp") == "origin/temp")
        _ = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: true))
        #expect(try await world.a.git("branch", "-r", "--list", "origin/temp") == "")
        #expect(try await world.handleA.remotes().first?.prune == true)
    }

    @Test func fetchRejectsUnknownRemote() async throws {
        let world = try await Ops.world()
        await #expect(throws: GitCoreError.self) {
            _ = try await world.handleA.fetch(FetchRequest(remote: "--upload-pack=evil", prune: false))
        }
    }

    @Test func fetchCancelLeavesRefsConsistent() async throws {
        let world = try await Ops.world()
        // A large synthetic pack: many random blobs so the transfer takes a moment.
        for index in 0..<16 {
            var bytes = [UInt8](repeating: 0, count: 256 * 1024)
            bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try Data(bytes).write(to: URL(fileURLWithPath: world.b.path + "/blob\(index).bin"))
        }
        try await world.b.commit("Big")
        try await world.b.git("push", "-q", "origin", "main")
        let before = try await world.a.git("rev-parse", "origin/main")
        let after = try await world.b.git("rev-parse", "main")
        let task = Task { try await world.handleA.fetch(FetchRequest(remote: "origin", prune: false)) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let outcome = try await task.value
        let now = try await world.a.git("rev-parse", "origin/main")
        #expect(now == before || now == after)
        if outcome.cancelled { #expect(outcome.changedRefs == (now == before ? 0 : 1)) }
        _ = try await world.a.git("fsck", "--connectivity-only", "--no-progress")
    }

    @Test func aheadBehindCounts() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        try await world.b.commit("B1")
        try world.b.write("b2.txt", "b\n")
        try await world.b.commit("B2")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A1")
        _ = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: false))
        let refs = try await world.handleA.refs()
        let main = try #require(refs.ref(named: "refs/heads/main"))
        #expect(main.ahead == 1 && main.behind == 2)
    }

    @Test func upstreamGoneDetected() async throws {
        let world = try await Ops.world()
        try await world.a.git("push", "-q", "-u", "origin", "HEAD:refs/heads/topic")
        try await world.a.git("branch", "--set-upstream-to=origin/topic", "main")
        try await world.b.git("push", "-q", "origin", "--delete", "topic")
        _ = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: true))
        let refs = try await world.handleA.refs()
        #expect(refs.ref(named: "refs/heads/main")?.upstreamGone == true)
    }

    @Test func remoteURLUserinfoMasked() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.git("remote", "add", "secret", "https://ada:hunter2@example.com/x.git")
        let remote = try #require(try await handle.remotes().first { $0.name == "secret" })
        let masked = RemoteInfo.masked(remote.fetchURLs[0])
        #expect(masked.hadCredentials)
        #expect(!masked.url.contains("hunter2"))
    }

    // MARK: Pull

    @Test func pullFFOnlyFastForwards() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        let tip = try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        let outcome = try await world.handleA.pull(.fastForwardOnly, context: .anonymous)
        guard case .fastForwarded(_, let to)? = outcome.integration else {
            Issue.record("expected fast-forward, got \(String(describing: outcome.integration))")
            return
        }
        #expect(to == tip)
        #expect(try await world.a.git("rev-parse", "HEAD") == tip)
    }

    @Test func pullFFOnlyRefusesDivergentWithoutChanges() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        try await world.a.git("fetch", "-q")
        let before = try await RepoFingerprint.capture(world.a)
        let outcome = try await world.handleA.pull(.fastForwardOnly, context: .anonymous)
        #expect(outcome.integration == .notFastForward(ahead: 1, behind: 1))
        let after = try await RepoFingerprint.capture(world.a)
        #expect(after == before, "\(after.difference(from: before))")
    }

    @Test func pullMergeCreatesMergeCommitWithProfileCommitter() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let outcome = try await world.handleA.pull(.merge, context: Ops.context)
        guard case .merged(let commit)? = outcome.integration else {
            Issue.record("expected merge, got \(String(describing: outcome.integration))")
            return
        }
        #expect(
            try await world.a.git("log", "-1", "--format=%an|%cn|%P", commit).split(separator: "|").prefix(2) == [
                "Ada Lovelace", "Ada Lovelace",
            ])
    }

    @Test func pullRebaseReplays() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        let upstream = try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let outcome = try await world.handleA.pull(.rebase, context: Ops.context)
        #expect(outcome.integration == .rebased(count: 1))
        #expect(try await world.a.git("rev-parse", "HEAD~1") == upstream)
        // Original author kept (the sandbox's "Jit Tests"), committer is the profile.
        #expect(try await world.a.git("log", "-1", "--format=%an|%cn") == "Jit Tests|Ada Lovelace")
        #expect(try await world.a.git("rev-list", "--merges", "--count", "HEAD") == "0")
    }

    @Test func pullIgnoresPullRebaseConfigForExplicitChoice() async throws {
        let world = try await Ops.world()
        try await world.a.git("config", "pull.rebase", "true")
        try await world.a.git("config", "pull.ff", "only")
        try world.b.write("b.txt", "b\n")
        try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let outcome = try await world.handleA.pull(.merge, context: Ops.context)
        guard case .merged? = outcome.integration else {
            Issue.record(
                "explicit merge must merge despite pull.rebase=true, got \(String(describing: outcome.integration))")
            return
        }
    }

    @Test func pullConflictEntersState() async throws {
        let world = try await Ops.world()
        try world.b.write("a.txt", "one\nB\nthree\n")
        try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a.txt", "one\nA\nthree\n")
        try await world.a.commit("A")
        let outcome = try await world.handleA.pull(.merge, context: Ops.context)
        #expect(outcome.integration == .stoppedWithConflicts(paths: ["a.txt"]))
        guard case .merging = try await world.handleA.operationState() else {
            Issue.record("expected merging state")
            return
        }
    }

    @Test func upstreamOfNamedBranch() async throws {
        let world = try await Ops.world()
        let upstream = try await world.handleA.upstream(of: "main")
        #expect(upstream?.remote == "origin")
        #expect(upstream?.ref == "refs/remotes/origin/main")
        try await world.a.git("switch", "-q", "-c", "local-only")
        #expect(try await world.handleA.upstream(of: "local-only") == nil)
        #expect(try await world.handleA.upstream(of: "main")?.shortName == "origin/main")
    }

    @Test func pullWithoutUpstreamRefused() async throws {
        let (sandbox, _, handle) = try await Ops.single()
        defer { withExtendedLifetime(sandbox) {} }
        await #expect(throws: GitCoreError.self) { _ = try await handle.pull(.fastForwardOnly, context: .anonymous) }
    }

    // MARK: Push

    @Test func pushFastForward() async throws {
        let world = try await Ops.world()
        try world.a.write("a2.txt", "a\n")
        let tip = try await world.a.commit("A")
        let outcome = try await world.handleA.push(PushRequest(remote: "origin", localBranch: "main"))
        #expect(outcome.succeeded)
        #expect(outcome.refs.first?.status == .fastForward)
        #expect(try await world.sandbox.git(["rev-parse", "main"], in: world.origin) == tip)
    }

    @Test func pushPublishesAndSetsUpstream() async throws {
        let world = try await Ops.world()
        try await world.a.git("switch", "-q", "-c", "topic")
        try world.a.write("t.txt", "t\n")
        try await world.a.commit("T")
        let outcome = try await world.handleA.push(
            PushRequest(remote: "origin", localBranch: "topic", setUpstream: true))
        #expect(outcome.refs.first?.status == .new)
        #expect(try await world.a.git("rev-parse", "--abbrev-ref", "topic@{upstream}") == "origin/topic")
    }

    @Test func pushRejectedNonFFClassified() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let outcome = try await world.handleA.push(PushRequest(remote: "origin", localBranch: "main"))
        #expect(outcome.rejection == .nonFastForward)
        #expect(!outcome.succeeded)
    }

    @Test func pushRejectedByHookShowsRemoteLines() async throws {
        let world = try await Ops.world()
        let hook = world.origin + "/hooks/pre-receive"
        try "#!/bin/sh\necho 'Branch main is protected by policy'\nexit 1\n".write(
            toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let outcome = try await world.handleA.push(PushRequest(remote: "origin", localBranch: "main"))
        guard case .remoteHook? = outcome.rejection else {
            Issue.record("expected hook rejection, got \(String(describing: outcome.rejection))")
            return
        }
        #expect(outcome.remoteLines.contains { $0.contains("protected by policy") })
    }

    @Test func forceWithLeaseSucceedsWhenExpectedMatches() async throws {
        let world = try await Ops.world()
        try world.b.write("b.txt", "b\n")
        try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        let mine = try await world.a.commit("A")
        _ = try await world.handleA.fetch(FetchRequest(remote: "origin", prune: false))
        let expected = try #require(try await world.handleA.remoteTrackingOID(remote: "origin", branch: "main"))
        let token = ConfirmationRequest(
            action: .forcePush(remote: "origin", remoteRef: "main", expected: expected), title: "", context: "",
            changes: "", recoverability: "", verb: "Force Push"
        ).confirm()
        let outcome = try await world.handleA.forcePushWithLease(
            PushRequest(remote: "origin", localBranch: "main"), expected: expected, token: token)
        #expect(outcome.succeeded)
        #expect(try await world.sandbox.git(["rev-parse", "main"], in: world.origin) == mine)
    }

    @Test func forceWithLeaseFailsWhenRemoteMoved() async throws {
        let world = try await Ops.world()
        let stale = try await world.a.git("rev-parse", "origin/main")
        try world.b.write("b.txt", "b\n")
        let theirs = try await world.b.commit("B")
        try await world.b.git("push", "-q", "origin", "main")
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let token = ConfirmationRequest(
            action: .forcePush(remote: "origin", remoteRef: "main", expected: stale), title: "", context: "",
            changes: "", recoverability: "", verb: "Force Push"
        ).confirm()
        let outcome = try await world.handleA.forcePushWithLease(
            PushRequest(remote: "origin", localBranch: "main"), expected: stale, token: token)
        #expect(outcome.rejection == .staleLease)
        #expect(try await world.sandbox.git(["rev-parse", "main"], in: world.origin) == theirs)
    }

    @Test func forcePushNeverUsesPlainForce() throws {
        let source = try String(
            contentsOf: HygieneTests.gitCoreSources.appendingPathComponent("Operations/Remote.swift"), encoding: .utf8)
        #expect(!source.contains("\"--force\""))
        #expect(!source.contains("\"-f\""))
    }

    @Test func pushCancelReportsActualRemoteState() async throws {
        let world = try await Ops.world()
        try world.a.write("a2.txt", "a\n")
        try await world.a.commit("A")
        let task = Task { try await world.handleA.push(PushRequest(remote: "origin", localBranch: "main")) }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        let remote: String
        let local = try await world.a.git("rev-parse", "main")
        let outcome: PushOutcome
        do {
            outcome = try await task.value
            remote = try await world.sandbox.git(["rev-parse", "main"], in: world.origin)
        } catch let error as GitCoreError where error == .cancelled {
            // Cancelled before Git started: nothing was pushed.
            #expect(try await world.sandbox.git(["rev-parse", "main"], in: world.origin) != local)
            return
        }
        if outcome.cancelled {
            #expect(outcome.refs.first?.status == (remote == local ? .fastForward : .failed))
        } else {
            #expect(remote == local)
        }
    }

    // MARK: Clone

    @Test func cloneFileURLSucceeds() async throws {
        let world = try await Ops.world()
        let (stream, continuation) = AsyncStream.makeStream(
            of: OperationProgress.self, bufferingPolicy: .bufferingNewest(1))
        _ = stream
        let outcome = try await cloneRepository(
            CloneRequest(url: "file://" + world.origin, parentDirectory: world.sandbox.root, name: "c"),
            engine: world.sandbox.engine, progress: continuation)
        #expect(outcome.path == world.sandbox.root + "/c")
        #expect(!outcome.hasSubmodules)
        #expect(FileManager.default.fileExists(atPath: outcome.path + "/a.txt"))
    }

    @Test func cloneRejectsDashPrefixedURL() async throws {
        let sandbox = try GitSandbox()
        await #expect(throws: GitCoreError.self) {
            _ = try await cloneRepository(
                CloneRequest(url: "--upload-pack=touch /tmp/x", parentDirectory: sandbox.root, name: "x"),
                engine: sandbox.engine)
        }
    }

    @Test func cloneRejectsExtProtocol() async throws {
        let sandbox = try GitSandbox()
        for url in ["ext::sh -c touch% /tmp/pwned", "fd::17", "foo://example.com/x"] {
            if case .success = CloneURL.classify(url) { Issue.record("\(url) accepted") }
        }
        await #expect(throws: GitCoreError.self) {
            _ = try await cloneRepository(
                CloneRequest(url: "ext::sh -c id", parentDirectory: sandbox.root, name: "x"), engine: sandbox.engine)
        }
        #expect(CloneURL.classify("git@github.com:owner/repo.git") == .success(.scp))
        #expect(CloneURL.classify("https://github.com/owner/repo") == .success(.https))
        #expect(CloneURL.classify("http://example.com/r.git") == .success(.insecureHTTP))
        #expect(CloneURL.derivedName("https://github.com/owner/repo.git") == "repo")
        #expect(CloneURL.derivedName("git@gitlab.com:group/sub/project.git/") == "project")
    }

    @Test func cloneInsecureHTTPRequiresConfirmation() async throws {
        let sandbox = try GitSandbox()
        do {
            _ = try await cloneRepository(
                CloneRequest(url: "http://127.0.0.1:9/x.git", parentDirectory: sandbox.root, name: "x"),
                engine: sandbox.engine)
            Issue.record("http:// must need confirmation")
        } catch .refused {
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func cloneCancelRemovesCreatedDestination() async throws {
        let world = try await Ops.world()
        for index in 0..<16 {
            var bytes = [UInt8](repeating: 0, count: 256 * 1024)
            bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try Data(bytes).write(to: URL(fileURLWithPath: world.b.path + "/blob\(index).bin"))
        }
        try await world.b.commit("Big")
        try await world.b.git("push", "-q", "origin", "main")
        let destination = world.sandbox.root + "/cancelled"
        let task = Task {
            try await cloneRepository(
                CloneRequest(url: "file://" + world.origin, parentDirectory: world.sandbox.root, name: "cancelled"),
                engine: world.sandbox.engine)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            // Finished before the cancel landed: that's a complete clone.
            #expect(FileManager.default.fileExists(atPath: destination + "/.git"))
        } catch {
            #expect(!FileManager.default.fileExists(atPath: destination))
        }
    }

    @Test func cloneCancelPreservesPreexistingEmptyFolder() async throws {
        let world = try await Ops.world()
        let destination = try world.sandbox.makeDirectory("empty")
        let task = Task {
            try await cloneRepository(
                CloneRequest(url: "file://" + world.origin, parentDirectory: world.sandbox.root, name: "empty"),
                engine: world.sandbox.engine)
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory) && isDirectory.boolValue)
            #expect((try FileManager.default.contentsOfDirectory(atPath: destination)).isEmpty)
        }
    }

    @Test func cloneIntoNonemptyFolderBlocked() async throws {
        let world = try await Ops.world()
        let destination = try world.sandbox.makeDirectory("full")
        try "keep".write(toFile: destination + "/mine.txt", atomically: true, encoding: .utf8)
        await #expect(throws: GitCoreError.self) {
            _ = try await cloneRepository(
                CloneRequest(url: "file://" + world.origin, parentDirectory: world.sandbox.root, name: "full"),
                engine: world.sandbox.engine)
        }
        #expect(try String(contentsOfFile: destination + "/mine.txt", encoding: .utf8) == "keep")
    }

    @Test func cloneAuthRequiredFailsFastNonInteractive() async throws {
        let server = try HTTPStubServer()
        let sandbox = try GitSandbox()
        let start = ContinuousClock.now
        do {
            _ = try await cloneRepository(
                CloneRequest(url: server.url, parentDirectory: sandbox.root, name: "x", allowInsecureHTTP: true),
                engine: sandbox.engine)
        } catch .failed(let failure) {
            #expect(failure.kind == .authenticationFailed)
        }
        #expect(ContinuousClock.now - start < PerfBudget.limit(.seconds(1)))
    }
}
