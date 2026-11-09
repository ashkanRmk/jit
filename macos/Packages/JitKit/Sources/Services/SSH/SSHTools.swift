import CryptoKit
import Darwin
import Foundation
import GitCore

/// A host key offered by an SSH server (from `ssh-keyscan`).
public struct SSHHostKey: Sendable, Hashable, Identifiable {
    public var host: String
    public var port: Int
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, …
    public var type: String
    /// Base64 public key blob.
    public var key: String
    /// `SHA256:…` (OpenSSH format).
    public var fingerprint: String

    public var id: String { type + key }

    /// The human key type ("ED25519", "ECDSA", "RSA").
    public var displayType: String {
        if type.contains("ed25519") { return "ED25519" }
        if type.contains("ecdsa") { return "ECDSA" }
        if type.contains("rsa") { return "RSA" }
        return type
    }
}

/// The OpenSSH tools Jit runs, always with argv arrays and fixed paths (design §4.6, ADR-0036).
public enum SSHTools {
    static let keygen = "/usr/bin/ssh-keygen"
    static let keyscan = "/usr/bin/ssh-keyscan"

    static func run(
        _ executable: String, _ arguments: [String], stdin: [UInt8]? = nil, timeout: Duration = .seconds(20)
    )
        async -> ProcessOutput?
    {
        let spec = ProcessSpec(
            executable: executable, arguments: arguments, workingDirectory: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": NSHomeDirectory()], timeout: timeout,
            stdoutLimit: 1024 * 1024, acceptedExitCodes: [0, 1], stdin: stdin)
        return try? await ProcessRunner().run(spec)
    }

    /// `SHA256:…` of a key file (`ssh-keygen -lf`; the `.pub` next to it is preferred so encrypted private keys
    /// need no passphrase).
    public static func fingerprint(ofKeyFile path: String) async -> String? {
        let publicKey = path.hasSuffix(".pub") ? path : path + ".pub"
        let target = FileManager.default.fileExists(atPath: publicKey) ? publicKey : path
        guard let output = await run(keygen, ["-l", "-E", "sha256", "-f", target]), output.exitCode == 0 else {
            return nil
        }
        return parseFingerprint(output.stdoutText)
    }

    /// "256 SHA256:abc comment (ED25519)" → "SHA256:abc".
    static func parseFingerprint(_ line: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init)
    }

    /// Asks the server for its host keys (`ssh-keyscan -p <port> -t ed25519,ecdsa,rsa -- <host>`) and
    /// fingerprints them via `ssh-keygen -lf -` (stdin). Nothing is written anywhere.
    public static func scanHostKeys(host: String, port: Int, proxy: SSHProxy? = nil) async -> [SSHHostKey] {
        guard HostSyntax.isHostname(host), (1...65_535).contains(port) else { return [] }
        guard proxy == nil else { return [] }  // ssh-keyscan has no ProxyCommand; the trust sheet explains.
        guard let output = await run(keyscan, ["-p", "\(port)", "-T", "10", "-t", "ed25519,ecdsa,rsa", "--", host])
        else {
            return []
        }
        var keys: [SSHHostKey] = []
        for line in output.stdoutText.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { continue }
            let type = String(parts[1])
            let blob = String(parts[2])
            guard let fingerprint = fingerprint(type: type, base64: blob) else { continue }
            keys.append(SSHHostKey(host: host, port: port, type: type, key: blob, fingerprint: fingerprint))
        }
        return keys
    }

    /// OpenSSH SHA-256 fingerprint: base64 (no padding) of SHA-256 over the decoded key blob.
    public static func fingerprint(type: String, base64: String) -> String? {
        guard let blob = Data(base64Encoded: base64) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(
            in: CharacterSet(charactersIn: "="))
        return "SHA256:" + digest
    }
}

/// Jit's own `known_hosts` file (`AppSupport/Jit/known_hosts`, `0600`), written only after the user verified a
/// fingerprint in the trust sheet. Entries are hashed (`|1|salt|hmac`) like `HashKnownHosts yes`. The user's
/// `~/.ssh/known_hosts` is read by ssh but never written by Jit.
public struct KnownHostsStore: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// `host` for port 22, `[host]:port` otherwise (OpenSSH's known_hosts host pattern).
    static func pattern(host: String, port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    static func hashedHost(_ pattern: String, salt: [UInt8]) -> String {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(pattern.utf8), using: SymmetricKey(data: Data(salt)))
        return "|1|\(Data(salt).base64EncodedString())|\(Data(mac).base64EncodedString())"
    }

    /// Appends the trusted key (hashed host). Refuses to add a key for a host that already has a *different* key of
    /// the same type in this file (that's a changed key — a security error, never "trust again").
    public func trust(_ key: SSHHostKey) throws {
        if let existing = entries(host: key.host, port: key.port).first(where: { $0.type == key.type }) {
            if existing.key == key.key { return }
            throw KnownHostsError.changedKey
        }
        var salt = [UInt8](repeating: 0, count: 20)
        arc4random_buf(&salt, salt.count)
        let line =
            "\(Self.hashedHost(Self.pattern(host: key.host, port: key.port), salt: salt)) \(key.type) \(key.key)\n"
        let directory = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw KnownHostsError.unwritable }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else { throw KnownHostsError.unwritable }
        fchmod(descriptor, 0o600)
    }

    public struct Entry: Sendable, Hashable {
        public var type: String
        public var key: String
    }

    /// Entries in this file matching host:port (hashed or plain).
    public func entries(host: String, port: Int) -> [Entry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Self.entries(in: text, host: host, port: port)
    }

    static func entries(in text: String, host: String, port: Int) -> [Entry] {
        let pattern = Self.pattern(host: host, port: port)
        var result: [Entry] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("@") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { continue }
            let hosts = String(parts[0])
            let matches: Bool
            if hosts.hasPrefix("|1|") {
                let fields = hosts.split(separator: "|")
                guard fields.count == 3, let salt = Data(base64Encoded: String(fields[1])) else { continue }
                matches = hashedHost(pattern, salt: Array(salt)) == hosts
            } else {
                matches = hosts.split(separator: ",").contains { $0.lowercased() == pattern }
            }
            if matches { result.append(Entry(type: String(parts[1]), key: String(parts[2]))) }
        }
        return result
    }
}

public enum KnownHostsError: Error, Sendable, Equatable {
    case changedKey
    case unwritable
}
