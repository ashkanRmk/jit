import Foundation
import GitCore
import GitTestKit
import Synchronization
import Testing

@testable import Services

/// The local enterprise rig (ADR-0039): `scripts/testing/enterprise-rig/up.sh`, then `JIT_RIG=1 swift test --filter Rig`.
enum Rig {
    static let values: [String: String] = {
        let env = ProcessInfo.processInfo.environment
        let dir = env["JIT_RIG_DIR"] ?? NSHomeDirectory() + "/Library/Caches/jit-rig"
        guard let text = try? String(contentsOfFile: dir + "/rig.env", encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("export ") {
            let pair = line.dropFirst("export ".count)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            values[String(pair[..<equals])] = String(pair[pair.index(after: equals)...]).replacingOccurrences(
                of: "\\ ", with: " ")
        }
        return values
    }()

    static var enabled: Bool { ProcessInfo.processInfo.environment["JIT_RIG"] == "1" && !values.isEmpty }
    static func value(_ key: String) -> String { values[key] ?? "" }
    static func port(_ key: String) -> Int { Int(value(key)) ?? 0 }
}

@MainActor @Suite(.serialized, .enabled(if: Rig.enabled, "set JIT_RIG=1 and run the enterprise rig"))
struct RigIntegrationTests {
    nonisolated static let ada = GitIdentity(name: "Ada Lovelace", email: "ada@example.com")

    struct Fixture {
        let sandbox: GitSandbox
        let caStore: CAStore
        let environment: AccessEnvironment
        let secrets = MemorySecretStore()
        let helper: String

        init() throws {
            sandbox = try GitSandbox()
            caStore = CAStore(directory: sandbox.root + "/appsupport/ca")
            environment = AccessEnvironment(
                userKnownHosts: sandbox.root + "/home/.ssh/known_hosts",
                jitKnownHosts: sandbox.root + "/appsupport/known_hosts", caDirectory: caStore.directory,
                agentAvailable: false)
            helper = try #require(HelperBinary.path)
        }

        func instance(ca: String?, port: Int = Rig.port("JIT_RIG_HTTPS_PORT"), proxy: ProxyMode = .direct)
            throws -> ProviderInstance
        {
            var ids: [String] = []
            if let ca { ids = [try caStore.importCA(try Data(contentsOf: URL(fileURLWithPath: ca))).id] }
            let base = try #require(URL(string: "https://127.0.0.1:\(port)"))
            return ProviderInstance(
                id: .new(), kind: .gitlab, name: "Rig", webBaseURL: base,
                sshHost: "127.0.0.1", sshPort: Rig.port("JIT_RIG_SSH_PORT"), caCertificateIDs: ids, proxy: proxy)
        }

        func context(
            instance: ProviderInstance?, token: String?, ssh: SSHIdentity? = nil, login: String = "ada",
            proxies: (any ProxyResolving)? = nil
        ) async throws -> (ExecContext, ProfileAccessProvider) {
            var account: HostingAccount?
            if let instance, let token {
                let created = HostingAccount(instanceID: instance.id, login: login, userID: "1", method: .pat)
                try await secrets.store(SecretBytes(utf8: token), for: .account(created.id), label: "t")
                account = created
            }
            let profile = GitProfile(
                displayName: "Rig", colorIndex: 0, author: RigIntegrationTests.ada,
                auth: instance.map { ProfileAuth(instanceID: $0.id, accountID: account?.id, ssh: ssh) })
            let snapshot = ProfileSnapshot(profile, account: account, instance: instance)
            let source = KeychainCredentialSource(
                store: secrets, accounts: account.map { [$0] } ?? [], instances: instance.map { [$0] } ?? [],
                status: { _, _ in }, prompt: nil)
            let provider = ProfileAccessProvider(
                snapshot: snapshot, environment: environment, helperPath: helper, credentials: source,
                proxies: proxies ?? SystemProxyResolver(settings: { [:] }), caStore: caStore)
            return (
                ExecContext(identity: snapshot.identity, auth: .profile(RemoteAccessProviderRef(provider))), provider
            )
        }

        func clone(_ url: String, context: ExecContext, name: String = "clone") async throws(GitCoreError)
            -> CloneOutcome
        {
            try await cloneRepository(
                CloneRequest(url: url, parentDirectory: sandbox.root, name: name), engine: sandbox.engine,
                context: context)
        }
    }

    static var httpsURL: String { "https://127.0.0.1:\(Rig.port("JIT_RIG_HTTPS_PORT"))/git/project.git" }

    func failureKind(_ body: () async throws(GitCoreError) -> Void) async -> FailureKind? {
        do throws(GitCoreError) {
            try await body()
            return nil
        } catch {
            if case .failed(let failure) = error { return failure.kind }
            return .unknown
        }
    }

    @Test func httpsCloneAndPushWithPATAndCustomCA() async throws {
        let fixture = try Fixture()
        let instance = try fixture.instance(ca: Rig.value("JIT_RIG_CA"))
        let (context, _) = try await fixture.context(instance: instance, token: "rig-token-ada")
        let outcome = try await fixture.clone(Self.httpsURL, context: context)
        let repo = TestRepo(sandbox: fixture.sandbox, path: outcome.path)
        try repo.write("rig-\(UUID().uuidString).txt", "hello")
        _ = try await repo.git("add", ".")
        _ = try await repo.commit("Rig push")
        let handle = try await fixture.sandbox.engine.openRepository(at: URL(fileURLWithPath: outcome.path))
        let branch = try await repo.git("rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let pushed = try await handle.push(
            PushRequest(remote: "origin", localBranch: branch, remoteBranch: branch), context: context)
        #expect(pushed.rejection == nil)
        #expect(!pushed.cancelled)
    }

    @Test func tlsFailsWithoutOrWithWrongCAAndNeverBypasses() async throws {
        let fixture = try Fixture()
        for ca in [nil, Rig.value("JIT_RIG_OTHER_CA")] {
            let instance = try fixture.instance(ca: ca)
            let (context, _) = try await fixture.context(instance: instance, token: "rig-token-ada")
            let kind = await failureKind { () throws(GitCoreError) in
                _ = try await fixture.clone(Self.httpsURL, context: context, name: "tls-\(UUID().uuidString.prefix(4))")
            }
            #expect(kind == .tlsFailure)
        }
    }

    @Test func wrongTokenFailsAsAuthAndMarksNoFallback() async throws {
        let fixture = try Fixture()
        let instance = try fixture.instance(ca: Rig.value("JIT_RIG_CA"))
        let (context, _) = try await fixture.context(instance: instance, token: "not-a-valid-token")
        let kind = await failureKind { () throws(GitCoreError) in
            _ = try await fixture.clone(Self.httpsURL, context: context)
        }
        #expect(kind == .authenticationFailed)
    }

    @Test func noAccountForHostRunsAnonymouslyAndExplainsMismatch() async throws {
        let fixture = try Fixture()
        // The profile's account is for GitHub; the remote is the rig.
        let (context, provider) = try await fixture.context(instance: .github, token: "rig-token-ada")
        let kind = await failureKind { () throws(GitCoreError) in
            _ = try await fixture.clone(Self.httpsURL, context: context)
        }
        #expect(kind == .tlsFailure || kind == .authenticationFailed)
        let resolution = provider.lastResolution.withLock { $0 }
        #expect(resolution?.mismatches == [.noAccountForHost(host: "127.0.0.1")])
        #expect(resolution?.policy.https.isEmpty == true)
    }

    @Test func httpsThroughAuthenticatingProxyWithBrokeredPassword() async throws {
        let fixture = try Fixture()
        let proxy = ManualProxy(
            kind: .http, host: "127.0.0.1", port: Rig.port("JIT_RIG_PROXY_AUTH_PORT"),
            username: Rig.value("JIT_RIG_PROXY_USER"))
        try await fixture.secrets.store(
            SecretBytes(utf8: Rig.value("JIT_RIG_PROXY_PASSWORD")), for: .proxy(proxy.id), label: "p")
        let instance = try fixture.instance(ca: Rig.value("JIT_RIG_CA"), proxy: .manual(proxy))
        let seen = Mutex<[String]>([])
        ProcessRunner.spawnObserver.withLock { observer in
            observer = { spec in
                seen.withLock {
                    $0.append(
                        (spec.arguments + spec.environment.map { "\($0.key)=\($0.value)" }).joined(separator: " "))
                }
            }
        }
        defer { ProcessRunner.spawnObserver.withLock { $0 = nil } }
        let (context, _) = try await fixture.context(instance: instance, token: "rig-token-ada")
        let logPath = Rig.value("JIT_RIG_LOGS") + "/proxy-auth-tunnels.log"
        let before = (try? String(contentsOfFile: logPath, encoding: .utf8))?.count ?? 0
        _ = try await fixture.clone(Self.httpsURL, context: context)
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        #expect(log.count > before, "the clone didn't go through the authenticating proxy (\(logPath))")
        // proxyCredentialsNeverInArgv / sentinel: neither the proxy password nor the token in argv or env.
        let spawned = seen.withLock { $0 }
        #expect(
            spawned.allSatisfy { !$0.contains(Rig.value("JIT_RIG_PROXY_PASSWORD")) && !$0.contains("rig-token-ada") })
    }

    // MARK: SSH (rig sshd)

    static var sshURL: String {
        "ssh://\(Rig.value("JIT_RIG_SSH_USER"))@127.0.0.1:\(Rig.port("JIT_RIG_SSH_PORT"))\(Rig.value("JIT_RIG_REPOS"))/project.git"
    }

    func trustRigHost(_ fixture: Fixture) async throws {
        let keys = await SSHTools.scanHostKeys(host: "127.0.0.1", port: Rig.port("JIT_RIG_SSH_PORT"))
        let key = try #require(keys.first { $0.displayType == "ED25519" })
        try KnownHostsStore(path: fixture.environment.jitKnownHosts).trust(key)
    }

    @Test func sshUnknownHostFailsWithoutTrust() async throws {
        let fixture = try Fixture()
        let instance = try fixture.instance(ca: nil)
        let (context, _) = try await fixture.context(
            instance: instance, token: nil, ssh: .keyFile(path: Rig.value("JIT_RIG_CLIENT_KEY"), fingerprint: "x"))
        let kind = await failureKind { () throws(GitCoreError) in
            _ = try await fixture.clone(Self.sshURL, context: context)
        }
        #expect(kind == .sshHostKeyUnknown)
        #expect(!FileManager.default.fileExists(atPath: fixture.environment.jitKnownHosts))
    }

    @Test func sshTrustWritesOnlyJitKnownHostsThenKeyAuthWorks() async throws {
        let fixture = try Fixture()
        let userSSH = NSHomeDirectory() + "/.ssh"
        let before = Self.hashes(userSSH)
        try await trustRigHost(fixture)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.environment.jitKnownHosts)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOfFile: fixture.environment.jitKnownHosts, encoding: .utf8)
        #expect(text.hasPrefix("|1|"))  // hashed host
        #expect(!text.contains("127.0.0.1"))
        let instance = try fixture.instance(ca: nil)
        let (context, _) = try await fixture.context(
            instance: instance, token: nil, ssh: .keyFile(path: Rig.value("JIT_RIG_CLIENT_KEY"), fingerprint: "x"))
        let outcome = try await fixture.clone(Self.sshURL, context: context)
        #expect(FileManager.default.fileExists(atPath: outcome.path + "/.git"))
        #expect(Self.hashes(userSSH) == before, "~/.ssh changed")
    }

    @Test func sshPassphraseViaAskpassAndKeyPathWithSpaces() async throws {
        let fixture = try Fixture()
        try await trustRigHost(fixture)
        // Copy the passphrase key to a path with spaces and quotes.
        let directory = fixture.sandbox.root + "/keys dir/it's"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let key = directory + "/id ed25519"
        try FileManager.default.copyItem(atPath: Rig.value("JIT_RIG_CLIENT_KEY_PASS"), toPath: key)
        chmod(key, 0o600)
        let instance = try fixture.instance(ca: nil)
        let account = HostingAccountID.new()
        _ = account
        let profile = GitProfile(
            displayName: "Rig", colorIndex: 0, author: Self.ada,
            auth: ProfileAuth(instanceID: instance.id, ssh: .keyFile(path: key, fingerprint: "SHA256:test")))
        let snapshot = ProfileSnapshot(profile, instance: instance)
        let prompted = Mutex(0)
        let source = KeychainCredentialSource(
            store: fixture.secrets, accounts: [], instances: [instance], status: { _, _ in },
            prompt: { path, _ in
                prompted.withLock { $0 += 1 }
                return path == key ? (SecretBytes(utf8: Rig.value("JIT_RIG_CLIENT_KEY_PASSPHRASE")), false) : nil
            })
        let provider = ProfileAccessProvider(
            snapshot: snapshot, environment: fixture.environment, helperPath: fixture.helper, credentials: source,
            caStore: fixture.caStore)
        let context = ExecContext(identity: snapshot.identity, auth: .profile(RemoteAccessProviderRef(provider)))
        let result: Result<CloneOutcome, GitCoreError>
        do throws(GitCoreError) { result = .success(try await fixture.clone(Self.sshURL, context: context)) } catch {
            result = .failure(error)
        }
        #expect(prompted.withLock { $0 } == 1)
        let outcome = try result.get()
        #expect(FileManager.default.fileExists(atPath: outcome.path + "/.git"))
    }

    @Test func sshChangedHostKeyHardError() async throws {
        let fixture = try Fixture()
        // A different ED25519 key recorded for the rig host → ssh refuses (changed key), trust() refuses too.
        let fake = SSHHostKey(
            host: "127.0.0.1", port: Rig.port("JIT_RIG_SSH_PORT"), type: "ssh-ed25519",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAIJdD7y3aLq454yWBdwLWbieU1ebz9/cu7/QEXn9OIeZJ", fingerprint: "x")
        try KnownHostsStore(path: fixture.environment.jitKnownHosts).trust(fake)
        let instance = try fixture.instance(ca: nil)
        let (context, _) = try await fixture.context(
            instance: instance, token: nil, ssh: .keyFile(path: Rig.value("JIT_RIG_CLIENT_KEY"), fingerprint: "x"))
        let kind = await failureKind { () throws(GitCoreError) in
            _ = try await fixture.clone(Self.sshURL, context: context)
        }
        #expect(kind == .sshHostKeyChanged)
        let real = try #require(
            await SSHTools.scanHostKeys(host: "127.0.0.1", port: Rig.port("JIT_RIG_SSH_PORT")).first {
                $0.displayType == "ED25519"
            })
        #expect(throws: KnownHostsError.changedKey) {
            try KnownHostsStore(path: fixture.environment.jitKnownHosts).trust(real)
        }
    }

    @Test func sshStrictModeIgnoresUserIdentityFile() async throws {
        let fixture = try Fixture()
        try await trustRigHost(fixture)
        // Agent-only profile with no agent: strict mode must not fall back to ~/.ssh/id_* files.
        let instance = try fixture.instance(ca: nil)
        let (context, _) = try await fixture.context(instance: instance, token: nil, ssh: .agent)
        let kind = await failureKind { () throws(GitCoreError) in
            _ = try await fixture.clone(Self.sshURL, context: context)
        }
        #expect(kind == .sshPublicKeyDenied)
    }

    static func hashes(_ directory: String) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in ["config", "known_hosts"] {
            if let data = FileManager.default.contents(atPath: directory + "/" + name) { result[name] = data }
        }
        if let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.gitconfig") {
            result["gitconfig"] = data
        }
        return result
    }
}
