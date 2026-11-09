import Darwin
import Foundation

/// A secret (token, password, passphrase) held in a manually allocated buffer that is wiped with `memset_s`
/// when the last reference goes away (design §4.3). It never converts to `String`, and every textual
/// representation is `<redacted>`, so a secret can't end up in logs, error details or crash output by accident.
public final class SecretBytes: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let buffer: UnsafeMutableRawBufferPointer
    public let count: Int

    /// Test-only: observes the buffer right after it was wiped (proves the wipe without reading freed memory).
    nonisolated(unsafe) static var wipeObserver: ((UnsafeRawBufferPointer) -> Void)?

    public init<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        count = bytes.count
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(count, 1), alignment: 1)
        _ = buffer.initializeMemory(as: UInt8.self, from: bytes)
    }

    /// Copies the UTF-8 bytes of text the user typed into a secure field. The caller should drop its
    /// `String` immediately; this is the only `String → secret` path.
    public convenience init(utf8 text: String) {
        self.init(Array(text.utf8))
    }

    deinit {
        if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
        Self.wipeObserver?(UnsafeRawBufferPointer(buffer))
        buffer.deallocate()
    }

    public var isEmpty: Bool { count == 0 }

    /// Scoped access to the bytes (to write them to a socket or hand them to the Keychain).
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: buffer.baseAddress, count: count))
    }

    /// A `Data` copy for APIs that require it (Keychain, URLRequest bodies). Keep its lifetime short.
    public func dataCopy() -> Data { withUnsafeBytes { Data($0) } }

    /// Constant-time comparison.
    public func constantTimeEquals(_ other: SecretBytes) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBytes { a in
            other.withUnsafeBytes { b in
                var difference: UInt8 = 0
                for index in 0..<count { difference |= a[index] ^ b[index] }
                return difference == 0
            }
        }
    }

    public func contains(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        return withUnsafeBytes { bytes in
            for start in 0...(count - needle.count) where bytes[start] == needle[0] {
                if (0..<needle.count).allSatisfy({ bytes[start + $0] == needle[$0] }) { return true }
            }
            return false
        }
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

/// A username + secret for HTTPS (`x-access-token` / `oauth2` / login + token) or a proxy.
public struct SecretPair: Sendable {
    public var username: String
    public var secret: SecretBytes

    public init(username: String, secret: SecretBytes) {
        self.username = username
        self.secret = secret
    }
}
