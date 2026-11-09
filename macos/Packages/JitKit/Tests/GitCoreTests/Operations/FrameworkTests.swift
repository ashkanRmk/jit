import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import GitCore

/// P4.1 — operation framework: execution context, progress, classification, tokens, serialization.
@Suite struct FrameworkTests {
    @Test func execEnvIsNonInteractive() {
        let base = ProcessEnvironment.make(executableDirectory: "/usr/bin", kind: .write, parent: [:])
        #expect(base["GIT_TERMINAL_PROMPT"] == "0")
        #expect(base["GIT_ASKPASS"] == "/usr/bin/false")
        #expect(base["SSH_ASKPASS"] == "/usr/bin/false")
        #expect(base["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(base["GIT_EDITOR"] == "true")
        #expect(base["GIT_SEQUENCE_EDITOR"] == "true")
        #expect(base["GCM_INTERACTIVE"] == "never")
        #expect(base["LC_ALL"] == "C")
        let remote = GitEnvironment.remoteCommand(["fetch", "origin"], in: "/tmp", context: .anonymous)
        #expect(remote.environment["GIT_SSH_COMMAND"] == "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes")
        #expect(remote.timeout == nil)
        #expect(Array(remote.arguments.prefix(4)) == GitEnvironment.protocolPolicy)
    }

    @Test func execEnvContainsNoUserDerivedCValues() {
        // Whatever a user names their remote or branch, it never becomes a `-c` value or an env value.
        let hostile = "origin; touch /tmp/pwned -c core.sshCommand=evil"
        let command = GitEnvironment.remoteCommand(["fetch", hostile], in: "/tmp", context: Ops.context)
        var configValues: [String] = []
        for (index, argument) in command.arguments.enumerated() where argument == "-c" {
            configValues.append(command.arguments[index + 1])
        }
        // Phase 5 (ADR-0016): inherited credential helpers are always cleared.
        #expect(configValues == ["protocol.ext.allow=never", "protocol.fd.allow=never", "credential.helper="])
        for value in command.environment.values { #expect(!value.contains("pwned")) }
        // Identity is only ever set through the environment (ADR-0028), never `-c user.*`.
        let integration = GitEnvironment.integrationCommand(
            ["merge", "x"], in: "/tmp", identity: Ops.ada, use: .authorAndCommitter)
        #expect(!integration.arguments.contains("-c"))
        #expect(integration.environment["GIT_AUTHOR_EMAIL"] == "ada@profile.example")
        let pick = GitEnvironment.integrationCommand(
            ["cherry-pick", "x"], in: "/tmp", identity: Ops.ada, use: .committerOnly)
        #expect(pick.environment["GIT_AUTHOR_NAME"] == nil)
        #expect(pick.environment["GIT_COMMITTER_NAME"] == "Ada Lovelace")
    }

    @Test func profileAccessBecomesScopedOptionsAndEnvironment() {
        let access = RemoteAccess(
            helperPath: "/Applications/My Apps/Jit.app/Contents/Helpers/jit-git-helper",
            broker: BrokerEndpoint(socketPath: "/tmp/jit-x/b", nonce: "abc"), httpsCredentials: true,
            ssh: SSHPlan(
                keyPath: "/Users/me/keys/it's a key", useAgent: false,
                knownHostsFiles: [
                    "/Users/me/.ssh/known_hosts", "/Users/me/Library/Application Support/Jit/known_hosts",
                ],
                strictConfig: true, proxy: SSHProxy(kind: .socks5, host: "proxy.corp", port: 1080)),
            network: [
                ScopedNetwork(
                    urlPrefix: "https://git.corp:8443/", caInfo: "/ca/x.pem", proxy: .url("http://proxy.corp:3128")),
                ScopedNetwork(urlPrefix: "https://github.com/", proxy: .direct),
            ])
        let command = GitEnvironment.remoteCommand(
            ["fetch", "origin"], in: "/tmp", context: .anonymous, access: access)
        var config: [String] = []
        for (index, argument) in command.arguments.enumerated() where argument == "-c" {
            config.append(command.arguments[index + 1])
        }
        #expect(
            config == [
                "protocol.ext.allow=never", "protocol.fd.allow=never", "credential.helper=",
                "credential.helper=!'/Applications/My Apps/Jit.app/Contents/Helpers/jit-git-helper' credential",
                "credential.useHttpPath=false", "credential.interactive=false",
                "http.https://git.corp:8443/.sslCAInfo=/ca/x.pem",
                "http.https://git.corp:8443/.proxy=http://proxy.corp:3128",
                "http.https://github.com/.proxy=",
            ])
        #expect(Array(command.arguments.suffix(2)) == ["fetch", "origin"])
        let env = command.environment
        #expect(env["GIT_SSH_COMMAND"] == "'/Applications/My Apps/Jit.app/Contents/Helpers/jit-git-helper'")
        #expect(env["JIT_HELPER_MODE"] == "ssh")
        #expect(env["JIT_SSH_KEY"] == "/Users/me/keys/it's a key")
        #expect(env["JIT_SSH_STRICT"] == "1")
        #expect(env["JIT_SSH_PROXY"] == "socks5 proxy.corp:1080")
        #expect(env["JIT_BROKER_NONCE"] == "abc")
        // Never insecure TLS or host-key settings.
        let all = (command.arguments + env.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
        for forbidden in ["sslVerify", "GIT_SSL_NO_VERIFY", "StrictHostKeyChecking=no", "accept-new"] {
            #expect(!all.contains(forbidden))
        }
    }

    @Test func shellQuoteHandlesQuotes() {
        #expect(GitEnvironment.shellQuote("/a b/it's") == "'/a b/it'\\''s'")
    }

    @Test func progressParsesFetchClonePushSamples() {
        // Captured from `git clone --progress` / `git push --progress` (C locale), CR-separated updates.
        let clone =
            "Cloning into 'x'...\nremote: Enumerating objects: 1234, done.\nremote: Counting objects:  50% (10/20)\rremote: Counting objects: 100% (20/20), done.\n"
            + "Receiving objects:  42% (518/1234), 1.20 MiB | 2.40 MiB/s\rReceiving objects: 100% (1234/1234), 2.85 MiB | 3.10 MiB/s, done.\n"
            + "Resolving deltas:  10% (12/120)\rResolving deltas: 100% (120/120), done.\n"
        var parser = ProgressParser()
        let events = parser.feed(Array(clone.utf8)) + parser.finish()
        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        #expect(
            progress.contains(
                OperationProgress(
                    phase: "Receiving objects", percent: 42, completed: 518, total: 1234, rate: "1.20 MiB | 2.40 MiB/s")
            ))
        #expect(progress.contains { $0.phase == "Resolving deltas" && $0.percent == 100 && $0.total == 120 })
        #expect(progress.contains { $0.phase == "Counting objects" && $0.percent == 50 })
        #expect(events.contains(.line("Cloning into 'x'...")))

        let push =
            "Enumerating objects: 5, done.\nWriting objects:  60% (3/5)\rWriting objects: 100% (5/5), 480 bytes | 480.00 KiB/s, done.\nremote: Resolving deltas: 100% (1/1)\nremote: \nremote: Create a pull request for 'x' on GitHub by visiting:\n"
        var pushParser = ProgressParser()
        let pushEvents = pushParser.feed(Array(push.utf8))
        #expect(
            pushEvents.contains {
                if case .progress(let p) = $0 { p.phase == "Writing objects" && p.percent == 60 } else { false }
            })
        #expect(pushEvents.contains(.remote("Create a pull request for 'x' on GitHub by visiting:")))

        // A chunk boundary inside a line still parses once the line completes.
        var split = ProgressParser()
        #expect(split.feed(Array("Receiving obj".utf8)).isEmpty)
        #expect(
            split.feed(Array("ects:  7% (7/100)\r".utf8)) == [
                .progress(OperationProgress(phase: "Receiving objects", percent: 7, completed: 7, total: 100))
            ])
    }

    @Test(arguments: [
        ("fatal: Unable to create '/r/.git/index.lock': File exists.", FailureKind.indexLocked),
        ("fatal: Authentication failed for 'https://example.com/x.git/'", .authenticationFailed),
        ("fatal: could not read Username for 'https://example.com': terminal prompts disabled", .authenticationFailed),
        ("remote: HTTP Basic: Access denied\nfatal: Authentication failed", .authenticationFailed),
        ("remote: Your token has expired.\nfatal: Authentication failed", .expiredToken),
        (
            "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
            .sshPublicKeyDenied
        ),
        ("Host key verification failed.\nfatal: Could not read from remote repository.", .sshHostKeyUnknown),
        ("@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n", .sshHostKeyChanged),
        ("fatal: unable to access 'https://x/': SSL certificate problem: self signed certificate", .tlsFailure),
        ("fatal: unable to access 'https://x/': server certificate verification failed. CAfile: none", .tlsFailure),
        ("fatal: unable to access 'https://x/': Received HTTP code 407 from proxy after CONNECT", .proxyFailure),
        ("fatal: unable to access 'https://x/': Failed to connect to proxy.local port 8080", .proxyFailure),
        ("fatal: unable to access 'https://nope.invalid/': Could not resolve host: nope.invalid", .hostNotFound),
        ("ssh: Could not resolve hostname nope.invalid: nodename nor servname provided, or not known", .hostNotFound),
        (
            "fatal: unable to access 'https://x/': Failed to connect to x port 443 after 75002 ms: Operation timed out",
            .connectionTimedOut
        ),
        (
            "fatal: unable to access 'https://x/': Failed to connect to 127.0.0.1 port 9: Connection refused",
            .connectionRefused
        ),
        (
            "remote: Repository not found.\nfatal: repository 'https://github.com/x/y.git/' not found",
            .remoteRepositoryNotFound
        ),
        ("fatal: '/nope' does not appear to be a git repository", .remoteRepositoryNotFound),
        (
            "error: Your local changes to the following files would be overwritten by checkout:\n\ta.txt\nPlease commit your changes or stash them before you switch branches.\nAborting",
            .dirtyWorkingTree
        ),
        (
            "error: The following untracked working tree files would be overwritten by checkout:\n\tb.txt\nPlease move or remove them before you switch branches.",
            .untrackedWouldBeOverwritten
        ),
        ("error: you need to resolve your current index first\na.txt: needs merge", .unmergedIndex),
        ("fatal: Not possible to fast-forward, aborting.", .notFastForward),
        ("error: the branch 'x' is not fully merged.", .branchNotFullyMerged),
        ("fatal: 'x' is already used by worktree at '/w'", .branchCheckedOutElsewhere),
        ("fatal: 'a..b' is not a valid branch name", .invalidName),
        ("fatal: a branch named 'x' already exists", .alreadyExists),
        ("error: unable to write file a.txt: No space left on device", .diskFull),
        ("error: open(\"a.txt\"): Permission denied", .permissionDenied),
        ("fatal: You are not currently on a branch.", .detachedHead),
        ("fatal: not a git repository (or any of the parent directories): .git", .invalidRepository),
        ("fatal: something entirely new happened", .unknown),
    ])
    func classifyMapsAll16_4Cases(stderr: String, kind: FailureKind) {
        let failure = GitErrorClassifier.classify(exitCode: 128, stderr: stderr)
        #expect(failure.kind == kind, "\(stderr)")
        #expect(!failure.summary.isEmpty)
    }

    @Test func classifierListsBlockingPaths() {
        let failure = GitErrorClassifier.classify(
            exitCode: 1,
            stderr:
                "error: Your local changes to the following files would be overwritten by checkout:\n\ta.txt\n\tdir/b c.txt\nPlease commit your changes or stash them before you switch branches.\nAborting"
        )
        #expect(failure.paths == ["a.txt", "dir/b c.txt"])
    }

    @Test func redactStripsUserinfoAndTokenPrefixes() {
        let raw =
            "fatal: unable to access 'https://ada:s3cret@github.com/x/y.git/': gho_abcdefghijklmnopqrstuvwxyz012345 ghp_abcdefghijklmnopqrstuvwxyz012345 github_pat_abcdefghijklmnopqrstuvwxyz glpat-abcdefghijklmnopqrstuv"
        let redacted = Redactor.redact(raw)
        for secret in ["s3cret", "ada:", "gho_abc", "ghp_abc", "github_pat_abc", "glpat-abc"] {
            #expect(!redacted.contains(secret), "leaked \(secret)")
        }
        let failure = GitErrorClassifier.classify(exitCode: 128, stderr: raw)
        #expect(!failure.detail.contains("s3cret"))
        #expect(RemoteInfo.masked("https://ada:s3cret@example.com/x.git") == ("https://***@example.com/x.git", true))
        #expect(RemoteInfo.masked("ssh://git@example.com/x.git").hadCredentials == false)
    }

    @Test func writerSerializesMutationsAcrossSuspension() async throws {
        let (sandbox, _, handle) = try await Ops.single()
        defer { withExtendedLifetime(sandbox) {} }
        let active = Mutex(0)
        let overlap = Mutex(false)
        let order = Mutex<[Int]>([])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    do {
                        try await handle.performExclusive("Test \(index)", invalidating: []) {
                            () throws(GitCoreError) in
                            let now = active.withLock { value in
                                value += 1
                                return value
                            }
                            if now > 1 { overlap.withLock { $0 = true } }
                            // Suspend inside the gate (a real Git process) — the gate must still hold.
                            _ = try await handle.gitEngine.run(GitCommand(["rev-parse", "HEAD"], in: handle.path))
                            try? await Task.sleep(for: .milliseconds(2))
                            order.withLock { $0.append(index) }
                            active.withLock { $0 -= 1 }
                        }
                    } catch { Issue.record("\(error)") }
                }
            }
        }
        #expect(!overlap.withLock { $0 })
        #expect(order.withLock { $0.count } == 24)
    }

    @Test func staleRevisionRejected() async throws {
        let (_, repo, handle) = try await Ops.single()
        let token = try await handle.captureState()
        try await repo.git("commit", "-q", "--allow-empty", "-m", "Made in Terminal")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.createBranch("x", startPoint: "HEAD", switchTo: false, expected: token)
        }
        do {
            _ = try await handle.createBranch("x", startPoint: "HEAD", switchTo: false, expected: token)
        } catch .staleSnapshot {
        } catch {
            Issue.record("expected staleSnapshot, got \(error)")
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
        // A fresh token works.
        _ = try await handle.createBranch(
            "x", startPoint: "HEAD", switchTo: false, expected: try await handle.captureState())
        #expect(try await repo.git("branch", "--list", "x") == "x")
    }

    @Test func confirmationTokenMustMatchAction() async throws {
        let (_, repo, handle) = try await Ops.single()
        try await repo.branch("doomed")
        let wrong = ConfirmationRequest(
            action: .deleteBranch(name: "other", force: false), title: "", context: "", changes: "", recoverability: "",
            verb: "Delete"
        ).confirm()
        await #expect(throws: GitCoreError.self) {
            try await handle.deleteBranch("doomed", token: wrong, expected: try await handle.captureState())
        }
        #expect(try await repo.git("branch", "--list", "doomed") == "doomed")
        let right = ConfirmationRequest(
            action: .deleteBranch(name: "doomed", force: false), title: "", context: "", changes: "",
            recoverability: "",
            verb: "Delete"
        ).confirm()
        try await handle.deleteBranch("doomed", token: right, expected: try await handle.captureState())
        #expect(try await repo.git("branch", "--list", "doomed") == "")
    }

    @Test func taskCancellationKillsProcessGroup() async throws {
        let sandbox = try GitSandbox()
        let marker = sandbox.root + "/grandchild.pid"
        // A child that starts a grandchild and waits: cancelling must kill both (process group).
        let runner = ProcessRunner(terminationGrace: .milliseconds(300))
        let task = Task {
            try await runner.run(
                ProcessSpec(
                    executable: "/bin/sleep", arguments: ["30"], workingDirectory: sandbox.root,
                    environment: [:]))
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: GitCoreError.self) { _ = try await task.value }
        // The child sleeps 30 s; cancellation ends it at SIGTERM (≈ms isolated; bounded for parallel debug runs).
        #expect(ContinuousClock.now - start < PerfBudget.limit(.seconds(1)))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func progressStreamDropsStaleValues() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: OperationProgress.self, bufferingPolicy: .bufferingNewest(1))
        let sink = ProgressSink(continuation, interval: .zero)
        for percent in 1...50 { sink.consume(Array("Receiving objects: \(percent)% (\(percent)/50)\r".utf8)) }
        continuation.finish()
        var seen: [Int] = []
        for await value in stream { seen.append(value.percent ?? -1) }
        // Only the newest value survives in the bounded buffer.
        #expect(seen == [50])
    }

    @Test func progressThrottledToTenHertz() async {
        let (stream, continuation) = AsyncStream.makeStream(of: OperationProgress.self, bufferingPolicy: .unbounded)
        let sink = ProgressSink(continuation, interval: .milliseconds(100))
        for percent in 1...99 { sink.consume(Array("Receiving objects: \(percent)% (\(percent)/100)\r".utf8)) }
        continuation.finish()
        // All 99 updates arrive within far less than 100 ms: only the first (phase change) is yielded.
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count <= 2)
    }

    @Test func authFailureFailsFastWithoutPrompt() async throws {
        let server = try HTTPStubServer()
        let sandbox = try GitSandbox()
        let start = ContinuousClock.now
        do {
            _ = try await cloneRepository(
                CloneRequest(url: server.url, parentDirectory: sandbox.root, name: "x", allowInsecureHTTP: true),
                engine: sandbox.engine)
            Issue.record("clone should fail")
        } catch .failed(let failure) {
            #expect(failure.kind == .authenticationFailed)
        } catch {
            Issue.record("unexpected \(error)")
        }
        // A prompt would hang forever; isolated this takes ~50 ms. Bounded generously for parallel debug runs.
        #expect(ContinuousClock.now - start < PerfBudget.limit(.seconds(1)))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root + "/x"))
    }

    @Test func noActiveProfileBlocksCommitCreatingOperations() async throws {
        let (_, repo, handle) = try await Ops.conflicting()
        let before = try await RepoFingerprint.capture(repo)
        do {
            _ = try await handle.merge(MergeRequest(source: "feature"), context: .anonymous, expected: nil)
            Issue.record("merge without a profile must be refused")
        } catch .noActiveProfile {
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(try await RepoFingerprint.capture(repo) == before)
    }
}

@Suite struct Phase5ClassifierTests {
    @Test func helperWithoutAnswerIsAuthFailure() {
        let failure = GitErrorClassifier.classify(
            exitCode: 128, stderr: "fatal: unable to get password from user\n")
        #expect(failure.kind == .authenticationFailed)
    }
}
