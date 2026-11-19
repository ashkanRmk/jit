import CryptoKit
import Foundation

/// Pinned in the installed app by the release build. The feed cannot supply or change this key.
public struct UpdateSigningKey: Sendable {
    public static let bundleKey = "JitUpdatePublicKey"
    let hex: String
    private let publicKey: Curve25519.Signing.PublicKey

    public init?(hex: String) {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy(Self.isLowercaseHex) else { return nil }
        var bytes = Data()
        var digits = hex.utf8.makeIterator()
        while let high = digits.next(), let low = digits.next() {
            bytes.append(Self.nibble(high) * 16 + Self.nibble(low))
        }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { return nil }
        self.hex = hex
        self.publicKey = publicKey
    }

    /// The exact, domain-specific UTF-8 payload used by scripts/release/update-signing.sh.
    /// Verify before interpreting the version or checksum, and accept only one canonical representation.
    func verifiedChecksum(manifest: Data, signature: Data, version: AppVersion) throws -> String {
        let prefix = Data("Jit Update Manifest v1\nversion=\(version)\nsha256=".utf8)
        guard signature.count == 64, manifest.count <= 256,
            publicKey.isValidSignature(signature, for: manifest)
        else { throw UpdateError.invalidUpdateSignature }
        guard manifest.count == prefix.count + 65, manifest.starts(with: prefix), manifest.last == 10 else {
            throw UpdateError.invalidUpdateManifest
        }
        let digest = manifest.dropFirst(prefix.count).dropLast()
        guard digest.allSatisfy(Self.isLowercaseHex) else { throw UpdateError.invalidUpdateManifest }
        return String(decoding: digest, as: UTF8.self)
    }

    private static func isLowercaseHex(_ digit: UInt8) -> Bool {
        (48...57).contains(digit) || (97...102).contains(digit)
    }

    private static func nibble(_ digit: UInt8) -> UInt8 { digit < 97 ? digit - 48 : digit - 87 }
}
