import Foundation
import GitCore
import Synchronization
import Testing

@testable import Services

@MainActor @Suite struct AuthFailureExplainerTests {
    static let ada = GitIdentity(name: "Ada", email: "ada@example.com")

    func failure(_ kind: FailureKind) -> PresentableError {
        PresentableError.make(.failed(ClassifiedFailure(kind: kind, summary: "x", detail: "d")))
    }

    func snapshot(account: HostingAccount?, instance: ProviderInstance = .github, ssh: SSHIdentity? = nil)
        -> ProfileSnapshot
    {
        let profile = GitProfile(
            displayName: "Personal GitHub", colorIndex: 0, author: Self.ada,
            auth: ProfileAuth(instanceID: instance.id, accountID: account?.id, ssh: ssh))
        return ProfileSnapshot(profile, account: account, instance: instance)
    }

    @Test func noAccountForHostOffersSwitchToMatchingProfile() {
        let work = GitProfile(displayName: "Work GitLab", colorIndex: 1, author: Self.ada)
        let resolution = AccessResolution(
            policy: BrokerPolicy(), ssh: nil, network: [], mismatches: [.noAccountForHost(host: "gitlab.corp.example")],
            remoteHosts: ["gitlab.corp.example"])
        let result = AuthFailureExplainer.explain(
            failure(.authenticationFailed), snapshot: snapshot(account: nil), resolution: resolution,
            candidates: [work])
        #expect(result.title == "The active profile “Personal GitHub” has no account for gitlab.corp.example.")
        #expect(result.actions.first == .switchProfileAndRetry)
        #expect(result.profileSwitches == [ProfileSwitch(profileID: work.id, name: "Work GitLab")])
        #expect(result.explanation.contains("never uses another profile"))
    }

    @Test func rejectedTokenNamesAccountAndExpiry() {
        var account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        account.expiresAt = Date(timeIntervalSince1970: 1_000)
        let resolution = AccessResolution(
            policy: BrokerPolicy(https: [.init(accountID: account.id, host: "github.com", port: 443)]), ssh: nil,
            network: [], mismatches: [], remoteHosts: ["github.com"])
        let result = AuthFailureExplainer.explain(
            failure(.authenticationFailed), snapshot: snapshot(account: account), resolution: resolution, candidates: []
        )
        #expect(result.title.hasPrefix("GitHub rejected the token for @ada (expired on"))
        #expect(result.actions == [.manageAccounts])
    }

    @Test func notFoundWithAccountIsExplainedAsNoAccess() {
        let account = HostingAccount(instanceID: .github, login: "ada-oss", userID: "2", method: .pat)
        let resolution = AccessResolution(
            policy: BrokerPolicy(https: [.init(accountID: account.id, host: "github.com", port: 443)]), ssh: nil,
            network: [], mismatches: [], remoteHosts: ["github.com"])
        let result = AuthFailureExplainer.explain(
            failure(.remoteRepositoryNotFound), snapshot: snapshot(account: account), resolution: resolution,
            candidates: [], remoteURLs: ["https://github.com/acme/private-repo.git"])
        #expect(result.title == "@ada-oss can't access acme/private-repo.")
    }

    @Test func sshKeyRefusedNamesKeyAndFingerprint() {
        let result = AuthFailureExplainer.explain(
            failure(.sshPublicKeyDenied),
            snapshot: snapshot(account: nil, ssh: .keyFile(path: "/k/id_oss", fingerprint: "SHA256:abc")),
            resolution: nil,
            candidates: [], remoteURLs: ["git@github.com:acme/app.git"])
        #expect(result.explanation.contains("id_oss (SHA256:abc)"))
    }

    @Test func unknownHostKeyCarriesTarget() {
        let result = AuthFailureExplainer.explain(
            failure(.sshHostKeyUnknown), snapshot: nil, resolution: nil, candidates: [],
            remoteURLs: ["ssh://git@git.corp.example:2222/a/b.git"])
        #expect(result.hostKey == HostKeyTarget(host: "git.corp.example", port: 2222))
        #expect(result.actions == [.trustHostKey])
    }

    @Test func otherFailuresUntouched() {
        let original = failure(.pushRejected)
        #expect(AuthFailureExplainer.explain(original, snapshot: nil, resolution: nil, candidates: []) == original)
    }

    @Test func switchCandidatesMatchHostsNeverActiveProfile() {
        let store = ProfileStore(location: TempLocation().location)
        let accounts = AccountsService(profiles: store, secrets: MemorySecretStore(), location: TempLocation().location)
        let active = GitProfile(
            displayName: "A", colorIndex: 0, author: Self.ada, auth: ProfileAuth(instanceID: .github))
        let other = GitProfile(
            displayName: "B", colorIndex: 1, author: Self.ada, auth: ProfileAuth(instanceID: .github))
        let lab = GitProfile(displayName: "C", colorIndex: 2, author: Self.ada, auth: ProfileAuth(instanceID: .gitlab))
        store.create(active, activate: true)
        store.create(other)
        store.create(lab)
        #expect(accounts.switchCandidates(for: ["github.com"]).map(\.displayName) == ["B"])
    }
}

@Suite struct KnownHostsTests {
    @Test func hashedEntriesMatchOnlyTheirHost() throws {
        let path = NSTemporaryDirectory() + "jit-kh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = KnownHostsStore(path: path)
        let key = SSHHostKey(
            host: "git.corp.example", port: 2222, type: "ssh-ed25519",
            key: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl", fingerprint: "x")
        try store.trust(key)
        try store.trust(key)  // idempotent
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
        #expect(!text.contains("git.corp.example"))
        #expect(store.entries(host: "git.corp.example", port: 2222) == [.init(type: "ssh-ed25519", key: key.key)])
        #expect(store.entries(host: "git.corp.example", port: 22).isEmpty)
        var changed = key
        changed.key = "AAAAC3NzaC1lZDI1NTE5AAAAIJdD7y3aLq454yWBdwLWbieU1ebz9/cu7/QEXn9OIeZJ"
        #expect(throws: KnownHostsError.changedKey) { try store.trust(changed) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func openSSHFingerprintFormat() {
        // GitHub's published ed25519 host key and fingerprint.
        let fingerprint = SSHTools.fingerprint(
            type: "ssh-ed25519", base64: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        #expect(fingerprint == "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
    }
}

@Suite struct NetworkPolicyTests {
    @Test func proxyExceptionPatterns() {
        #expect(SystemProxyResolver.matches(host: "git.corp.example", pattern: "*.corp.example"))
        #expect(SystemProxyResolver.matches(host: "git.corp.example", pattern: ".corp.example"))
        #expect(!SystemProxyResolver.matches(host: "corp.example.evil", pattern: "*.corp.example"))
        #expect(SystemProxyResolver.matches(host: "printer.local", pattern: "*.local"))
    }

    @Test func manualAndDirectModes() async {
        let resolver = SystemProxyResolver(settings: { [:] })
        let url = RemoteURL.parse("https://github.com/a/b")!
        let proxy = ManualProxy(kind: .socks5, host: "socks.corp", port: 1080)
        #expect(await resolver.resolve(url, mode: .manual(proxy), global: .direct).proxy == proxy)
        #expect(await resolver.resolve(url, mode: .inheritGlobal, global: .direct).source == .direct)
        #expect(await resolver.resolve(url, mode: .direct, global: .manual(proxy)).source == .direct)
    }

    @Test func invalidManualProxyNeverReachesGit() {
        #expect(!ManualProxy(kind: .http, host: "-oProxyCommand=evil", port: 80).isValid)
        #expect(!ManualProxy(kind: .http, host: "proxy corp", port: 80).isValid)
        #expect(!ManualProxy(kind: .http, host: "proxy.corp", port: 70_000).isValid)
        #expect(ManualProxy(kind: .http, host: "10.0.0.1", port: 3128).isValid)
    }

    @Test func vpnHints() {
        #expect(NetworkHints.looksInternal(host: "gitlab"))
        #expect(NetworkHints.looksInternal(host: "git.corp"))
        #expect(NetworkHints.looksInternal(host: "192.168.1.20"))
        #expect(!NetworkHints.looksInternal(host: "github.com"))
        #expect(NetworkHints.vpnHint(host: "github.com") == nil)
    }
}

final class FakePathMonitor: PathMonitoring, @unchecked Sendable {
    var handler: (@Sendable (PathSnapshot) -> Void)?
    func start(_ handler: @escaping @Sendable (PathSnapshot) -> Void) { self.handler = handler }
    func cancel() { handler = nil }
}

@MainActor @Suite struct ConnectivityTests {
    @Test func backOnlineOnlyAfterAnOfflineFailure() {
        let monitor = FakePathMonitor()
        let state = ConnectivityState(monitor: monitor)
        state.start()
        state.apply(PathSnapshot(status: .unsatisfied))
        state.apply(PathSnapshot(status: .satisfied))
        #expect(!state.backOnline)
        state.apply(PathSnapshot(status: .unsatisfied))
        state.noteOfflineFailure()
        state.apply(PathSnapshot(status: .satisfied))
        #expect(state.backOnline)
        state.acknowledge()
        #expect(!state.backOnline)
    }

    @Test func offlineFailsRemoteOperationFastWithoutSpawningGit() async throws {
        let monitor = FakePathMonitor()
        let state = ConnectivityState(monitor: monitor)
        state.start()
        monitor.handler?(PathSnapshot(status: .unsatisfied))
        let spawned = Mutex(0)
        // Other suites spawn processes in parallel: count only ones that would contact this remote.
        ProcessRunner.spawnObserver.withLock { observer in
            observer = { spec in
                if spec.arguments.contains(where: { $0.contains("github.com/a/b") }) { spawned.withLock { $0 += 1 } }
            }
        }
        defer { ProcessRunner.spawnObserver.withLock { $0 = nil } }
        let provider = ProfileAccessProvider(
            snapshot: nil,
            environment: AccessEnvironment(
                userKnownHosts: "/a", jitKnownHosts: "/b", caDirectory: "/c", agentAvailable: false),
            helperPath: "/usr/bin/false", credentials: FakeCredentialSource(token: "x"), connectivity: state.checker)
        await #expect(throws: GitCoreError.self) {
            _ = try await provider.prepare(for: ["https://github.com/a/b"], purpose: .fetch)
        }
        #expect(spawned.withLock { $0 } == 0)
        // Local file remotes still work offline.
        _ = try await provider.prepare(for: ["/tmp/repo.git"], purpose: .fetch)
    }
}

@Suite struct CAStoreTests {
    static let rigCerts = NSHomeDirectory() + "/Library/Caches/jit-rig/certs"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: rigCerts + "/ca.pem")))
    func leafRejectedAndCAImported() throws {
        let store = CAStore(directory: NSTemporaryDirectory() + "jit-ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        let leaf = try Data(contentsOf: URL(fileURLWithPath: Self.rigCerts + "/leaf-selfsigned.pem"))
        #expect(throws: CertificateImportError.self) { try store.importCA(leaf) }
        let ca = try Data(contentsOf: URL(fileURLWithPath: Self.rigCerts + "/ca.pem"))
        let info = try store.importCA(ca)
        #expect(info.isCA)
        #expect(info.sha256.split(separator: ":").count == 32)
        #expect(store.load(info.id)?.1.subject == info.subject)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path(info.id))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func garbageIsUnreadable() {
        #expect(throws: CertificateImportError.unreadable) { try CAStore.inspect(Data("hello".utf8)) }
    }

    @Test func expiryHelpers() {
        let soon = CertificateInfo(
            id: "x", subject: "s", issuer: "s", notBefore: nil, notAfter: Date().addingTimeInterval(86_400),
            sha256: "", isCA: true, isSelfSigned: true)
        #expect(soon.expiresSoon())
        #expect(!soon.isExpired())
    }
}

/// `noInsecureTLSSettingsAnywhere`: no code path disables TLS or host-key verification (security checklist §4.11).
@Suite struct InsecureSettingsLintTests {
    @Test func noInsecureTLSOrHostKeySettingsInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let forbidden = [
            "sslVerify", "GIT_SSL_NO_VERIFY", "StrictHostKeyChecking=no", "StrictHostKeyChecking=accept-new",
            "kSecTrustResultProceed", "allowsExpiredCertificates", "disableEvaluation",
        ]
        var scanned = 0
        for directory in ["GitCore", "Services", "Features", "JitGitHelper"] {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let file as String in enumerator where file.hasSuffix(".swift") {
                scanned += 1
                let text = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
                for pattern in forbidden {
                    #expect(!text.contains(pattern), "\(directory)/\(file) contains \(pattern)")
                }
            }
        }
        #expect(scanned > 50)
    }
}
