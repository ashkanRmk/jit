import CryptoKit
import Darwin
import Foundation

/// Cryptographically secure random bytes (`arc4random_buf`, the system CSPRNG).
func secureRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    bytes.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
    }
    return bytes
}

/// Base64url without padding (RFC 4648 §5).
func base64URL<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Zeroes a scratch buffer that held secret bytes.
func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
    }
    bytes.removeAll()
}

func wipe(_ data: inout Data) {
    data.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
    }
    data.removeAll()
}

/// PKCE (RFC 7636) with the S256 method. The verifier is a one-shot value that lives only for one sign-in.
public struct PKCE: Sendable, Hashable {
    /// 43 characters: base64url of 32 random bytes.
    public let verifier: String
    public let challenge: String
    public static let method = "S256"

    public init() { self.init(verifier: base64URL(secureRandomBytes(32))) }

    /// For tests and RFC vectors. `verifier` must be 43–128 unreserved characters.
    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`.
    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(data: Data(verifier.utf8)))
    }
}

/// The OAuth `state` parameter: 128 random bits, compared in constant time.
public struct OAuthState: Sendable, Hashable {
    public let value: String

    public init() { value = base64URL(secureRandomBytes(16)) }
    init(value: String) { self.value = value }

    public func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let a = Array(value.utf8)
        let b = Array(candidate.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

/// An `application/x-www-form-urlencoded` body. Secret values are percent-encoded byte by byte straight into
/// the body without becoming a `String`.
struct FormBody {
    enum Value {
        case text(String)
        case secret(SecretBytes)
    }

    var fields: [(String, Value)]

    func encoded() -> Data {
        var bytes: [UInt8] = []
        for (index, field) in fields.enumerated() {
            if index > 0 { bytes.append(UInt8(ascii: "&")) }
            Self.append(Array(field.0.utf8), to: &bytes)
            bytes.append(UInt8(ascii: "="))
            switch field.1 {
            case .text(let text): Self.append(Array(text.utf8), to: &bytes)
            case .secret(let secret): secret.withUnsafeBytes { Self.append($0, to: &bytes) }
            }
        }
        let data = Data(bytes)
        wipe(&bytes)
        return data
    }

    private static let hex = Array("0123456789ABCDEF".utf8)

    private static func append<Bytes: Collection>(_ source: Bytes, to bytes: inout [UInt8])
    where Bytes.Element == UInt8 {
        for byte in source {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                UInt8(ascii: "~"):
                bytes.append(byte)
            default:
                bytes.append(UInt8(ascii: "%"))
                bytes.append(hex[Int(byte >> 4)])
                bytes.append(hex[Int(byte & 0x0F)])
            }
        }
    }
}

/// A tiny reader for a flat JSON object that yields string values as raw bytes, so token values never pass
/// through `String`. Nested objects/arrays are skipped. Used only for OAuth token payloads.
struct FlatJSON {
    enum Value {
        case string([UInt8])
        case number(Double)
        case bool(Bool)
        case null
        case nested
    }

    private(set) var values: [String: Value] = [:]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var reader = Reader(bytes: bytes)
        guard let parsed = reader.object() else { return nil }
        values = parsed
    }

    func text(_ key: String) -> String? {
        if case .string(let bytes)? = values[key] { return String(decoding: bytes, as: UTF8.self) }
        return nil
    }

    func number(_ key: String) -> Double? {
        switch values[key] {
        case .number(let value)?: return value
        case .string(let bytes)?: return Double(String(decoding: bytes, as: UTF8.self))
        default: return nil
        }
    }

    /// The string value as a secret; the scratch copy is wiped. `nil` when absent or empty.
    func secret(_ key: String) -> SecretBytes? {
        guard case .string(var bytes)? = values[key], !bytes.isEmpty else { return nil }
        let secret = SecretBytes(bytes)
        wipe(&bytes)
        return secret
    }

    /// Zeroes every string value's scratch bytes.
    mutating func wipeAll() {
        for key in values.keys {
            if case .string(var bytes)? = values[key] {
                wipe(&bytes)
                values[key] = .null
            }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) -> Bool {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func object() -> [String: Value]? {
            guard expect(UInt8(ascii: "{")) else { return nil }
            var result: [String: Value] = [:]
            if expect(UInt8(ascii: "}")) { return result }
            while true {
                skipSpace()
                guard var keyBytes = string() else { return nil }
                let key = String(decoding: keyBytes, as: UTF8.self)
                keyBytes.removeAll()
                guard expect(UInt8(ascii: ":")), let value = value() else { return nil }
                result[key] = value
                if expect(UInt8(ascii: ",")) { continue }
                guard expect(UInt8(ascii: "}")) else { return nil }
                return result
            }
        }

        mutating func value() -> Value? {
            skipSpace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "{"), UInt8(ascii: "["): return skipNested() ? .nested : nil
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            default:
                let start = index
                while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
                return Double(String(decoding: bytes[start..<index], as: UTF8.self)).map { .number($0) }
            }
        }

        mutating func literal(_ word: String) -> Bool {
            let target = Array(word.utf8)
            guard index + target.count <= bytes.count, Array(bytes[index..<index + target.count]) == target else {
                return false
            }
            index += target.count
            return true
        }

        mutating func skipNested() -> Bool {
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    guard string() != nil else { return false }
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return true
                    }
                }
                index += 1
            }
            return false
        }

        /// Reads a JSON string at `index` (which must be `"`), decoding escapes to UTF-8 bytes.
        mutating func string() -> [UInt8]? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return out
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var scalar = hex4() else { return nil }
                        if (0xD800..<0xDC00).contains(scalar), literal("\\u"), let low = hex4(),
                            (0xDC00..<0xE000).contains(low)
                        {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { return nil }
                        out.append(contentsOf: Array(String(Character(unicode)).utf8))
                    default: return nil
                    }
                default:
                    out.append(byte)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count,
                let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { return nil }
            index += 4
            return value
        }
    }
}

/// An OAuth token set. Secret parts stay in `SecretBytes`; descriptions are redacted.
public struct OAuthTokens: Sendable, CustomStringConvertible {
    public let access: SecretBytes
    public let refresh: SecretBytes?
    public let expiresAt: Date?
    public let tokenType: String
    public let scopes: [String]

    public init(
        access: SecretBytes, refresh: SecretBytes?, expiresAt: Date?, tokenType: String = "bearer",
        scopes: [String] = []
    ) {
        self.access = access
        self.refresh = refresh
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scopes = scopes
    }

    /// Whether the access token is expired or expires within `leeway` seconds of `now`.
    public func expires(within leeway: TimeInterval, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    public var description: String {
        "OAuthTokens(type: \(tokenType), expiresAt: \(expiresAt.map { "\($0)" } ?? "never"), refresh: \(refresh != nil))"
    }

    /// Parses an RFC 6749 §5.1 token response (or §5.2 error → `OAuthError.provider`).
    static func parse(response data: Data, now: Date) throws -> OAuthTokens {
        guard var json = FlatJSON(data) else { throw OAuthError.invalidResponse }
        defer { json.wipeAll() }
        if let code = json.text("error") { throw OAuthError.provider(code: OAuthError.sanitizedCode(code)) }
        guard let access = json.secret("access_token") else { throw OAuthError.invalidResponse }
        let scopes = (json.text("scope") ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        return OAuthTokens(
            access: access, refresh: json.secret("refresh_token"),
            expiresAt: json.number("expires_in").flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil },
            tokenType: json.text("token_type")?.lowercased() ?? "bearer", scopes: scopes)
    }

    // MARK: Keychain encoding

    /// Serialized form for one Keychain item: JSON with base64-encoded secrets, built byte by byte so the
    /// tokens never become `String`s. Returned as `SecretBytes` (wiped on release).
    public func keychainData() -> SecretBytes {
        var bytes: [UInt8] = []
        func appendText(_ text: String) { bytes.append(contentsOf: Array(text.utf8)) }
        func appendSecret(_ secret: SecretBytes) {
            var encoded = secret.withUnsafeBytes { Data($0) }.base64EncodedData()
            bytes.append(UInt8(ascii: "\""))
            bytes.append(contentsOf: encoded)
            bytes.append(UInt8(ascii: "\""))
            wipe(&encoded)
        }
        appendText("{\"v\":1,\"token_type\":")
        appendText(Self.jsonString(tokenType))
        if let expiresAt { appendText(",\"expires_at\":\(expiresAt.timeIntervalSince1970)") }
        appendText(",\"scope\":")
        appendText(Self.jsonString(scopes.joined(separator: " ")))
        appendText(",\"access\":")
        appendSecret(access)
        if let refresh {
            appendText(",\"refresh\":")
            appendSecret(refresh)
        }
        appendText("}")
        let secret = SecretBytes(bytes)
        wipe(&bytes)
        return secret
    }

    /// Reads `keychainData()` output.
    public init(keychainData: SecretBytes) throws {
        var data = keychainData.dataCopy()
        defer { wipe(&data) }
        guard var json = FlatJSON(data), json.number("v") == 1 else { throw OAuthError.invalidResponse }
        defer { json.wipeAll() }
        func decodeSecret(_ key: String) -> SecretBytes? {
            guard case .string(let encoded)? = json.values[key], var raw = Data(base64Encoded: Data(encoded)) else {
                return nil
            }
            defer { wipe(&raw) }
            return SecretBytes(raw)
        }
        guard let access = decodeSecret("access") else { throw OAuthError.invalidResponse }
        self.init(
            access: access, refresh: decodeSecret("refresh"),
            expiresAt: json.number("expires_at").map(Date.init(timeIntervalSince1970:)),
            tokenType: json.text("token_type") ?? "bearer",
            scopes: (json.text("scope") ?? "").split(separator: " ").map(String.init))
    }

    private static func jsonString(_ text: String) -> String {
        let data =
            (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}

/// Sends an OAuth form POST (no `Authorization` header; client ID only, never a secret).
func postForm(_ url: URL, _ body: FormBody, transport: any HTTPTransport) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(ProviderHTTP.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpShouldHandleCookies = false
    request.httpBody = body.encoded()
    do {
        return try await transport.data(for: request)
    } catch let error as URLError {
        throw OAuthError.request(.transport(ProviderHTTP.scrubbed(error)))
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as ProviderError {
        throw OAuthError.request(error)
    } catch {
        throw OAuthError.invalidResponse
    }
}
