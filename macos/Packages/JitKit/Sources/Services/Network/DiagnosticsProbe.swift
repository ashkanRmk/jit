import Darwin
import Foundation
import Network
import Security
import Synchronization

/// Production probes for the diagnostics (design §3.7, ADR-0038): `getaddrinfo` on a GCD worker (it blocks),
/// Network.framework connections with a one-shot timeout, and `ssh-keyscan`. Proxies are honoured through
/// Network.framework's proxy configuration (HTTP CONNECT or SOCKS5), so the TCP and TLS steps take the same
/// route as API requests.
public struct SystemDiagnosticsProbe: DiagnosticsProbing {
    public init() {}

    public func resolve(host: String) async -> DNSOutcome {
        let once = ResumeOnce<DNSOutcome>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard once.install(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async { once.finish(Self.lookup(host)) }
            }
        } onCancel: {
            once.finish(.failed("Cancelled."))
        }
    }

    static func lookup(_ host: String) -> DNSOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        guard status == 0 else {
            if status == EAI_NONAME || status == EAI_NODATA { return .notFound }
            if status == EAI_AGAIN { return .failed("the DNS server didn't answer.") }
            return .failed(String(cString: gai_strerror(status)))
        }
        var addresses: [String] = []
        var cursor = list
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = entry.pointee.ai_addr,
                getnameinfo(
                    address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            {
                let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !addresses.contains(text) { addresses.append(text) }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses.isEmpty ? .notFound : .resolved(addresses)
    }

    public func connect(host: String, port: Int, via proxy: DiagnosticsProxy?, timeout: Duration) async -> TCPOutcome {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            return .unreachable("the port \(port) isn't valid.")
        }
        let parameters = Self.parameters(tls: nil, proxy: proxy, timeout: timeout)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        switch await Self.establish(connection, timeout: timeout) {
        case .ready: return .connected
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .failed(let error): return Self.tcpOutcome(error)
        }
    }

    public func handshake(
        host: String, port: Int, anchors: [SecCertificate], via proxy: DiagnosticsProxy?, timeout: Duration
    ) async -> TLSOutcome {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            return .connection(.unreachable("the port \(port) isn't valid."))
        }
        let captured = Mutex<TrustAnalyzer.Analysis?>(nil)
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if !Self.isIPAddress(host) { sec_protocol_options_set_tls_server_name(security, host) }
        let verifyQueue = DispatchQueue(label: "jit.diagnostics.tls-verify")
        // The verify block evaluates with the instance's CAs plus system roots and completes with the honest
        // result: an untrusted chain aborts the handshake. Nothing is ever accepted that wouldn't be for real use.
        sec_protocol_options_set_verify_block(
            security,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let analysis = TrustAnalyzer.analyze(trust, host: host, anchors: anchors, now: Date())
                captured.withLock { $0 = analysis }
                complete(analysis.trusted)
            }, verifyQueue)
        let parameters = Self.parameters(tls: tls, proxy: proxy, timeout: timeout)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        let result = await Self.establish(connection, timeout: timeout)
        let analysis = captured.withLock { $0 }
        switch result {
        case .ready:
            if let analysis { return analysis.outcome }
            return .handshakeFailed("the server's certificate wasn't checked.")
        case .timedOut:
            if let analysis, !analysis.trusted { return analysis.outcome }
            return .connection(.timedOut)
        case .cancelled:
            return .connection(.cancelled)
        case .failed(let error):
            if let analysis, !analysis.trusted { return analysis.outcome }
            if case .tls(let status) = error {
                return .handshakeFailed("TLS error \(status) (\(Self.securityMessage(status))).")
            }
            return .connection(Self.tcpOutcome(error))
        }
    }

    public func scanHostKeys(host: String, port: Int) async -> [SSHHostKey] {
        await SSHTools.scanHostKeys(host: host, port: port)
    }

    // MARK: Network.framework plumbing

    enum ConnectionResult: Sendable {
        case ready
        case failed(NWError)
        case timedOut
        case cancelled
    }

    /// Starts `connection` and waits for ready / waiting / failed, a one-shot timeout, or task cancellation.
    /// The connection is always cancelled afterwards (diagnostics never send data).
    static func establish(_ connection: NWConnection, timeout: Duration) async -> ConnectionResult {
        let once = ResumeOnce<ConnectionResult>()
        let queue = DispatchQueue(label: "jit.diagnostics.connection")
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard once.install(continuation) else { return }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.finish(.ready)
                    case .waiting(let error), .failed(let error): once.finish(.failed(error))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + seconds(timeout)) { once.finish(.timedOut) }
            }
        } onCancel: {
            once.finish(.cancelled)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return result
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func parameters(tls: NWProtocolTLS.Options?, proxy: DiagnosticsProxy?, timeout: Duration) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(seconds(timeout)))
        let parameters = NWParameters(tls: tls, tcp: tcp)
        guard let proxy, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.proxy.port)) else {
            parameters.preferNoProxies = true
            return parameters
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.proxy.host), port: port)
        // An "HTTPS" proxy is spoken to with HTTP CONNECT, like URLSession and Git do.
        var configuration =
            proxy.proxy.kind == .socks5
            ? ProxyConfiguration(socksv5Proxy: endpoint) : ProxyConfiguration(httpCONNECTProxy: endpoint)
        configuration.allowFailover = false
        if let username = proxy.proxy.username, let password = proxy.password {
            // The API requires a String; it lives only for this probe.
            configuration.applyCredential(
                username: username, password: String(decoding: password.dataCopy(), as: UTF8.self))
        }
        let context = NWParameters.PrivacyContext(description: "Jit connectivity diagnostics")
        context.proxyConfigurations = [configuration]
        parameters.setPrivacyContext(context)
        return parameters
    }

    static func tcpOutcome(_ error: NWError) -> TCPOutcome {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .ETIMEDOUT: return .timedOut
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN:
                return .unreachable("there's no network route to the server.")
            case .ECANCELED: return .cancelled
            default: return .unreachable(String(cString: strerror(code.rawValue)).lowercased() + ".")
            }
        case .dns:
            return .nameNotFound
        case .tls(let status):
            return .unreachable("TLS error \(status).")
        default:
            return .unreachable(error.localizedDescription)
        }
    }

    static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

/// Server-trust evaluation for the diagnostics: the same evaluation as `ScopedTrustDelegate` (instance CAs plus
/// system roots, SSL policy with the host name), then — only to explain a failure — re-evaluations that isolate
/// the cause (validity dates, host name, issuer). Never changes what is trusted.
public enum TrustAnalyzer {
    public struct Analysis: Sendable {
        public var trusted: Bool
        public var outcome: TLSOutcome
    }

    public static func analyze(_ trust: SecTrust, host: String, anchors: [SecCertificate], now: Date) -> Analysis {
        let (trusted, message) = ScopedTrustDelegate.evaluate(trust, host: host, anchors: anchors)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let leaf = chain.first.map(summary)
        if trusted, let leaf {
            let root = chain.last
            let rootName = root.map { CAStore.info($0).subject } ?? "unknown"
            let custom = root.map { root in anchors.contains { der($0) == der(root) } } ?? false
            return Analysis(
                trusted: true, outcome: .trusted(leaf: leaf, anchor: custom ? .custom(rootName) : .system(rootName)))
        }
        guard let leaf else {
            return Analysis(
                trusted: false, outcome: .untrusted(leaf: nil, problem: .other(message ?? "no certificate.")))
        }
        // Validity first: an expired leaf or intermediate is the most specific explanation.
        for certificate in chain {
            let info = CAStore.info(certificate)
            if let notAfter = info.notAfter, notAfter < now {
                return Analysis(trusted: false, outcome: .untrusted(leaf: leaf, problem: .expired(notAfter)))
            }
            if let notBefore = info.notBefore, notBefore > now {
                return Analysis(trusted: false, outcome: .untrusted(leaf: leaf, problem: .notYetValid(notBefore)))
            }
        }
        // Same chain without the host-name requirement: if that passes, the name is the problem.
        var probe: SecTrust?
        if SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, nil), &probe) == errSecSuccess,
            let probe
        {
            SecTrustSetAnchorCertificates(probe, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(probe, false)
            if SecTrustEvaluateWithError(probe, nil) {
                return Analysis(trusted: false, outcome: .untrusted(leaf: leaf, problem: .hostnameMismatch))
            }
        }
        return Analysis(trusted: false, outcome: .untrusted(leaf: leaf, problem: .unknownIssuer))
    }

    static func der(_ certificate: SecCertificate) -> Data { SecCertificateCopyData(certificate) as Data }

    public static func summary(_ certificate: SecCertificate) -> CertificateSummary {
        let info = CAStore.info(certificate)
        return CertificateSummary(
            subject: info.subject, issuer: info.issuer, notBefore: info.notBefore, notAfter: info.notAfter,
            names: subjectAlternativeNames(certificate))
    }

    /// DNS names and IP addresses from the subjectAltName extension.
    static func subjectAlternativeNames(_ certificate: SecCertificate) -> [String] {
        let keys = [kSecOIDSubjectAltName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]],
            let entries = values[kSecOIDSubjectAltName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            if let text = entry[kSecPropertyKeyValue as String] as? String { return text }
            return nil
        }
    }
}

/// Resumes a continuation exactly once, from whichever comes first: the result, a timeout or cancellation
/// (which may arrive before the continuation is installed).
final class ResumeOnce<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, Never>)
        case finished(Value)
        case consumed
    }

    private let state = Mutex<State>(.idle)

    /// Returns false when a result already arrived (the continuation was resumed with it right away).
    func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        let early: Value? = state.withLock { state in
            switch state {
            case .idle:
                state = .waiting(continuation)
                return nil
            case .finished(let value):
                state = .consumed
                return value
            case .waiting, .consumed:
                return nil
            }
        }
        guard let early else { return true }
        continuation.resume(returning: early)
        return false
    }

    func finish(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = state.withLock { state in
            switch state {
            case .idle:
                state = .finished(value)
                return nil
            case .waiting(let continuation):
                state = .consumed
                return continuation
            case .finished, .consumed:
                return nil
            }
        }
        waiting?.resume(returning: value)
    }
}
