import Darwin
import Dispatch
import Foundation
import GitCore
import Synchronization
import os

let brokerLog = Logger(subsystem: "jit.app", category: "credentials")

public enum CredentialError: Error, Sendable, Equatable {
    case notAvailable(String)
    case cancelled
}

/// Where the broker gets secrets (production: Keychain + passphrase sheet; tests: fakes).
public protocol CredentialSource: Sendable {
    func httpsCredential(accountID: HostingAccountID, host: String) async throws(CredentialError) -> SecretPair
    func sshPassphrase(keyPath: String, fingerprint: String?, prompt: String) async throws(CredentialError)
        -> SecretBytes
    func proxyCredential(proxyID: ProxyConfigID, username: String) async throws(CredentialError) -> SecretPair
    /// Git called `erase`: the remote rejected the credential.
    func credentialRejected(accountID: HostingAccountID, host: String) async
    /// Git called `store`: the credential worked.
    func credentialAccepted(accountID: HostingAccountID, host: String) async
}

/// What one operation's broker may answer (resolved from the profile snapshot, design §4.2).
public struct BrokerPolicy: Sendable, Hashable {
    public struct HTTPSTarget: Sendable, Hashable {
        public var accountID: HostingAccountID
        public var host: String
        public var port: Int
        public var allowPlainHTTP: Bool

        public init(accountID: HostingAccountID, host: String, port: Int, allowPlainHTTP: Bool = false) {
            self.accountID = accountID
            self.host = host.lowercased()
            self.port = port
            self.allowPlainHTTP = allowPlainHTTP
        }
    }

    public struct ProxyTarget: Sendable, Hashable {
        public var proxyID: ProxyConfigID
        public var host: String
        public var port: Int
        public var username: String

        public init(proxyID: ProxyConfigID, host: String, port: Int, username: String) {
            self.proxyID = proxyID
            self.host = host.lowercased()
            self.port = port
            self.username = username
        }
    }

    public struct SSHKeyTarget: Sendable, Hashable {
        public var path: String
        public var fingerprint: String?

        public init(path: String, fingerprint: String?) {
            self.path = path
            self.fingerprint = fingerprint
        }
    }

    public var https: [HTTPSTarget]
    public var proxies: [ProxyTarget]
    public var sshKey: SSHKeyTarget?

    public init(https: [HTTPSTarget] = [], proxies: [ProxyTarget] = [], sshKey: SSHKeyTarget? = nil) {
        self.https = https
        self.proxies = proxies
        self.sshKey = sshKey
    }

    public var isEmpty: Bool { https.isEmpty && proxies.isEmpty && sshKey == nil }
}

/// The operation-scoped credential broker (ADR-0016, channel B): a Unix socket in a fresh `0700` directory
/// under `$TMPDIR`, a per-operation nonce, the peer verified to be the bundled helper (`LOCAL_PEERPID` →
/// executable path), answers only for the policy's hosts/key, and a hard cap on requests. Serviced by Dispatch
/// sources on one serial queue — no thread waits between requests — and removed when the operation ends.
public final class CredentialBroker: Sendable {
    public let endpoint: BrokerEndpoint
    /// Requests per operation: Git calls the helper for get + store/erase, per remote, and for proxy auth.
    public static let requestLimit = 16

    private let directory: String
    private let listener: Int32
    private let state: Mutex<State>
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead

    struct State {
        var requests = 0
        var closed = false
        var connections: [Int32: any DispatchSourceRead] = [:]
        var buffers: [Int32: [UInt8]] = [:]
        var tasks: [Task<Void, Never>] = []
    }

    /// Test hook: every request the broker refused, by reason (never contains secrets).
    public let refusals = Mutex<[String]>([])

    /// - Parameter expectedPeer: the helper's absolute path; connections from any other executable are dropped.
    ///   `nil` only in tests that connect from the test process itself.
    public init(policy: BrokerPolicy, source credentialSource: any CredentialSource, expectedPeer: String?)
        throws(CredentialError)
    {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("jit-XXXXXX")
        var template = Array(base.utf8CString)
        guard
            let created = template.withUnsafeMutableBufferPointer({ buffer in buffer.baseAddress.flatMap { mkdtemp($0) }
            })
        else {
            throw .notAvailable("Jit couldn't create a private folder for the credential broker.")
        }
        directory = String(cString: created)
        chmod(directory, 0o700)
        let socketPath = (directory as NSString).appendingPathComponent("b")
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .notAvailable("socket failed") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            rmdir(directory)
            throw .notAvailable("The temporary folder path is too long for a socket.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            unlink(socketPath)
            rmdir(directory)
            throw .notAvailable("The credential broker couldn't listen.")
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        listener = descriptor
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytesShim.fill(&nonceBytes)
        endpoint = BrokerEndpoint(
            socketPath: socketPath, nonce: nonceBytes.map { String(format: "%02x", $0) }.joined())
        state = Mutex(State())
        queue = DispatchQueue(label: "jit.credential-broker")
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let policy = policy
        let expected = expectedPeer.map { (($0 as NSString).resolvingSymlinksInPath as NSString).standardizingPath }
        source.setEventHandler { [weak self] in
            self?.acceptConnections(policy: policy, source: credentialSource, expectedPeer: expected)
        }
        source.resume()
    }

    deinit { shutdown() }

    /// Stops listening, drops open connections and removes the socket directory. Idempotent.
    public func shutdown() {
        let (connections, tasks) = state.withLock { state -> ([Int32: any DispatchSourceRead], [Task<Void, Never>]) in
            guard !state.closed else { return ([:], []) }
            state.closed = true
            defer {
                state.connections = [:]
                state.buffers = [:]
            }
            return (state.connections, state.tasks)
        }
        guard !source.isCancelled else { return }
        source.cancel()
        close(listener)
        for (descriptor, connection) in connections {
            connection.cancel()
            close(descriptor)
        }
        for task in tasks { task.cancel() }
        unlink(endpoint.socketPath)
        rmdir(directory)
    }

    private func refuse(_ reason: String) {
        refusals.withLock { $0.append(reason) }
        brokerLog.notice("Credential request refused: \(reason, privacy: .public)")
    }

    private func acceptConnections(policy: BrokerPolicy, source: any CredentialSource, expectedPeer: String?) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            if let expectedPeer, Self.peerPath(client) != expectedPeer {
                refuse("unexpected peer process")
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            let accepted = state.withLock { state -> Bool in
                guard !state.closed else { return false }
                state.connections[client] = reader
                state.buffers[client] = []
                return true
            }
            guard accepted else {
                close(client)
                return
            }
            reader.setEventHandler { [weak self] in
                self?.readRequest(client, policy: policy, source: source)
            }
            reader.resume()
        }
    }

    private func readRequest(_ client: Int32, policy: BrokerPolicy, source: any CredentialSource) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        var finished = false
        while true {
            let count = read(client, &chunk, chunk.count)
            if count > 0 {
                let tooLarge = state.withLock { state -> Bool in
                    state.buffers[client, default: []] += chunk[0..<count]
                    return (state.buffers[client]?.count ?? 0) > 16 * 1024
                }
                if tooLarge {
                    refuse("oversized request")
                    drop(client)
                    return
                }
                continue
            }
            if count == 0 { finished = true }
            if count < 0 && errno == EINTR { continue }
            break
        }
        let buffer = state.withLock { $0.buffers[client] ?? [] }
        // Complete when the helper closed its write side, or a blank line ended the header.
        guard finished || buffer.suffix(2) == [10, 10] else { return }
        state.withLock { state in
            state.connections[client]?.cancel()
            state.connections[client] = nil
            state.buffers[client] = nil
        }
        let task = Task { [weak self] in
            guard let self else {
                close(client)
                return
            }
            let response = await self.respond(to: buffer, policy: policy, source: source)
            response.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count, let base = bytes.baseAddress {
                    let written = write(client, base + offset, bytes.count - offset)
                    if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    if written <= 0 { break }
                    offset += written
                }
            }
            var wiped = response
            wiped.withUnsafeMutableBytes { if let base = $0.baseAddress { memset_s(base, $0.count, 0, $0.count) } }
            close(client)
        }
        state.withLock { $0.tasks.append(task) }
    }

    private func drop(_ client: Int32) {
        state.withLock { state in
            state.connections[client]?.cancel()
            state.connections[client] = nil
            state.buffers[client] = nil
        }
        close(client)
    }

    static let refusedResponse = Array("status=refused\n\n".utf8)

    /// Parses one request and returns the response bytes (secret bytes copied straight from `SecretBytes`).
    func respond(to request: [UInt8], policy: BrokerPolicy, source: any CredentialSource) async -> [UInt8] {
        let overLimit = state.withLock { state -> Bool in
            state.requests += 1
            return state.requests > Self.requestLimit || state.closed
        }
        guard !overLimit else {
            refuse("request limit reached")
            return Self.refusedResponse
        }
        let text = String(decoding: request, as: UTF8.self)
        var fields: [String: String] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            if fields[key] == nil { order.append(key) }
            fields[key] = String(line[line.index(after: equals)...])
        }
        guard order.first == "nonce", let nonce = fields["nonce"], Self.constantTimeEqual(nonce, endpoint.nonce) else {
            refuse("bad nonce")
            return Self.refusedResponse
        }
        switch fields["mode"] {
        case "credential":
            return await credential(fields, policy: policy, source: source)
        case "askpass":
            return await askpass(fields["prompt"] ?? "", policy: policy, source: source)
        default:
            refuse("unknown mode")
            return Self.refusedResponse
        }
    }

    private func credential(_ fields: [String: String], policy: BrokerPolicy, source: any CredentialSource) async
        -> [UInt8]
    {
        let scheme = (fields["protocol"] ?? "").lowercased()
        let hostField = (fields["host"] ?? "").lowercased()
        var host = hostField
        var port: Int?
        if let colon = hostField.lastIndex(of: ":"), !hostField.hasSuffix("]") {
            host = String(hostField[..<colon])
            port = Int(hostField[hostField.index(after: colon)...])
        }
        let action = fields["action"] ?? ""
        if let target = policy.https.first(where: { target in
            target.host == host && (port ?? (scheme == "http" ? 80 : 443)) == target.port
                && (scheme == "https" || (scheme == "http" && target.allowPlainHTTP))
        }) {
            switch action {
            case "get":
                do throws(CredentialError) {
                    let pair = try await source.httpsCredential(accountID: target.accountID, host: host)
                    return Self.okResponse(username: pair.username, secret: pair.secret)
                } catch {
                    refuse("no credential for \(host)")
                    return Self.refusedResponse
                }
            case "erase":
                await source.credentialRejected(accountID: target.accountID, host: host)
                return Array("status=ok\n\n".utf8)
            case "store":
                await source.credentialAccepted(accountID: target.accountID, host: host)
                return Array("status=ok\n\n".utf8)
            default:
                return Self.refusedResponse
            }
        }
        if action == "get",
            let proxy = policy.proxies.first(where: { $0.host == host && (port ?? 80) == $0.port })
        {
            do throws(CredentialError) {
                let pair = try await source.proxyCredential(proxyID: proxy.proxyID, username: proxy.username)
                return Self.okResponse(username: pair.username, secret: pair.secret)
            } catch {
                refuse("no proxy credential for \(host)")
                return Self.refusedResponse
            }
        }
        if action == "get" { refuse("unexpected host \(host)") }
        return Self.refusedResponse
    }

    private func askpass(_ prompt: String, policy: BrokerPolicy, source: any CredentialSource) async -> [UInt8] {
        let lower = prompt.lowercased()
        guard let key = policy.sshKey, lower.contains("passphrase"), Self.promptNamesKey(prompt, path: key.path) else {
            refuse("unexpected askpass prompt")
            return Self.refusedResponse
        }
        do throws(CredentialError) {
            let secret = try await source.sshPassphrase(keyPath: key.path, fingerprint: key.fingerprint, prompt: prompt)
            return Self.okResponse(username: nil, secret: secret)
        } catch {
            refuse("passphrase not provided")
            return Self.refusedResponse
        }
    }

    /// `Enter passphrase for key '<path>': ` — ssh truncates long paths in the prompt, so the quoted path must be
    /// the key's path or a (long enough) prefix of it. ssh can only use that key anyway (`IdentitiesOnly`, `-i`).
    static func promptNamesKey(_ prompt: String, path: String) -> Bool {
        guard let open = prompt.range(of: "key '") else { return false }
        let rest = prompt[open.upperBound...]
        let quoted = rest.range(of: "'").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        guard !quoted.isEmpty else { return false }
        return quoted == path || (path.hasPrefix(quoted) && quoted.count >= min(path.count, 24))
    }

    static func okResponse(username: String?, secret: SecretBytes) -> [UInt8] {
        guard username?.contains("\n") != true, !secret.contains([10]) else { return refusedResponse }
        var header = "status=ok\n"
        if let username { header += "username=\(username)\n" }
        header += "secret-length=\(secret.count)\n"
        var bytes = Array(header.utf8)
        secret.withUnsafeBytes { bytes += $0 }
        return bytes
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    /// The executable path of the process on the other end of a Unix socket.
    static func peerPath(_ descriptor: Int32) -> String? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard pathLength > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(pathLength)), as: UTF8.self)
        return ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    }
}

/// `SecRandomCopyBytes` without importing Security in every file.
enum SecRandomCopyBytesShim {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        arc4random_buf(&bytes, bytes.count)
        return true
    }
}
