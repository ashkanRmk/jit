import Foundation
import GitCore
import Security

// Connectivity diagnostics (design §3.7, ADR-0038): an explicit, user-started sequence of checks for one
// provider instance. Nothing here runs on its own — no polling, no timers, no background refresh.

/// The eight checks, in the order they run.
public enum DiagnosticStepID: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case networkPath = 1
    case dns
    case proxy
    case tcp
    case tls
    case http
    case authentication
    case ssh

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .networkPath: "Network"
        case .dns: "Name lookup (DNS)"
        case .proxy: "Proxy"
        case .tcp: "Connection to the HTTPS port"
        case .tls: "Secure connection (TLS)"
        case .http: "Server API"
        case .authentication: "Sign-in"
        case .ssh: "SSH"
        }
    }
}

public enum DiagnosticStatus: String, Sendable, Hashable {
    case pending
    case running
    case passed
    case warning
    case failed
    case skipped

    public var title: String {
        switch self {
        case .pending: "Not run"
        case .running: "Checking"
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }
}

/// One check's state: a plain-language result line, optional detail lines (addresses, certificate fields) and,
/// for warnings and failures, what to do next.
public struct DiagnosticStep: Sendable, Hashable, Identifiable {
    public let id: DiagnosticStepID
    public var status: DiagnosticStatus
    public var result: String
    public var details: [String]
    public var explanation: String?

    public init(
        id: DiagnosticStepID, status: DiagnosticStatus, result: String, details: [String] = [],
        explanation: String? = nil
    ) {
        self.id = id
        self.status = status
        self.result = result
        self.details = details
        self.explanation = explanation
    }

    public var title: String { id.title }

    public static func pending(_ id: DiagnosticStepID) -> DiagnosticStep {
        DiagnosticStep(id: id, status: .pending, result: "Not run yet.")
    }

    public static var allPending: [DiagnosticStep] { DiagnosticStepID.allCases.map(pending) }
}

// MARK: Probe seam

/// Outcome of a name lookup.
public enum DNSOutcome: Sendable, Hashable {
    case resolved([String])
    case notFound
    case failed(String)
}

/// Outcome of a TCP connection attempt (directly or through a proxy).
public enum TCPOutcome: Sendable, Hashable {
    case connected
    case refused
    case timedOut
    case nameNotFound
    case unreachable(String)
    case cancelled
}

/// The fields of a certificate the diagnostics show.
public struct CertificateSummary: Sendable, Hashable {
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    /// Subject alternative names (DNS names and IP addresses).
    public var names: [String]

    public init(subject: String, issuer: String, notBefore: Date? = nil, notAfter: Date? = nil, names: [String] = []) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.names = names
    }
}

/// Which trust anchor completed the chain.
public enum TrustAnchor: Sendable, Hashable {
    /// A root certificate trusted by macOS.
    case system(String)
    /// A CA certificate imported in Jit for this server (or the global network settings).
    case custom(String)
}

public enum TrustProblem: Sendable, Hashable {
    case expired(Date?)
    case notYetValid(Date?)
    case hostnameMismatch
    case unknownIssuer
    case other(String)
}

/// Outcome of a TLS handshake whose server trust was evaluated with the instance's CAs plus system roots.
/// An untrusted certificate is never accepted — the handshake is aborted and the reason reported.
public enum TLSOutcome: Sendable, Hashable {
    case trusted(leaf: CertificateSummary, anchor: TrustAnchor)
    case untrusted(leaf: CertificateSummary?, problem: TrustProblem)
    case handshakeFailed(String)
    case connection(TCPOutcome)
}

/// A proxy the probe should tunnel through, with its password when it needs one (Keychain, read on demand).
public struct DiagnosticsProxy: Sendable {
    public var proxy: ManualProxy
    public var password: SecretBytes?

    public init(proxy: ManualProxy, password: SecretBytes? = nil) {
        self.proxy = proxy
        self.password = password
    }
}

/// The network operations the runner needs — the seam unit tests replace to force each failure.
/// Production: `SystemDiagnosticsProbe` (getaddrinfo, Network.framework, ssh-keyscan).
public protocol DiagnosticsProbing: Sendable {
    func resolve(host: String) async -> DNSOutcome
    func connect(host: String, port: Int, via proxy: DiagnosticsProxy?, timeout: Duration) async -> TCPOutcome
    func handshake(
        host: String, port: Int, anchors: [SecCertificate], via proxy: DiagnosticsProxy?, timeout: Duration
    ) async -> TLSOutcome
    func scanHostKeys(host: String, port: Int) async -> [SSHHostKey]
}

// MARK: Runner

/// Runs the diagnostics for one provider instance (and optionally one account) and streams step updates.
/// Steps that depend on a failed step are `.skipped` with the reason. Cancelling the consuming task (or
/// dropping the stream) cancels in-flight probes.
public struct DiagnosticsRunner: Sendable {
    public struct Configuration: Sendable {
        public var instance: ProviderInstance
        public var account: HostingAccount?
        /// The path as `ConnectivityState` last saw it.
        public var path: PathSnapshot
        /// The global proxy mode instances inherit.
        public var globalProxy: ProxyMode
        /// The instance's (and global) imported CA certificates.
        public var anchors: [SecCertificate]
        public var jitKnownHosts: String
        public var userKnownHosts: String
        public var timeout: Duration

        public init(
            instance: ProviderInstance, account: HostingAccount? = nil, path: PathSnapshot,
            globalProxy: ProxyMode = .system, anchors: [SecCertificate] = [], jitKnownHosts: String,
            userKnownHosts: String, timeout: Duration = .seconds(10)
        ) {
            self.instance = instance
            self.account = account
            self.path = path
            self.globalProxy = globalProxy
            self.anchors = anchors
            self.jitKnownHosts = jitKnownHosts
            self.userKnownHosts = userKnownHosts
            self.timeout = timeout
        }
    }

    public let configuration: Configuration
    let transport: any HTTPTransport
    let token: TokenProvider?
    let proxyResolver: any ProxyResolving
    let probe: any DiagnosticsProbing
    let proxyPassword: (@Sendable (ManualProxy) async -> SecretBytes?)?

    /// - Parameters:
    ///   - transport: the instance's API transport (`AccountsService.transport(for:)`: proxy + scoped CA trust).
    ///   - token: the account's token provider; `nil` skips the sign-in step.
    ///   - proxyPassword: reads a manual proxy's password from the Keychain when the proxy has a username.
    public init(
        configuration: Configuration, transport: any HTTPTransport, token: TokenProvider? = nil,
        proxyResolver: any ProxyResolving = SystemProxyResolver(),
        probe: any DiagnosticsProbing = SystemDiagnosticsProbe(),
        proxyPassword: (@Sendable (ManualProxy) async -> SecretBytes?)? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.token = token
        self.proxyResolver = proxyResolver
        self.probe = probe
        self.proxyPassword = proxyPassword
    }

    /// Streams every step change (running, then the final status) in order. The run starts when the stream is
    /// created and is cancelled when the stream is dropped.
    public func run() -> AsyncStream<DiagnosticStep> {
        AsyncStream { continuation in
            let task = Task {
                _ = await perform { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs all steps and returns their final states.
    public func runToCompletion() async -> [DiagnosticStep] {
        await perform { _ in }
    }

    // MARK: Sequence

    private struct Board {
        var steps = DiagnosticStep.allPending
        let emit: @Sendable (DiagnosticStep) -> Void

        mutating func set(_ step: DiagnosticStep) {
            steps[step.id.rawValue - 1] = step
            emit(step)
        }

        mutating func start(_ id: DiagnosticStepID) {
            set(DiagnosticStep(id: id, status: .running, result: "Checking…"))
        }

        mutating func skip(_ id: DiagnosticStepID, _ reason: String) {
            set(DiagnosticStep(id: id, status: .skipped, result: reason))
        }

        mutating func skipRemaining(after id: DiagnosticStepID, _ reason: String) {
            for later in DiagnosticStepID.allCases
            where later.rawValue > id.rawValue
                && steps[later.rawValue - 1]
                    .status == .pending
            {
                skip(later, reason)
            }
        }
    }

    func perform(_ emit: @escaping @Sendable (DiagnosticStep) -> Void) async -> [DiagnosticStep] {
        var board = Board(emit: emit)
        let instance = configuration.instance
        let host = instance.httpsHost
        let port = instance.httpsPort

        // 1. Network path
        board.start(.networkPath)
        let pathStep = Self.networkStep(configuration.path)
        board.set(pathStep)
        if configuration.path.status.isOffline {
            board.skipRemaining(after: .networkPath, "Skipped — you're offline.")
            return board.steps
        }

        // The proxy decision is needed to judge DNS results (a proxy may resolve names Jit can't).
        let resolved: ResolvedProxy
        if let url = RemoteURL.parse(instance.webBaseURL.absoluteString) {
            resolved = await proxyResolver.resolve(url, mode: instance.proxy, global: configuration.globalProxy)
        } else {
            resolved = .direct
        }
        // macOS never proxies loopback targets (Network.framework and URLSession bypass them), so neither do we.
        var route: DiagnosticsProxy?
        if let proxy = resolved.proxy, !Self.isLoopback(host) {
            let password = proxy.username == nil ? nil : await proxyPassword?(proxy)
            route = DiagnosticsProxy(proxy: proxy, password: password)
        }

        // HTTPS steps stop at the first hard failure; `blocked` is the reason later steps are skipped.
        var blocked: String?
        var dnsFailed = false

        // 2. DNS
        if Task.isCancelled { return cancelled(&board, after: .networkPath) }
        board.start(.dns)
        let dnsStep = Self.dnsStep(await probe.resolve(host: host), host: host, proxy: resolved.proxy)
        board.set(dnsStep)
        if dnsStep.status == .failed {
            dnsFailed = true
            blocked = "Skipped — the server's name couldn't be found."
        }

        // 3. Proxy
        if Task.isCancelled { return cancelled(&board, after: .dns) }
        board.start(.proxy)
        var reachability: TCPOutcome?
        if let proxy = resolved.proxy {
            reachability = await probe.connect(host: proxy.host, port: proxy.port, via: nil, timeout: timeout)
        }
        let proxyStep = Self.proxyStep(resolved, mode: instance.proxy, reachability: reachability)
        board.set(proxyStep)
        if proxyStep.status == .failed, blocked == nil { blocked = "Skipped — the proxy isn't reachable." }

        // 4. TCP
        if Task.isCancelled { return cancelled(&board, after: .proxy) }
        if let blocked {
            board.skip(.tcp, blocked)
        } else {
            board.start(.tcp)
            let outcome = await probe.connect(host: host, port: port, via: route, timeout: timeout)
            let step = Self.tcpStep(outcome, host: host, port: port, proxy: route?.proxy, timeout: timeout)
            board.set(step)
            if step.status == .failed { blocked = "Skipped — Jit couldn't connect to the server." }
        }

        // 5. TLS
        if Task.isCancelled { return cancelled(&board, after: .tcp) }
        if instance.webBaseURL.scheme?.lowercased() == "http" {
            board.set(
                DiagnosticStep(
                    id: .tls, status: .warning, result: "The server address uses http:// — nothing is encrypted.",
                    explanation: "Tokens and code travel in the clear. Use the server's https:// address if it has one."
                ))
        } else if let blocked {
            board.skip(.tls, blocked)
        } else {
            board.start(.tls)
            let outcome = await probe.handshake(
                host: host, port: port, anchors: configuration.anchors, via: route, timeout: timeout)
            let step = Self.tlsStep(outcome, host: host, port: port, hasCustomCA: !configuration.anchors.isEmpty)
            board.set(step)
            if step.status == .failed { blocked = "Skipped — the secure connection failed." }
        }

        // 6. HTTP
        if Task.isCancelled { return cancelled(&board, after: .tls) }
        if let blocked {
            board.skip(.http, blocked)
        } else {
            board.start(.http)
            let step = await httpStep(instance)
            board.set(step)
            if step.status == .failed { blocked = "Skipped — the server's API didn't answer as expected." }
        }

        // 7. Authentication
        if Task.isCancelled { return cancelled(&board, after: .http) }
        if configuration.account == nil || token == nil {
            board.skip(.authentication, "Skipped — no account is selected for this server.")
        } else if let blocked {
            board.skip(.authentication, blocked)
        } else {
            board.start(.authentication)
            board.set(await authenticationStep(instance))
        }

        // 8. SSH
        if Task.isCancelled { return cancelled(&board, after: .authentication) }
        let sshHost = instance.sshHost
        if sshHost.isEmpty {
            board.skip(.ssh, "Skipped — no SSH host is configured.")
        } else if dnsFailed, sshHost.lowercased() == host, resolved.proxy == nil {
            board.skip(.ssh, "Skipped — the server's name couldn't be found.")
        } else {
            board.start(.ssh)
            board.set(await sshStep(host: sshHost, port: instance.sshPort))
        }
        return board.steps
    }

    private var timeout: Duration { configuration.timeout }

    static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower.hasSuffix(".localhost") || lower == "::1" || lower.hasPrefix("127.")
    }

    private func cancelled(_ board: inout Board, after id: DiagnosticStepID) -> [DiagnosticStep] {
        board.skipRemaining(after: id, "Cancelled.")
        return board.steps
    }

    // MARK: Step evaluation (pure, unit-tested)

    static func networkStep(_ path: PathSnapshot) -> DiagnosticStep {
        var notes: [String] = []
        if path.vpnInterface { notes.append("A VPN connection appears to be active.") }
        if path.isConstrained { notes.append("Low Data Mode is on.") }
        if path.isExpensive { notes.append("The connection is metered (for example a personal hotspot).") }
        switch path.status {
        case .satisfied:
            return DiagnosticStep(id: .networkPath, status: .passed, result: "Connected to a network.", details: notes)
        case .unsatisfied:
            return DiagnosticStep(
                id: .networkPath, status: .failed, result: "You're offline.",
                explanation: "Connect to Wi-Fi or Ethernet, then test again. Jit doesn't retry on its own.")
        case .requiresConnection:
            return DiagnosticStep(
                id: .networkPath, status: .warning, result: "The network needs to connect first.", details: notes,
                explanation: "macOS reports that a connection (for example a VPN on demand) must be established.")
        case .unknown:
            return DiagnosticStep(
                id: .networkPath, status: .warning, result: "Jit hasn't received the network status yet.",
                details: notes)
        }
    }

    static func dnsStep(_ outcome: DNSOutcome, host: String, proxy: ManualProxy?) -> DiagnosticStep {
        switch outcome {
        case .resolved(let addresses):
            let shown = addresses.prefix(6).joined(separator: ", ")
            let more = addresses.count > 6 ? " and \(addresses.count - 6) more" : ""
            return DiagnosticStep(id: .dns, status: .passed, result: "\(host) resolves to \(shown)\(more).")
        case .notFound, .failed:
            let reason: String
            if case .failed(let message) = outcome {
                reason = "The name lookup for \(host) failed: \(message)"
            } else {
                reason = "Name not found."
            }
            if let proxy {
                return DiagnosticStep(
                    id: .dns, status: .warning, result: reason,
                    explanation:
                        "Your Mac can't resolve \(host), but requests go through the proxy \(proxy.host):\(proxy.port), which looks the name up itself."
                )
            }
            let hint =
                NetworkHints.vpnHint(host: host)
                ?? "Check the server address for typos. If the server is on a private network, connect to it (for example with a VPN) and try again."
            return DiagnosticStep(id: .dns, status: .failed, result: reason, explanation: hint)
        }
    }

    static func proxyStep(_ resolved: ResolvedProxy, mode: ProxyMode, reachability: TCPOutcome?) -> DiagnosticStep {
        let description: String
        switch resolved.source {
        case .direct:
            description =
                mode == .direct ? "No proxy — this server is set to connect directly." : "No proxy — direct connection."
        case .exception:
            description = "No proxy — the server is on the system proxy exception list."
        case .system:
            description =
                resolved.proxy.map { "System proxy \(label($0))." } ?? "System settings — no proxy for this server."
        case .pac:
            description = resolved.proxy.map { "Proxy auto-configuration (PAC) chose \(label($0))." } ?? "PAC — direct."
        case .manual:
            description = resolved.proxy.map { "Manual proxy \(label($0))." } ?? "Manual proxy."
        }
        guard let proxy = resolved.proxy, let reachability else {
            return DiagnosticStep(id: .proxy, status: .passed, result: description)
        }
        switch reachability {
        case .connected:
            return DiagnosticStep(id: .proxy, status: .passed, result: "\(description) The proxy is reachable.")
        case .cancelled:
            return DiagnosticStep(id: .proxy, status: .skipped, result: "Cancelled.")
        default:
            return DiagnosticStep(
                id: .proxy, status: .failed,
                result: "\(description) Jit couldn't reach the proxy (\(tcpPhrase(reachability))).",
                explanation:
                    "Check the proxy host and port in Settings ▸ Servers & Network, or ask your IT department whether \(proxy.host) is the right proxy for this network."
            )
        }
    }

    static func label(_ proxy: ManualProxy) -> String { "\(proxy.kind.title) \(proxy.host):\(proxy.port)" }

    static func tcpPhrase(_ outcome: TCPOutcome) -> String {
        switch outcome {
        case .connected: "connected"
        case .refused: "connection refused"
        case .timedOut: "no answer"
        case .nameNotFound: "name not found"
        case .unreachable(let message): message
        case .cancelled: "cancelled"
        }
    }

    static func tcpStep(_ outcome: TCPOutcome, host: String, port: Int, proxy: ManualProxy?, timeout: Duration)
        -> DiagnosticStep
    {
        let through = proxy.map { " through the proxy \($0.host):\($0.port)" } ?? ""
        let seconds = Int(timeout.components.seconds)
        switch outcome {
        case .connected:
            return DiagnosticStep(id: .tcp, status: .passed, result: "Connected to \(host):\(port)\(through).")
        case .refused:
            return DiagnosticStep(
                id: .tcp, status: .failed, result: "Connection refused by \(host):\(port)\(through).",
                explanation:
                    "Nothing is accepting connections on port \(port). Check the port in the server address, and whether the server is running."
            )
        case .timedOut:
            let vpn = NetworkHints.vpnHint(host: host).map { " \($0)" } ?? ""
            return DiagnosticStep(
                id: .tcp, status: .failed,
                result: "No answer from \(host):\(port) within \(seconds) seconds\(through).",
                explanation: "A firewall may be blocking port \(port), or the server is down.\(vpn)")
        case .nameNotFound:
            return DiagnosticStep(
                id: .tcp, status: .failed, result: "Name not found while connecting\(through).",
                explanation: NetworkHints.vpnHint(host: host) ?? "Check the server address.")
        case .unreachable(let message):
            return DiagnosticStep(
                id: .tcp, status: .failed, result: "Jit couldn't connect to \(host):\(port)\(through): \(message)",
                explanation: "Check your network connection and the server address.")
        case .cancelled:
            return DiagnosticStep(id: .tcp, status: .skipped, result: "Cancelled.")
        }
    }

    static func tlsStep(_ outcome: TLSOutcome, host: String, port: Int, hasCustomCA: Bool, now: Date = Date())
        -> DiagnosticStep
    {
        switch outcome {
        case .trusted(let leaf, let anchor):
            var details = certificateDetails(leaf)
            switch anchor {
            case .system(let name): details.append("Trusted through: macOS root certificate “\(name)”")
            case .custom(let name): details.append("Trusted through: imported CA “\(name)”")
            }
            if let notAfter = leaf.notAfter, notAfter.timeIntervalSince(now) < 30 * 24 * 3600 {
                return DiagnosticStep(
                    id: .tls, status: .warning,
                    result: "The certificate is trusted but expires on \(dateText(notAfter)).", details: details,
                    explanation: "Let the server's administrator know so it's renewed in time.")
            }
            return DiagnosticStep(
                id: .tls, status: .passed, result: "The server's certificate for \(leaf.subject) is trusted.",
                details: details)
        case .untrusted(let leaf, let problem):
            let details = leaf.map(certificateDetails) ?? []
            switch problem {
            case .expired(let date):
                return DiagnosticStep(
                    id: .tls, status: .failed,
                    result: "The server's certificate expired\(date.map { " on \(dateText($0))" } ?? "").",
                    details: details,
                    explanation:
                        "Ask the server's administrator to renew it. Jit doesn't connect to servers with expired certificates. If the date looks wrong, check your Mac's date and time."
                )
            case .notYetValid(let date):
                return DiagnosticStep(
                    id: .tls, status: .failed,
                    result: "The server's certificate isn't valid yet\(date.map { " (from \(dateText($0)))" } ?? "").",
                    details: details, explanation: "Check your Mac's date and time settings.")
            case .hostnameMismatch:
                let names = leaf?.names ?? []
                let covers = names.isEmpty ? "" : " It covers \(names.joined(separator: ", "))."
                return DiagnosticStep(
                    id: .tls, status: .failed, result: "The certificate isn't valid for “\(host)”.", details: details,
                    explanation:
                        "The server presented a certificate for a different name.\(covers) Check the server address, or ask the administrator."
                )
            case .unknownIssuer:
                let issuer = leaf?.issuer ?? "an unknown authority"
                let explanation =
                    hasCustomCA
                    ? "The CA certificates imported for this server didn't sign this certificate. Import the CA that issued it (ask your IT department) in Settings ▸ Servers & Network."
                    : "If this is your company's server, import your company's CA certificate in Settings ▸ Servers & Network. Never import a certificate you didn't get from your IT department."
                return DiagnosticStep(
                    id: .tls, status: .failed,
                    result: "The certificate was issued by “\(issuer)”, which this Mac doesn't trust.",
                    details: details, explanation: explanation)
            case .other(let message):
                return DiagnosticStep(
                    id: .tls, status: .failed, result: "The certificate isn't trusted: \(message)", details: details,
                    explanation: "Ask the server's administrator to check its certificate.")
            }
        case .handshakeFailed(let message):
            return DiagnosticStep(
                id: .tls, status: .failed, result: "The secure connection failed: \(message)",
                explanation:
                    "The server may not speak HTTPS on port \(port), or a network device interfered with the connection."
            )
        case .connection(let tcp):
            var step = tcpStep(tcp, host: host, port: port, proxy: nil, timeout: .seconds(10))
            step = DiagnosticStep(
                id: .tls, status: step.status, result: step.result, details: step.details,
                explanation: step.explanation)
            return step
        }
    }

    static func certificateDetails(_ leaf: CertificateSummary) -> [String] {
        var details = ["Certificate: \(leaf.subject)", "Issued by: \(leaf.issuer)"]
        if let notAfter = leaf.notAfter { details.append("Expires: \(dateText(notAfter))") }
        if !leaf.names.isEmpty { details.append("Names: \(leaf.names.joined(separator: ", "))") }
        return details
    }

    static func dateText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    // MARK: HTTP and sign-in

    /// GitLab: `GET <api>/version` (401/403 still prove the API answered). GitHub: `GET <api>/meta`.
    func httpStep(_ instance: ProviderInstance) async -> DiagnosticStep {
        let endpoint = instance.kind == .gitlab ? "version" : "meta"
        let url = instance.apiBaseURL.appendingPathComponent(endpoint)
        let shown = RemoteURL.masked(url.absoluteString)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Jit", forHTTPHeaderField: "User-Agent")
        let prefixHint =
            "Check the server address, including any path prefix (for example https://git.example.com/gitlab)."
        do {
            let (data, response) = try await transport.data(for: request)
            let status = response.statusCode
            let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let details = ["GET \(shown) → HTTP \(status)"]
            if type.contains("text/html") || status == 404 {
                return DiagnosticStep(
                    id: .http, status: .failed,
                    result: "The server answered (HTTP \(status)), but not with the \(instance.kind.title) API.",
                    details: details, explanation: prefixHint)
            }
            switch status {
            case 200..<300:
                guard instance.kind == .gitlab else {
                    return DiagnosticStep(
                        id: .http, status: .passed, result: "The GitHub API answered (HTTP \(status)).",
                        details: details)
                }
                struct Version: Decodable { let version: String }
                guard let payload = try? JSONDecoder().decode(Version.self, from: data),
                    let version = SemanticVersion(parsing: payload.version)
                else {
                    return DiagnosticStep(
                        id: .http, status: .failed,
                        result: "The server answered (HTTP \(status)), but not with the GitLab API.",
                        details: details, explanation: prefixHint)
                }
                if version < GitLabProvider.minimumSupportedGitLab {
                    return DiagnosticStep(
                        id: .http, status: .warning,
                        result: "GitLab \(version.raw) answered — older than Jit supports.", details: details,
                        explanation: ProviderError.unsupportedVersion(version.raw).description)
                }
                return DiagnosticStep(
                    id: .http, status: .passed, result: "GitLab \(version.raw) answered (HTTP \(status)).",
                    details: details)
            case 401, 403:
                return DiagnosticStep(
                    id: .http, status: .passed,
                    result: "The \(instance.kind.title) API answered (HTTP \(status) — it asks for sign-in).",
                    details: details)
            case 429:
                return DiagnosticStep(
                    id: .http, status: .warning, result: "The API answered, but its rate limit was reached.",
                    details: details, explanation: "Wait a few minutes before testing again.")
            case 407:
                return DiagnosticStep(
                    id: .http, status: .failed, result: "The proxy asked for a user name and password (HTTP 407).",
                    details: details,
                    explanation: "Enter the proxy's user name and password in Settings ▸ Servers & Network.")
            default:
                return DiagnosticStep(
                    id: .http, status: .failed, result: "The server returned an unexpected error (HTTP \(status)).",
                    details: details, explanation: "The server may be under maintenance. Try again later.")
            }
        } catch let error as URLError {
            return transportFailure(ProviderError.transport(error), id: .http, host: instance.httpsHost)
        } catch let error as ProviderError {
            return transportFailure(error, id: .http, host: instance.httpsHost)
        } catch {
            return DiagnosticStep(
                id: .http, status: .failed, result: "The request failed.", explanation: "Try again.")
        }
    }

    func transportFailure(_ error: ProviderError, id: DiagnosticStepID, host: String) -> DiagnosticStep {
        let explanation: String
        switch error.transportFailure {
        case .dns?: explanation = NetworkHints.vpnHint(host: host) ?? "Check the server address."
        case .tls?: explanation = "Compare with the secure-connection step; import your company's CA if needed."
        case .proxy?: explanation = "Check the proxy settings in Settings ▸ Servers & Network."
        case .timeout?: explanation = "The server or a firewall didn't answer in time. Try again later."
        case .offline?: explanation = "Connect to a network and try again."
        default: explanation = "Try again. If it keeps failing, copy the report for your administrator."
        }
        return DiagnosticStep(id: id, status: .failed, result: error.description, explanation: explanation)
    }

    func authenticationStep(_ instance: ProviderInstance) async -> DiagnosticStep {
        guard let account = configuration.account, let token else {
            return DiagnosticStep(id: .authentication, status: .skipped, result: "No account selected.")
        }
        let provider: any HostingProvider =
            switch instance.kind {
            case .github: GitHubProvider(instance: instance, transport: transport, token: token)
            case .gitlab: GitLabProvider(instance: instance, method: account.method, transport: transport, token: token)
            }
        do {
            let user = try await provider.currentUser()
            if user.login.lowercased() != account.login.lowercased() {
                return DiagnosticStep(
                    id: .authentication, status: .warning,
                    result: "The token signs in as @\(user.login), not @\(account.login).",
                    explanation: "Reconnect the account with the right token in Settings ▸ Accounts.")
            }
            return DiagnosticStep(id: .authentication, status: .passed, result: "Signed in as @\(user.login).")
        } catch ProviderError.unauthorized {
            return DiagnosticStep(
                id: .authentication, status: .failed, result: "The server rejected the token for @\(account.login).",
                explanation: "It may have expired or been revoked. Reconnect the account in Settings ▸ Accounts.")
        } catch ProviderError.forbidden(let message) {
            return DiagnosticStep(
                id: .authentication, status: .failed,
                result: ProviderError.forbidden(message).description,
                explanation: "Check the token's scopes (it needs read_api / read_user, or repo for GitHub).")
        } catch OAuthError.refreshFailed {
            return DiagnosticStep(
                id: .authentication, status: .failed, result: "The sign-in for @\(account.login) has expired.",
                explanation: "Sign in again in Settings ▸ Accounts.")
        } catch let error as ProviderError {
            return transportFailure(error, id: .authentication, host: instance.httpsHost)
        } catch let error as URLError {
            return transportFailure(.transport(error), id: .authentication, host: instance.httpsHost)
        } catch {
            return DiagnosticStep(
                id: .authentication, status: .failed, result: "Jit couldn't read the account's token.",
                explanation: "Reconnect the account in Settings ▸ Accounts.")
        }
    }

    // MARK: SSH

    func sshStep(host: String, port: Int) async -> DiagnosticStep {
        let address = port == 22 ? host : "\(host):\(port)"
        let tcp = await probe.connect(host: host, port: port, via: nil, timeout: timeout)
        guard tcp == .connected else {
            if tcp == .cancelled { return DiagnosticStep(id: .ssh, status: .skipped, result: "Cancelled.") }
            let explanation: String =
                switch tcp {
                case .refused:
                    "Nothing accepts SSH connections on port \(port). Check the SSH port in the server settings, or use HTTPS."
                case .nameNotFound: NetworkHints.vpnHint(host: host) ?? "Check the SSH host name."
                default:
                    "A firewall may block SSH (port \(port)) on this network. Use HTTPS instead, or ask your IT department."
                }
            return DiagnosticStep(
                id: .ssh, status: .failed, result: "Jit couldn't connect to \(address) (\(Self.tcpPhrase(tcp))).",
                explanation: explanation)
        }
        let keys = await probe.scanHostKeys(host: host, port: port)
        guard
            let key = keys.first(where: { $0.displayType == "ED25519" })
                ?? keys.first(where: { $0.displayType == "ECDSA" }) ?? keys.first
        else {
            return DiagnosticStep(
                id: .ssh, status: .failed, result: "Connected to \(address), but Jit couldn't read its host key.",
                explanation: "The port may not be an SSH server. Check the SSH host and port.")
        }
        let details = ["\(key.displayType) host key: \(key.fingerprint)"]
        let stores = [
            ("Jit's known_hosts", KnownHostsStore(path: configuration.jitKnownHosts)),
            ("your ~/.ssh/known_hosts", KnownHostsStore(path: configuration.userKnownHosts)),
        ]
        var changed = false
        for (name, store) in stores {
            let entries = store.entries(host: host, port: port)
            if entries.contains(where: { entry in keys.contains { $0.type == entry.type && $0.key == entry.key } }) {
                return DiagnosticStep(
                    id: .ssh, status: .passed, result: "\(address) answers with a host key trusted in \(name).",
                    details: details)
            }
            if entries.contains(where: { entry in keys.contains { $0.type == entry.type && $0.key != entry.key } }) {
                changed = true
            }
        }
        if changed {
            return DiagnosticStep(
                id: .ssh, status: .failed, result: "The host key of \(address) has CHANGED.", details: details,
                explanation:
                    "This may mean someone is intercepting the connection, or the server was reinstalled. Jit won't connect over SSH. Ask the administrator for the new fingerprint before doing anything else."
            )
        }
        return DiagnosticStep(
            id: .ssh, status: .warning, result: "\(address) answers, but its host key isn't trusted yet.",
            details: details,
            explanation:
                "Jit will ask you to verify the fingerprint the first time you use SSH with this server. Compare it with the one your administrator publishes."
        )
    }
}

// MARK: Report

/// The "Copy Report" text: plain, sanitized (no tokens, no Authorization values, no user info in URLs).
public enum DiagnosticsReport {
    public static func text(
        instance: ProviderInstance, account: HostingAccount?, steps: [DiagnosticStep], date: Date = Date()
    ) -> String {
        var lines = [
            "Jit connectivity report",
            "Date: \(date.ISO8601Format())",
            "Server: \(instance.name) (\(instance.kind.title)\(instance.isSelfManaged ? ", self-managed" : ""))",
            "Address: \(RemoteURL.masked(instance.webBaseURL.absoluteString))",
            "API: \(RemoteURL.masked(instance.apiBaseURL.absoluteString))",
            "SSH: \(instance.sshHost):\(instance.sshPort)",
            "Proxy setting: \(proxyTitle(instance.proxy))",
            "Imported CA certificates: \(instance.caCertificateIDs.count)",
        ]
        if let account { lines.append("Account: @\(account.login) (\(account.method.title))") }
        lines.append("")
        for step in steps {
            lines.append("\(step.id.rawValue). \(step.title) — \(step.status.title)")
            lines.append("   \(step.result)")
            for detail in step.details { lines.append("   \(detail)") }
            if let explanation = step.explanation { lines.append("   Next step: \(explanation)") }
        }
        return sanitize(lines.joined(separator: "\n") + "\n")
    }

    /// Proxy credentials (user names) stay out of the report.
    static func proxyTitle(_ mode: ProxyMode) -> String {
        if case .manual(let proxy) = mode { return "\(proxy.kind.title) \(proxy.host):\(proxy.port)" }
        return mode.title
    }

    /// Strips user info from every URL, redacts header-style secrets and well-known token formats.
    public static func sanitize(_ text: String) -> String {
        var output = text.replacing(/[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s<>"]+/) { match in
            RemoteURL.masked(String(match.output))
        }
        output = output.replacing(
            /(?i)(proxy-authorization|authorization|private-token|job-token|x-api-key)(\s*[:=]\s*)[^\n]*/
        ) { match in
            "\(match.output.1)\(match.output.2)[redacted]"
        }
        output = output.replacing(/(glpat|gloas|glrt|gldt|glptt)-[A-Za-z0-9_\-]{8,}/, with: "[redacted]")
        output = output.replacing(/(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})/, with: "[redacted]")
        return output
    }
}

// MARK: AccountsService

extension AccountsService {
    /// A runner for `instance` using the same transport (proxy, scoped CA trust) as API requests, the account's
    /// token (if any), the current path, and Jit's and the user's known_hosts. Creating it performs no I/O.
    public func diagnosticsRunner(
        for instance: ProviderInstance, account: HostingAccount?,
        probe: any DiagnosticsProbing = SystemDiagnosticsProbe()
    ) async -> DiagnosticsRunner {
        connectivity.start()
        let transport = await transport(for: instance)
        let token = account.map { tokenProvider(for: $0, instance: instance) }
        let anchors = caStore.certificates(instance.caCertificateIDs + profiles.network.caCertificateIDs)
        let secrets = secrets
        let configuration = DiagnosticsRunner.Configuration(
            instance: instance, account: account, path: connectivity.path, globalProxy: profiles.network.proxy,
            anchors: anchors, jitKnownHosts: environment.jitKnownHosts, userKnownHosts: environment.userKnownHosts)
        return DiagnosticsRunner(
            configuration: configuration, transport: transport, token: token, proxyResolver: proxyResolver,
            probe: probe,
            proxyPassword: { proxy in try? await secrets.read(.proxy(proxy.id)) })
    }
}
