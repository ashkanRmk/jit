import Foundation

/// The repository's object format (`extensions.objectformat`).
public enum ObjectFormat: UInt8, Sendable, Hashable {
    case sha1
    case sha256

    /// Bytes in a full object id.
    public var byteCount: Int { self == .sha1 ? 20 : 32 }
    public var hexCount: Int { byteCount * 2 }
}

/// A Git object id stored inline in 32 bytes (four words, big-endian byte order); SHA-1 ids leave the
/// last 12 bytes zero. A trivial value type: no heap allocation, cheap to hash and compare (ADR-0022).
/// One layout for both formats keeps every column monomorphic; SHA-1 repositories pay 12 bytes per
/// commit for it.
public struct ObjectID: Sendable, Hashable, Comparable {
    public var w0: UInt64
    public var w1: UInt64
    public var w2: UInt64
    public var w3: UInt64

    public static let zero = ObjectID(w0: 0, w1: 0, w2: 0, w3: 0)

    public init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    /// Parses 40 or 64 lowercase/uppercase hex digits. `nil` for any other length or a non-hex byte.
    public init?(hex bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 40 || bytes.count == 64 else { return nil }
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        var ok = true
        withUnsafeMutableBytes(of: &words) { raw in
            var out = 0
            var index = 0
            while index < bytes.count {
                guard let high = Self.nibble(bytes[index]), let low = Self.nibble(bytes[index + 1]) else {
                    ok = false
                    return
                }
                // Place bytes so that, read as big-endian words, the id's byte order is preserved.
                raw[Self.storageIndex(out)] = high << 4 | low
                out += 1
                index += 2
            }
        }
        guard ok else { return nil }
        self.init(w0: words.0, w1: words.1, w2: words.2, w3: words.3)
    }

    public init?(hex string: some StringProtocol) {
        var copy = String(string)
        guard let parsed = copy.withUTF8({ ObjectID(hex: UnsafeRawBufferPointer($0)) }) else { return nil }
        self = parsed
    }

    public init?(hex bytes: ArraySlice<UInt8>) {
        guard let parsed = bytes.withUnsafeBytes({ ObjectID(hex: $0) }) else { return nil }
        self = parsed
    }

    /// Byte `n` of the id lives at this offset of the little-endian word storage.
    @inline(__always) static func storageIndex(_ n: Int) -> Int { (n & ~7) + (7 - (n & 7)) }

    @inline(__always) static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c &- 0x30
        case 0x61...0x66: c &- 0x61 &+ 10
        case 0x41...0x46: c &- 0x41 &+ 10
        default: nil
        }
    }

    /// Byte `n` (0-based) of the id.
    @inline(__always) public func byte(_ n: Int) -> UInt8 {
        let word: UInt64
        switch n >> 3 {
        case 0: word = w0
        case 1: word = w1
        case 2: word = w2
        default: word = w3
        }
        return UInt8(truncatingIfNeeded: word >> UInt64(56 - (n & 7) * 8))
    }

    static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase hex of the first `length` digits.
    public func hex(_ format: ObjectFormat = .sha1, length: Int? = nil) -> String {
        let digits = min(length ?? format.hexCount, format.hexCount)
        return String(unsafeUninitializedCapacity: digits) { buffer in
            for index in 0..<digits {
                let value = byte(index >> 1)
                buffer[index] = Self.hexDigits[Int(index & 1 == 0 ? value >> 4 : value & 0xF)]
            }
            return digits
        }
    }

    /// Whether the id's hex form starts with `prefix` (lowercase hex digits only, ≤ 64).
    public func hasHexPrefix(_ prefix: UnsafeRawBufferPointer) -> Bool {
        guard prefix.count <= 64 else { return false }
        for index in 0..<prefix.count {
            let value = byte(index >> 1)
            let digit = Self.hexDigits[Int(index & 1 == 0 ? value >> 4 : value & 0xF)]
            if digit != prefix[index] { return false }
        }
        return true
    }

    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool {
        (lhs.w0, lhs.w1, lhs.w2, lhs.w3) < (rhs.w0, rhs.w1, rhs.w2, rhs.w3)
    }
}

extension ObjectID: CustomStringConvertible {
    /// Debug form: SHA-1 length unless the SHA-256 tail is used.
    public var description: String { hex(w2 & 0xFFFF_FFFF == 0 && w3 == 0 ? .sha1 : .sha256) }
}

/// 64-bit FNV-1a: stable across processes and launches (unlike Swift's seeded `Hasher`). Used for lane
/// colour assignment, avatar colours and revision tokens.
public struct StableHash: Sendable {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    @inline(__always) public mutating func combine(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
    }

    public mutating func combine(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes { combine(byte) }
    }

    public mutating func combine(_ string: String) {
        var copy = string
        copy.withUTF8 { combine(UnsafeRawBufferPointer($0)) }
    }

    public mutating func combine(_ id: ObjectID) {
        for n in 0..<32 { combine(id.byte(n)) }
    }

    public static func of(_ string: String) -> UInt64 {
        var hash = StableHash()
        hash.combine(string)
        return hash.value
    }
}
