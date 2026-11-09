import Darwin
import Foundation
import GitCore
import Security
import Synchronization
import Testing

@testable import Services

// MARK: Test doubles

/// A probe whose every answer is chosen by the test; records the calls it receives.
final class StubDiagnosticsProbe: DiagnosticsProbing {
    struct Answers: Sendable {
        var dns: DNSOutcome = .resolved(["10.1.2.3"])
        var tcp: @Sendable (_ host: String, _ port: Int, _ proxy: DiagnosticsProxy?) -> TCPOutcome = { _, _, _ in
            .connected
        }
        var tls: TLSOutcome = .trusted(
            leaf: CertificateSummary(subject: "git.example.com", issuer: "Example CA", names: ["git.example.com"]),
            anchor: .system("Example Root"))
        var keys: [SSHHostKey] = []
    }

    let answers: Answers
    let calls = Mutex<[String]>([])

    init(_ answers: Answers = Answers()) { self.answers = answers }

    var recorded: [String] { calls.withLock { $0 } }

    func resolve(host: String) async -> DNSOutcome {
        calls.withLock { $0.append("dns \(host)") }
        return answers.dns
    }

    func connect(host: String, port: Int, via proxy: DiagnosticsProxy?, timeout: Duration) async -> TCPOutcome {
        calls.withLock { $0.append("tcp \(host):\(port)\(proxy == nil ? "" : " via proxy")") }
        return answers.tcp(host, port, proxy)
    }

    func handshake(
        host: String, port: Int, anchors: [SecCertificate], via proxy: DiagnosticsProxy?, timeout: Duration
    ) async -> TLSOutcome {
        calls.withLock { $0.append("tls \(host):\(port)") }
        return answers.tls
    }

    func scanHostKeys(host: String, port: Int) async -> [SSHHostKey] {
        calls.withLock { $0.append("ssh-keyscan \(host):\(port)") }
        return answers.keys
    }
}

struct FixedProxyResolver: ProxyResolving {
    let result: ResolvedProxy
    func resolve(_ url: RemoteURL, mode: ProxyMode, global: ProxyMode) async -> ResolvedProxy { result }
}

// MARK: Unit tests (no network)

@Suite struct DiagnosticsTests {
    static let sentinel = "glpat-SENTINELsecretTOKEN1234"
    static let hostKey = SSHHostKey(
        host: "git.example.com", port: 22, type: "ssh-ed25519",
        key: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
        fingerprint: SSHTools.fingerprint(
            type: "ssh-ed25519", base64: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
            ?? "")

    let directory: String

    init() throws {
        directory = NSTemporaryDirectory() + "jit-diagnostics-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    func instance(
        kind: ProviderKind = .gitlab, url: String = "https://git.example.com", sshHost: String = "git.example.com",
        proxy: ProxyMode = .direct
    ) throws -> ProviderInstance {
        ProviderInstance(
            id: ProviderInstanceID(rawValue: "test"), kind: kind, name: "Example", webBaseURL: try providerURL(url),
            sshHost: sshHost, proxy: proxy)
    }

    static func account(_ instance: ProviderInstance) -> HostingAccount {
        HostingAccount(instanceID: instance.id, login: "ada", userID: "1", method: .pat)
    }

    /// GitLab answering `/version` (17.5) and `/user` (ada) unless `handler` says otherwise.
    static func gitlab(_ handler: (@Sendable (URLRequest) -> ProviderStubResponse?)? = nil) -> ProviderStubTransport {
        ProviderStubTransport { request in
            if let custom = handler?(request) { return custom }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/version") { return .json(#"{"version":"17.5.0","revision":"x"}"#) }
            if path.hasSuffix("/user") { return .json(#"{"id":1,"username":"ada","name":"Ada"}"#) }
            return .json(#"{"message":"404 Not Found"}"#, status: 404)
        }
    }

    func runner(
        _ instance: ProviderInstance, account: HostingAccount? = nil, path: PathSnapshot = .init(status: .satisfied),
        transport: any HTTPTransport = DiagnosticsTests.gitlab(), probe: StubDiagnosticsProbe = StubDiagnosticsProbe(),
        proxy: ResolvedProxy = .direct
    ) -> DiagnosticsRunner {
        DiagnosticsRunner(
            configuration: .init(
                instance: instance, account: account, path: path, jitKnownHosts: directory + "/jit_known_hosts",
                userKnownHosts: directory + "/user_known_hosts"),
            transport: transport, token: account.map { _ -> TokenProvider in { SecretBytes(utf8: Self.sentinel) } },
            proxyResolver: FixedProxyResolver(result: proxy), probe: probe)
    }

    func statuses(_ steps: [DiagnosticStep]) -> [DiagnosticStatus] { steps.map(\.status) }

    func step(_ steps: [DiagnosticStep], _ id: DiagnosticStepID) -> DiagnosticStep { steps[id.rawValue - 1] }

    @Test func healthyServerPassesEveryStep() async throws {
        let instance = try instance()
        var answers = StubDiagnosticsProbe.Answers()
        answers.keys = [Self.hostKey]
        try KnownHostsStore(path: directory + "/jit_known_hosts").trust(Self.hostKey)
        let steps = await runner(instance, account: Self.account(instance), probe: StubDiagnosticsProbe(answers))
            .runToCompletion()
        #expect(statuses(steps) == Array(repeating: .passed, count: 8))
        #expect(step(steps, .http).result.contains("GitLab 17.5.0"))
        #expect(step(steps, .authentication).result == "Signed in as @ada.")
        #expect(step(steps, .ssh).result.contains("Jit's known_hosts"))
        #expect(step(steps, .tls).details.contains("Trusted through: macOS root certificate “Example Root”"))
    }

    @Test func offlineSkipsEverythingWithoutTouchingTheNetwork() async throws {
        let probe = StubDiagnosticsProbe()
        let transport = Self.gitlab()
        let instance = try instance()
        let steps = await runner(
            instance, account: Self.account(instance), path: .init(status: .unsatisfied), transport: transport,
            probe: probe
        ).runToCompletion()
        #expect(step(steps, .networkPath).status == .failed)
        #expect(step(steps, .networkPath).result == "You're offline.")
        #expect(steps.dropFirst().allSatisfy { $0.status == .skipped })
        #expect(probe.recorded.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func vpnInterfaceIsReported() {
        let step = DiagnosticsRunner.networkStep(PathSnapshot(status: .satisfied, vpnInterface: true))
        #expect(step.status == .passed)
        #expect(step.details.contains("A VPN connection appears to be active."))
    }

    @Test func nameNotFoundForInternalHostAddsVPNHintAndSkipsDependents() async throws {
        var answers = StubDiagnosticsProbe.Answers()
        answers.dns = .notFound
        let probe = StubDiagnosticsProbe(answers)
        let instance = try instance(url: "https://git.corp", sshHost: "git.corp")
        let steps = await runner(instance, account: Self.account(instance), probe: probe).runToCompletion()
        let dns = step(steps, .dns)
        #expect(dns.status == .failed)
        #expect(dns.result == "Name not found.")
        #expect(dns.explanation == "If this server is on your company network, connect your VPN and try again.")
        for id in [DiagnosticStepID.tcp, .tls, .http, .authentication, .ssh] {
            #expect(step(steps, id).status == .skipped, "\(id)")
        }
        #expect(step(steps, .tcp).result.contains("name couldn't be found"))
        #expect(!probe.recorded.contains { $0.hasPrefix("tcp") || $0.hasPrefix("tls") })
    }

    @Test func nameNotFoundForPublicHostSuggestsCheckingTheAddress() {
        let step = DiagnosticsRunner.dnsStep(.notFound, host: "git.example.com", proxy: nil)
        #expect(step.status == .failed)
        #expect(step.explanation?.contains("typos") == true)
    }

    @Test func nameNotFoundBehindAProxyIsOnlyAWarning() async throws {
        var answers = StubDiagnosticsProbe.Answers()
        answers.dns = .notFound
        let probe = StubDiagnosticsProbe(answers)
        let proxy = ManualProxy(kind: .http, host: "proxy.example.com", port: 3128)
        let steps = await runner(try instance(), probe: probe, proxy: ResolvedProxy(proxy: proxy, source: .pac))
            .runToCompletion()
        #expect(step(steps, .dns).status == .warning)
        #expect(step(steps, .proxy).status == .passed)
        #expect(step(steps, .proxy).result.contains("PAC"))
        #expect(step(steps, .tcp).status == .passed)
        #expect(probe.recorded.contains("tcp git.example.com:443 via proxy"))
    }

    @Test func unreachableManualProxyFailsAndSkipsHTTPSSteps() async throws {
        let proxy = ManualProxy(kind: .socks5, host: "proxy.example.com", port: 1080)
        var answers = StubDiagnosticsProbe.Answers()
        answers.tcp = { host, _, _ in host == "proxy.example.com" ? .refused : .connected }
        let steps = await runner(
            try instance(proxy: .manual(proxy)), probe: StubDiagnosticsProbe(answers),
            proxy: ResolvedProxy(proxy: proxy, source: .manual)
        ).runToCompletion()
        let proxyStep = step(steps, .proxy)
        #expect(proxyStep.status == .failed)
        #expect(proxyStep.result.contains("Manual proxy SOCKS5 proxy.example.com:1080"))
        #expect(proxyStep.result.contains("connection refused"))
        #expect(step(steps, .tcp).status == .skipped)
        #expect(step(steps, .http).status == .skipped)
    }

    @Test func refusedAndTimedOutAreDistinguished() async throws {
        var refused = StubDiagnosticsProbe.Answers()
        refused.tcp = { _, port, _ in port == 443 ? .refused : .connected }
        let a = await runner(try instance(), probe: StubDiagnosticsProbe(refused)).runToCompletion()
        #expect(step(a, .tcp).status == .failed)
        #expect(step(a, .tcp).result == "Connection refused by git.example.com:443.")
        #expect(step(a, .tcp).explanation?.contains("port 443") == true)
        #expect(step(a, .tls).status == .skipped)
        #expect(step(a, .http).status == .skipped)

        var timedOut = StubDiagnosticsProbe.Answers()
        timedOut.tcp = { _, port, _ in port == 443 ? .timedOut : .connected }
        let b = await runner(try instance(), probe: StubDiagnosticsProbe(timedOut)).runToCompletion()
        #expect(step(b, .tcp).result == "No answer from git.example.com:443 within 10 seconds.")
        #expect(step(b, .tcp).explanation?.contains("firewall") == true)
    }

    @Test(arguments: [
        (TrustProblem.expired(Date(timeIntervalSince1970: 1_700_000_000)), "expired on"),
        (TrustProblem.hostnameMismatch, "isn't valid for “git.example.com”"),
        (TrustProblem.unknownIssuer, "which this Mac doesn't trust"),
        (TrustProblem.notYetValid(nil), "isn't valid yet"),
    ])
    func tlsFailuresHaveSpecificMessages(problem: TrustProblem, expected: String) async throws {
        var answers = StubDiagnosticsProbe.Answers()
        answers.tls = .untrusted(
            leaf: CertificateSummary(subject: "other.example.com", issuer: "Corp CA", names: ["other.example.com"]),
            problem: problem)
        let transport = Self.gitlab()
        let instance = try instance()
        let steps = await runner(
            instance, account: Self.account(instance), transport: transport, probe: StubDiagnosticsProbe(answers)
        ).runToCompletion()
        let tls = step(steps, .tls)
        #expect(tls.status == .failed)
        #expect(tls.result.contains(expected), "\(tls.result)")
        #expect(step(steps, .http).status == .skipped)
        #expect(step(steps, .authentication).status == .skipped)
        #expect(transport.requests.isEmpty)
        if problem == .unknownIssuer {
            #expect(
                tls.explanation?.contains("import your company's CA certificate in Settings ▸ Servers & Network")
                    == true)
        }
        if problem == .hostnameMismatch { #expect(tls.explanation?.contains("other.example.com") == true) }
    }

    @Test func trustedCertificateExpiringSoonIsAWarning() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let leaf = CertificateSummary(subject: "git", issuer: "CA", notAfter: now.addingTimeInterval(5 * 24 * 3600))
        let step = DiagnosticsRunner.tlsStep(
            .trusted(leaf: leaf, anchor: .custom("Corp Root")), host: "git", port: 443, hasCustomCA: true, now: now)
        #expect(step.status == .warning)
        #expect(step.details.contains("Trusted through: imported CA “Corp Root”"))
    }

    @Test func notFoundOrHTMLMeansWrongPathPrefix() async throws {
        for response in [
            ProviderStubResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not Found".utf8)),
            ProviderStubResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)),
        ] {
            let transport = Self.gitlab { _ in response }
            let instance = try instance(url: "https://git.example.com")
            let steps = await runner(instance, account: Self.account(instance), transport: transport)
                .runToCompletion()
            let http = step(steps, .http)
            #expect(http.status == .failed)
            #expect(http.explanation?.contains("path prefix") == true)
            #expect(step(steps, .authentication).status == .skipped)
            #expect(transport.requests.map { $0.url?.path } == ["/api/v4/version"])
        }
    }

    @Test func unauthenticatedVersionStillCountsAsReachable() async throws {
        let transport = Self.gitlab { _ in .json(#"{"message":"401 Unauthorized"}"#, status: 401) }
        let steps = await runner(try instance(), transport: transport).runToCompletion()
        #expect(step(steps, .http).status == .passed)
        #expect(step(steps, .http).result.contains("HTTP 401"))
        #expect(step(steps, .authentication).status == .skipped)
        #expect(step(steps, .authentication).result.contains("no account"))
    }

    @Test func oldGitLabIsAWarning() async throws {
        let transport = Self.gitlab { request in
            request.url?.path.hasSuffix("/version") == true ? .json(#"{"version":"14.10.2"}"#) : nil
        }
        let steps = await runner(try instance(), transport: transport).runToCompletion()
        #expect(step(steps, .http).status == .warning)
    }

    @Test func gitHubUsesTheMetaEndpoint() async throws {
        let transport = ProviderStubTransport { _ in .json(#"{"ssh_keys":[]}"#) }
        let steps = await runner(.github, transport: transport).runToCompletion()
        #expect(step(steps, .http).status == .passed)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.github.com/meta")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func rejectedTokenFailsAuthentication() async throws {
        let transport = Self.gitlab { request in
            request.url?.path.hasSuffix("/user") == true ? .json(#"{"message":"401 Unauthorized"}"#, status: 401) : nil
        }
        let instance = try instance()
        let steps = await runner(instance, account: Self.account(instance), transport: transport).runToCompletion()
        let auth = step(steps, .authentication)
        #expect(auth.status == .failed)
        #expect(auth.result == "The server rejected the token for @ada.")
        #expect(auth.explanation?.contains("expired or been revoked") == true)
    }

    @Test func transportFailureInHTTPStepIsClassified() async throws {
        let transport = ProviderStubTransport { _ in throw URLError(.timedOut) }
        let steps = await runner(try instance(), transport: transport).runToCompletion()
        #expect(step(steps, .http).status == .failed)
        #expect(step(steps, .http).result == "The server didn't respond in time.")
    }

    @Test func sshUnknownChangedAndUnreachable() async throws {
        var answers = StubDiagnosticsProbe.Answers()
        answers.keys = [Self.hostKey]
        let unknown = await runner(try instance(), probe: StubDiagnosticsProbe(answers)).runToCompletion()
        #expect(step(unknown, .ssh).status == .warning)
        #expect(step(unknown, .ssh).result.contains("isn't trusted yet"))
        #expect(step(unknown, .ssh).explanation?.contains("Jit will ask you to verify") == true)
        #expect(step(unknown, .ssh).details == ["ED25519 host key: \(Self.hostKey.fingerprint)"])

        // A different ED25519 key for the host in the user's known_hosts → changed (security error).
        let other = "AAAAC3NzaC1lZDI1NTE5AAAAIA6xqCFVJh9hnoPp4Kz/NjhBM4rX3kPDdW5fdv4y6t3c"
        try "git.example.com ssh-ed25519 \(other)\n".write(
            toFile: directory + "/user_known_hosts", atomically: true, encoding: .utf8)
        let changed = await runner(try instance(), probe: StubDiagnosticsProbe(answers)).runToCompletion()
        #expect(step(changed, .ssh).status == .failed)
        #expect(step(changed, .ssh).result.contains("CHANGED"))

        var closed = StubDiagnosticsProbe.Answers()
        closed.tcp = { _, port, _ in port == 22 ? .refused : .connected }
        let refused = await runner(try instance(), probe: StubDiagnosticsProbe(closed)).runToCompletion()
        #expect(step(refused, .ssh).status == .failed)
        #expect(step(refused, .ssh).result.contains("connection refused"))
    }

    @Test func plainHTTPServerWarnsInsteadOfTLS() async throws {
        let steps = await runner(try instance(url: "http://git.example.com:8080")).runToCompletion()
        #expect(step(steps, .tls).status == .warning)
        #expect(step(steps, .http).status == .passed)
    }

    @Test func streamEmitsRunningThenFinalForEveryStep() async throws {
        let instance = try instance()
        var updates: [DiagnosticStep] = []
        for await update in runner(instance, account: Self.account(instance)).run() { updates.append(update) }
        for id in DiagnosticStepID.allCases {
            let mine = updates.filter { $0.id == id }
            #expect(mine.first?.status == .running, "\(id)")
            #expect(mine.last.map { $0.status != .running } == true, "\(id)")
        }
    }

    @Test func cancellationStopsTheRun() async throws {
        let gate = AsyncStream<Void>.makeStream()
        final class BlockingTransport: HTTPTransport {
            let stream: AsyncStream<Void>
            init(_ stream: AsyncStream<Void>) { self.stream = stream }
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                for await _ in stream {}
                throw URLError(.cancelled)
            }
        }
        let instance = try instance()
        let task = Task {
            await runner(instance, account: Self.account(instance), transport: BlockingTransport(gate.stream))
                .runToCompletion()
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        gate.continuation.finish()
        let steps = await task.value
        #expect(step(steps, .authentication).status == .skipped)
        #expect(step(steps, .ssh).status == .skipped)
        #expect(step(steps, .ssh).result == "Cancelled.")
    }

    @Test func reportIsSanitized() async throws {
        let instance = try instance(url: "https://ada:hunter2-password@git.example.com/gitlab")
        let account = Self.account(instance)
        var steps = await runner(instance, account: account).runToCompletion()
        steps[5].details.append("Authorization: Bearer \(Self.sentinel)")
        steps[5].details.append("Seen \(Self.sentinel) and ghp_abcdefghijklmnopqrstuvwxyz0123")
        steps[5].details.append("Redirect to https://oauth2:\(Self.sentinel)@git.example.com/x")
        let report = DiagnosticsReport.text(instance: instance, account: account, steps: steps)
        #expect(!report.contains("hunter2"))
        #expect(!report.contains("SENTINEL"))
        #expect(!report.contains("ghp_abc"))
        #expect(report.contains("Authorization: [redacted]"))
        #expect(report.contains("https://•••@git.example.com/gitlab"))
        #expect(report.contains("Account: @ada"))
        #expect(report.contains("8. SSH — "))
    }

    @Test func reportOmitsProxyUserNames() throws {
        let proxy = ManualProxy(kind: .http, host: "proxy.corp", port: 3128, username: "jdoe-secret-user")
        let report = DiagnosticsReport.text(
            instance: try instance(proxy: .manual(proxy)), account: nil, steps: DiagnosticStep.allPending)
        #expect(report.contains("Proxy setting: HTTP proxy.corp:3128"))
        #expect(!report.contains("jdoe"))
    }
}

// MARK: Rig integration (ADR-0039)

@Suite(.serialized, .enabled(if: Rig.enabled, "set JIT_RIG=1 and run the enterprise rig"))
struct DiagnosticsRigTests {
    let directory: String
    let caStore: CAStore

    init() throws {
        directory = NSTemporaryDirectory() + "jit-diagnostics-rig-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        caStore = CAStore(directory: directory + "/ca")
    }

    func anchors(_ caPath: String?) throws -> [SecCertificate] {
        guard let caPath else { return [] }
        let info = try caStore.importCA(try Data(contentsOf: URL(fileURLWithPath: caPath)))
        return caStore.certificates([info.id])
    }

    func run(
        host: String = "127.0.0.1", port: Int = Rig.port("JIT_RIG_HTTPS_PORT"), prefix: String = "",
        ca: String? = Rig.value("JIT_RIG_CA"), token: String? = "rig-token-ada", proxy: ProxyMode = .direct,
        sshPort: Int = Rig.port("JIT_RIG_SSH_PORT")
    ) async throws -> [DiagnosticStep] {
        let anchors = try anchors(ca)
        let url = try #require(URL(string: "https://\(host):\(port)\(prefix)"))
        let instance = ProviderInstance(
            id: .new(), kind: .gitlab, name: "Rig", webBaseURL: url, sshHost: host, sshPort: sshPort, proxy: proxy)
        let resolved: ResolvedProxy
        if case .manual(let manual) = proxy {
            resolved = ResolvedProxy(proxy: manual, source: .manual)
        } else {
            resolved = .direct
        }
        let scopes = anchors.isEmpty ? [] : [ScopedTrustDelegate.Scope(host: host, port: port, anchors: anchors)]
        let transport = URLSessionTransport(
            configuration: NetworkSessionFactory.configuration(proxy: resolved),
            delegate: ScopedTrustDelegate(scopes: scopes))
        let account = token.map { _ in HostingAccount(instanceID: instance.id, login: "ada", userID: "1", method: .pat)
        }
        let runner = DiagnosticsRunner(
            configuration: .init(
                instance: instance, account: account, path: PathSnapshot(status: .satisfied), anchors: anchors,
                jitKnownHosts: directory + "/known_hosts", userKnownHosts: directory + "/user_known_hosts",
                timeout: .seconds(5)),
            transport: transport, token: token.map { value -> TokenProvider in { SecretBytes(utf8: value) } },
            proxyResolver: SystemProxyResolver(settings: { [:] }))
        return await runner.runToCompletion()
    }

    func step(_ steps: [DiagnosticStep], _ id: DiagnosticStepID) -> DiagnosticStep { steps[id.rawValue - 1] }

    @Test func passesWithTheRigCA() async throws {
        let steps = try await run()
        for id in [DiagnosticStepID.networkPath, .dns, .proxy, .tcp, .tls, .http, .authentication] {
            #expect(step(steps, id).status == .passed, "\(id): \(step(steps, id).result)")
        }
        #expect(step(steps, .dns).result.contains("127.0.0.1"))
        #expect(step(steps, .tls).details.contains("Trusted through: imported CA “Jit Rig Test Root CA”"))
        #expect(step(steps, .tls).details.contains { $0.contains("127.0.0.1") })
        #expect(step(steps, .http).result.contains("GitLab 17.5.0"))
        #expect(step(steps, .authentication).result == "Signed in as @ada.")
        // Fresh known_hosts files: the rig's host key is unknown.
        #expect(step(steps, .ssh).status == .warning, "\(step(steps, .ssh).result)")
        #expect(step(steps, .ssh).result.contains("isn't trusted yet"))
    }

    @Test func otherCAFailsTLSAsUnknownIssuer() async throws {
        let steps = try await run(ca: Rig.value("JIT_RIG_OTHER_CA"))
        #expect(step(steps, .tcp).status == .passed)
        let tls = step(steps, .tls)
        #expect(tls.status == .failed)
        #expect(tls.result.contains("“Jit Rig Test Root CA”, which this Mac doesn't trust"), "\(tls.result)")
        #expect(tls.explanation?.contains("Servers & Network") == true)
        #expect(step(steps, .http).status == .skipped)
        #expect(step(steps, .authentication).status == .skipped)
    }

    @Test func noCAFailsTLS() async throws {
        let steps = try await run(ca: nil)
        #expect(step(steps, .tls).status == .failed)
        #expect(step(steps, .tls).explanation?.contains("import your company's CA certificate") == true)
    }

    /// The live handshake to the rig is trusted; the same chain evaluated for a name the certificate doesn't cover
    /// (offline, from the rig's server.pem) is classified as a host-name mismatch rather than an unknown issuer.
    @Test func wrongHostNameIsAHostnameMismatch() async throws {
        let anchors = try anchors(Rig.value("JIT_RIG_CA"))
        let outcome = await SystemDiagnosticsProbe().handshake(
            host: "127.0.0.1", port: Rig.port("JIT_RIG_HTTPS_PORT"), anchors: anchors, via: nil, timeout: .seconds(5))
        guard case .trusted(let leaf, .custom) = outcome else {
            Issue.record("expected trusted by the imported CA, got \(outcome)")
            return
        }
        #expect(leaf.names.contains("127.0.0.1"))
        let pem = try Data(contentsOf: URL(fileURLWithPath: Rig.value("JIT_RIG_SERVER_CERT")))
        let chain = CAStore.certificates(from: pem)
        var trust: SecTrust?
        #expect(
            SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
        let analysis = TrustAnalyzer.analyze(
            try #require(trust), host: "git.example.com", anchors: anchors, now: Date())
        #expect(analysis.trusted == false)
        guard case .untrusted(_, .hostnameMismatch) = analysis.outcome else {
            Issue.record("expected hostname mismatch, got \(analysis.outcome)")
            return
        }
    }

    @Test func closedPortIsRefused() async throws {
        let port = try Self.closedPort()
        let steps = try await run(port: port, sshPort: port)
        let tcp = step(steps, .tcp)
        #expect(tcp.status == .failed)
        #expect(tcp.result.contains("Connection refused"), "\(tcp.result)")
        #expect(step(steps, .tls).status == .skipped)
        #expect(step(steps, .ssh).status == .failed)
        #expect(step(steps, .ssh).result.contains("connection refused"))
    }

    @Test func badNameIsNotFound() async throws {
        let steps = try await run(host: "no-such-host.invalid")
        let dns = step(steps, .dns)
        #expect(dns.status == .failed)
        #expect(dns.result == "Name not found.")
        #expect(step(steps, .tcp).status == .skipped)
        #expect(step(steps, .ssh).status == .skipped)
    }

    @Test func missingPathPrefixIsDetected() async throws {
        let wrong = try await run(port: Rig.port("JIT_RIG_HTTPS_PREFIX_PORT"))
        #expect(step(wrong, .tls).status == .passed)
        #expect(step(wrong, .http).status == .failed)
        #expect(step(wrong, .http).result.contains("HTTP 404"))
        #expect(step(wrong, .http).explanation?.contains("path prefix") == true)
        #expect(step(wrong, .authentication).status == .skipped)

        let right = try await run(
            port: Rig.port("JIT_RIG_HTTPS_PREFIX_PORT"), prefix: Rig.value("JIT_RIG_HTTPS_PREFIX"))
        #expect(step(right, .http).status == .passed)
        #expect(step(right, .authentication).status == .passed)
    }

    @Test func badTokenIsRejected() async throws {
        let steps = try await run(token: "not-a-rig-token")
        #expect(step(steps, .http).status == .passed)
        #expect(step(steps, .authentication).status == .failed)
        #expect(step(steps, .authentication).result == "The server rejected the token for @ada.")
    }

    @Test func sshHostKeyKnownAndChanged() async throws {
        let line = try String(contentsOfFile: Rig.value("JIT_RIG_SSH_HOST_KEY_PUB"), encoding: .utf8)
        let parts = line.split(separator: " ")
        try #require(parts.count >= 2)
        let key = SSHHostKey(
            host: "127.0.0.1", port: Rig.port("JIT_RIG_SSH_PORT"), type: String(parts[0]), key: String(parts[1]),
            fingerprint: SSHTools.fingerprint(type: String(parts[0]), base64: String(parts[1])) ?? "")
        try KnownHostsStore(path: directory + "/known_hosts").trust(key)
        let known = try await run()
        #expect(step(known, .ssh).status == .passed, "\(step(known, .ssh).result)")
        #expect(step(known, .ssh).details == ["ED25519 host key: \(key.fingerprint)"])

        try FileManager.default.removeItem(atPath: directory + "/known_hosts")
        let other = "AAAAC3NzaC1lZDI1NTE5AAAAIA6xqCFVJh9hnoPp4Kz/NjhBM4rX3kPDdW5fdv4y6t3c"
        try "[127.0.0.1]:\(Rig.port("JIT_RIG_SSH_PORT")) ssh-ed25519 \(other)\n".write(
            toFile: directory + "/user_known_hosts", atomically: true, encoding: .utf8)
        let changed = try await run()
        #expect(step(changed, .ssh).status == .failed)
        #expect(step(changed, .ssh).result.contains("CHANGED"))
    }

    /// The proxy step's reachability check is a real TCP connect to the rig proxy. Network.framework and URLSession
    /// never proxy loopback targets, so the tunnel itself can't be exercised against the 127.0.0.1-only rig; the
    /// runner therefore doesn't claim to route through the proxy for loopback hosts.
    @Test func rigProxyIsReachableAndLoopbackIsNotTunnelled() async throws {
        let proxy = ManualProxy(kind: .http, host: "127.0.0.1", port: Rig.port("JIT_RIG_PROXY_PORT"))
        let steps = try await run(proxy: .manual(proxy))
        #expect(step(steps, .proxy).status == .passed)
        #expect(
            step(steps, .proxy).result.contains("Manual proxy HTTP 127.0.0.1:\(proxy.port). The proxy is reachable."))
        #expect(!step(steps, .tcp).result.contains("through the proxy"))
        for id in [DiagnosticStepID.tcp, .tls, .http, .authentication] {
            #expect(step(steps, id).status == .passed, "\(id): \(step(steps, id).result)")
        }

        let closed = ManualProxy(kind: .http, host: "127.0.0.1", port: try Self.closedPort())
        let refused = try await run(proxy: .manual(closed))
        #expect(step(refused, .proxy).status == .failed)
        #expect(step(refused, .proxy).result.contains("connection refused"))
        #expect(step(refused, .tcp).status == .skipped)
    }

    @Test func reportFromARealRunHasNoToken() async throws {
        let steps = try await run()
        let instance = ProviderInstance(
            id: .new(), kind: .gitlab, name: "Rig",
            webBaseURL: try #require(URL(string: "https://ada:rig-token-ada@127.0.0.1:1")), sshHost: "127.0.0.1")
        let report = DiagnosticsReport.text(instance: instance, account: nil, steps: steps)
        #expect(!report.contains("rig-token-ada"))
    }

    /// A loopback port nothing listens on (bound, then closed).
    static func closedPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        try #require(bound)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
