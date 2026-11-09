import Foundation

/// A hosting provider's REST API for one account on one instance (design §4.7, ADR-0037). Every call fetches
/// the token just in time through the provider's token closure (so OAuth refresh can happen first) and never
/// retries on its own.
public protocol HostingProvider: Sendable {
    func currentUser() async throws -> ProviderUser
    func tokenInfo() async throws -> TokenInfo
    /// Repositories the account can access, most recently updated first. `page == nil` = first page.
    func repositories(page: PageCursor?, query: String?) async throws -> RepositoryPage
    /// `SHA256:…` SSH host-key fingerprints published by the provider over verified HTTPS; `[]` when there is
    /// no official machine-readable source (gitlab.com, self-managed).
    func publishedSSHFingerprints() async throws -> [String]
}

/// Supplies the account's token just in time. Called once per request; the result is dropped right after.
public typealias TokenProvider = @Sendable () async throws -> SecretBytes

/// Shared request plumbing for provider clients: headers, status → `ProviderError` mapping, pagination.
struct ProviderHTTP: Sendable {
    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    static let userAgent = "Jit"

    /// How the token goes on the wire.
    enum AuthHeader {
        case bearer
        case privateToken
    }

    /// Sends `request` with the token (if any) added under `auth`, maps failures, and returns body + response.
    /// The header string exists only inside this call.
    func send(
        _ request: URLRequest, token: SecretBytes?, auth: AuthHeader, kind: ProviderKind
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        if let token {
            let value = String(decoding: token.dataCopy(), as: UTF8.self)
            switch auth {
            case .bearer: request.setValue("Bearer " + value, forHTTPHeaderField: "Authorization")
            case .privateToken: request.setValue(value, forHTTPHeaderField: "PRIVATE-TOKEN")
            }
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            throw ProviderError.transport(Self.scrubbed(error))
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.invalidResponse
        }
        if (200..<300).contains(response.statusCode) { return (data, response) }
        throw mapFailure(status: response.statusCode, response: response, body: data, token: token, kind: kind)
    }

    /// Maps a non-2xx response (design §4.7). Rate limits never auto-retry.
    func mapFailure(
        status: Int, response: HTTPURLResponse, body: Data, token: SecretBytes?, kind: ProviderKind
    ) -> ProviderError {
        let headers = Headers(response)
        switch status {
        case 401:
            return .unauthorized
        case 403, 429:
            if let reset = rateLimitReset(headers: headers, status: status, kind: kind) {
                return .rateLimited(resetAt: reset)
            }
            if status == 429 { return .rateLimited(resetAt: nil) }
            return .forbidden(Self.serverMessage(body, token: token))
        case 404:
            return .notFound
        default:
            return .server(status)
        }
    }

    /// `Date?` wrapped in an optional: `.some(nil)` = rate-limited without a known reset time.
    private func rateLimitReset(headers: Headers, status: Int, kind: ProviderKind) -> Date?? {
        let retryAfter = headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        switch kind {
        case .github:
            let remaining = headers["x-ratelimit-remaining"]?.trimmingCharacters(in: .whitespaces)
            if let retryAfter { return .some(now().addingTimeInterval(retryAfter)) }
            if remaining == "0" {
                let reset = headers["x-ratelimit-reset"].flatMap {
                    TimeInterval($0.trimmingCharacters(in: .whitespaces))
                }
                return .some(reset.map { Date(timeIntervalSince1970: $0) })
            }
            return nil
        case .gitlab:
            guard status == 429 else { return nil }
            if let reset = headers["ratelimit-reset"].flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
            {
                return .some(Date(timeIntervalSince1970: reset))
            }
            if let retryAfter { return .some(now().addingTimeInterval(retryAfter)) }
            return .some(nil)
        }
    }

    /// The JSON `message`/`error_description`/`error` field, single line, ≤ 200 characters, and dropped
    /// entirely if it contains the token (a misbehaving server echoing credentials).
    static func serverMessage(_ body: Data, token: SecretBytes?) -> String {
        if let token, !token.isEmpty, contains(body, token) { return "" }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        var text = ""
        for key in ["message", "error_description", "error"] {
            if let value = object[key] as? String {
                text = value
                break
            }
            if let value = object[key] as? [String: Any], let first = value.values.first {
                text = "\(first)"
                break
            }
        }
        text = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
        if let token, !token.isEmpty, contains(Data(text.utf8), token) { return "" }
        return text
    }

    private static func contains(_ haystack: Data, _ token: SecretBytes) -> Bool {
        token.withUnsafeBytes { needle in
            guard needle.count <= haystack.count, let first = needle.first else { return false }
            return haystack.withUnsafeBytes { hay in
                for start in 0...(hay.count - needle.count) where hay[start] == first {
                    var match = true
                    for offset in 1..<needle.count where hay[start + offset] != needle[offset] {
                        match = false
                        break
                    }
                    if match { return true }
                }
                return false
            }
        }
    }

    /// Drops the failing URL and underlying error from a `URLError` so nothing but the code travels on.
    static func scrubbed(_ error: URLError) -> URLError {
        var info: [String: Any] = [:]
        if let streamCode = error.userInfo["_kCFStreamErrorCodeKey"] as? Int {
            info["_kCFStreamErrorCodeKey"] = streamCode
        }
        return URLError(error.code, userInfo: info)
    }

    // MARK: Decoding

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    // MARK: URLs

    /// `base` + path components + query, every query value strictly percent-encoded (`+`, `&`, `=` included).
    static func url(_ base: URL, path: String, query: [(String, String)] = []) -> URL? {
        var url = base
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.percentEncodedQuery = query.map { "\(strictEncode($0.0))=\(strictEncode($0.1))" }
            .joined(separator: "&")
        return components.url
    }

    static func strictEncode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The `rel="next"` target of an RFC 8288 `Link` header, only if it has the same origin as `base`
    /// (a foreign host would receive the token on the next request).
    static func nextLink(_ header: String?, sameOriginAs base: URL) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = pieces.dropFirst().contains { parameter in
                let compact = parameter.replacingOccurrences(of: " ", with: "").lowercased()
                guard compact.hasPrefix("rel=") else { return false }
                let values = compact.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return values.split(separator: " ").contains("next") || values == "next"
            }
            guard isNext, let url = URL(string: String(target.dropFirst().dropLast())) else { continue }
            guard let origin = URLOrigin(url), origin == URLOrigin(base),
                origin.scheme == "https" || origin.scheme == "http"
            else { return nil }
            return url
        }
        return nil
    }

    /// Whether `url` may receive this instance's token (same origin as the API base).
    static func isSameOrigin(_ url: URL, as base: URL) -> Bool {
        guard let origin = URLOrigin(url) else { return false }
        return origin == URLOrigin(base)
    }
}

/// Case-insensitive header lookup.
struct Headers {
    private let values: [String: String]

    init(_ response: HTTPURLResponse) {
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { values[key.lowercased()] = value }
        }
        self.values = values
    }

    subscript(name: String) -> String? { values[name.lowercased()] }
}

/// Date parsing for provider payloads and headers.
enum ProviderDates {
    /// ISO 8601 with or without fractional seconds (`2011-01-26T19:14:43Z`, `2013-09-30T13:46:02.000Z`).
    static func iso8601(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// `YYYY-MM-DD` → 00:00 UTC that day (GitLab `expires_at`).
    static func dateOnly(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return iso8601(text) }
        return utcDate(year: parts[0], month: parts[1], day: parts[2], hour: 0, minute: 0, second: 0, offset: 0)
    }

    /// GitHub's `github-authentication-token-expiration`: `2026-12-01 10:00:00 UTC`, `… +0000`, `… -05:00`.
    static func githubExpiration(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2 else { return iso8601(text) }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let time = parts[1].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, time.count >= 2 else { return nil }
        var offset = 0
        if parts.count >= 3 {
            let zone = parts[2].uppercased()
            if zone == "UTC" || zone == "GMT" || zone == "Z" {
                offset = 0
            } else if let sign = zone.first, sign == "+" || sign == "-" {
                let digits = zone.dropFirst().filter(\.isNumber)
                guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else {
                    return nil
                }
                offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            } else {
                return nil
            }
        }
        return utcDate(
            year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1],
            second: time.count > 2 ? time[2] : 0, offset: offset)
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int)
        -> Date?
    {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(TimeInterval(-offset))
    }
}
