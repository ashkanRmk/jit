import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization

/// A CA certificate the user imported for an instance (design §4.10). Public data; integrity matters, so files
/// are `0600` in a `0700` directory.
public struct CertificateInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    /// Uppercase hex with colons.
    public var sha256: String
    public var isCA: Bool
    public var isSelfSigned: Bool

    public func expiresSoon(now: Date = Date()) -> Bool {
        guard let notAfter else { return false }
        return notAfter.timeIntervalSince(now) < 30 * 24 * 3600
    }

    public func isExpired(now: Date = Date()) -> Bool { notAfter.map { $0 < now } ?? false }
}

public enum CertificateImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable
    case notACertificateAuthority(subject: String)

    public var description: String {
        switch self {
        case .unreadable:
            "This file isn't a PEM, DER or .cer certificate."
        case .notACertificateAuthority(let subject):
            "“\(subject)” is a server (leaf) certificate, not a certificate authority. Import the CA that issued it — ask your IT department for the root or intermediate CA certificate."
        }
    }
}

/// Imported CA certificates under `AppSupport/Jit/ca/<id>.pem`, plus combined bundles for instances with more
/// than one CA (rotation: add the new CA, remove the old one later).
public struct CAStore: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public init(location: StoreLocation = .applicationSupport()) {
        directory = location.url("ca").path
    }

    public func path(_ id: String) -> String { (directory as NSString).appendingPathComponent("\(id).pem") }

    /// Parses PEM (one or more blocks; the first is used) or DER.
    public static func certificates(from data: Data) -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            var result: [SecCertificate] = []
            for block in text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
                guard let end = block.range(of: "-----END CERTIFICATE-----") else { continue }
                let body = block[..<end.lowerBound].filter { !$0.isWhitespace }
                if let der = Data(base64Encoded: String(body)),
                    let certificate = SecCertificateCreateWithData(nil, der as CFData)
                {
                    result.append(certificate)
                }
            }
            return result
        }
        return SecCertificateCreateWithData(nil, data as CFData).map { [$0] } ?? []
    }

    public static func info(_ certificate: SecCertificate) -> CertificateInfo {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unnamed certificate"
        var issuer = subject
        var notBefore: Date?
        var notAfter: Date?
        var isCA = false
        let keys =
            [
                kSecOIDBasicConstraints, kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore,
                kSecOIDX509V1ValidityNotAfter,
            ] as CFArray
        if let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] {
            if let constraints = values[kSecOIDBasicConstraints as String]?[kSecPropertyKeyValue as String]
                as? [[String: Any]]
            {
                for entry in constraints {
                    let label = (entry[kSecPropertyKeyLabel as String] as? String) ?? ""
                    let value = "\(entry[kSecPropertyKeyValue as String] ?? "")"
                    if label.localizedCaseInsensitiveContains("Certificate Authority"), value == "Yes" || value == "1" {
                        isCA = true
                    }
                }
            }
            if let names = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String]
                as? [[String: Any]]
            {
                let commonName = names.first { ($0[kSecPropertyKeyLabel as String] as? String) == "2.5.4.3" }
                if let value = commonName?[kSecPropertyKeyValue as String] as? String { issuer = value }
            }
            func date(_ key: CFString) -> Date? {
                (values[key as String]?[kSecPropertyKeyValue as String] as? NSNumber).map {
                    Date(timeIntervalSinceReferenceDate: $0.doubleValue)
                }
            }
            notBefore = date(kSecOIDX509V1ValidityNotBefore)
            notAfter = date(kSecOIDX509V1ValidityNotAfter)
        }
        let selfSigned = issuer == subject
        return CertificateInfo(
            id: String(digest.replacingOccurrences(of: ":", with: "").prefix(16)).lowercased(), subject: subject,
            issuer: issuer, notBefore: notBefore, notAfter: notAfter, sha256: digest, isCA: isCA,
            isSelfSigned: selfSigned)
    }

    /// Validates (must be a CA — leaf certificates are rejected) without storing.
    public static func inspect(_ data: Data) throws(CertificateImportError) -> (SecCertificate, CertificateInfo) {
        guard let certificate = certificates(from: data).first else { throw .unreadable }
        let info = info(certificate)
        guard info.isCA else { throw .notACertificateAuthority(subject: info.subject) }
        return (certificate, info)
    }

    /// Stores a validated CA as PEM and returns its info (the id is derived from the SHA-256).
    @discardableResult
    public func importCA(_ data: Data) throws(CertificateImportError) -> CertificateInfo {
        let (certificate, info) = try Self.inspect(data)
        do {
            try ensureDirectory()
            try write(Self.pem(certificate), to: path(info.id))
        } catch {
            throw .unreadable
        }
        return info
    }

    public func load(_ id: String) -> (SecCertificate, CertificateInfo)? {
        guard let data = FileManager.default.contents(atPath: path(id)),
            let certificate = Self.certificates(from: data).first
        else { return nil }
        return (certificate, Self.info(certificate))
    }

    public func certificates(_ ids: [String]) -> [SecCertificate] { ids.compactMap { load($0)?.0 } }

    public func remove(_ id: String) {
        unlink(path(id))
    }

    /// For combined paths (`<a>+<b>.pem`) writes the concatenation of the member PEMs.
    public func ensureBundle(at bundlePath: String) throws {
        let name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ids = name.split(separator: "+").map(String.init)
        guard ids.count > 1 else { return }
        var combined = Data()
        for id in ids {
            guard let data = FileManager.default.contents(atPath: path(id)) else { continue }
            combined.append(data)
        }
        try ensureDirectory()
        try write(combined, to: bundlePath)
    }

    static func pem(_ certificate: SecCertificate) -> Data {
        let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n".utf8)
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func write(_ data: Data, to path: String) throws {
        try JSONFile.write(data, to: URL(fileURLWithPath: path))
    }
}

/// URLSession trust evaluation for custom CAs (design §4.10, ADR-0018): only for the configured host:port,
/// anchors = the instance's CAs *plus* system roots, SSL policy with hostname. Everything else → default
/// handling. There is no code path that accepts an untrusted certificate.
public final class ScopedTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    public struct Scope: Sendable {
        public var host: String
        public var port: Int
        public var anchors: [SecCertificate]

        public init(host: String, port: Int, anchors: [SecCertificate]) {
            self.host = host.lowercased()
            self.port = port
            self.anchors = anchors
        }
    }

    let scopes: [Scope]
    /// Proxy credentials for 407 challenges (Keychain-backed).
    let proxyCredential: (@Sendable (_ host: String, _ port: Int) async -> URLCredential?)?
    /// The last trust failure (for diagnostics).
    public let lastTrustFailure = Mutex<String?>(nil)

    public init(
        scopes: [Scope], proxyCredential: (@Sendable (_ host: String, _ port: Int) async -> URLCredential?)? = nil
    ) {
        self.scopes = scopes
        self.proxyCredential = proxyCredential
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await handle(challenge)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await handle(challenge)
    }

    func handle(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let space = challenge.protectionSpace
        if space.proxyType != nil {
            guard challenge.previousFailureCount == 0, let proxyCredential,
                let credential = await proxyCredential(space.host, space.port)
            else { return (.performDefaultHandling, nil) }
            return (.useCredential, credential)
        }
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
            let scope = scopes.first(where: { $0.host == space.host.lowercased() && $0.port == space.port })
        else { return (.performDefaultHandling, nil) }
        let (trusted, message) = Self.evaluate(trust, host: scope.host, anchors: scope.anchors)
        if trusted { return (.useCredential, URLCredential(trust: trust)) }
        lastTrustFailure.withLock { $0 = message }
        return (.cancelAuthenticationChallenge, nil)
    }

    /// `SecTrustSetAnchorCertificatesOnly(false)` keeps the system roots valid alongside the custom CAs.
    public static func evaluate(_ trust: SecTrust, host: String, anchors: [SecCertificate]) -> (Bool, String?) {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        return (ok, ok ? nil : error.map { CFErrorCopyDescription($0) as String } ?? "The certificate isn't trusted.")
    }
}
