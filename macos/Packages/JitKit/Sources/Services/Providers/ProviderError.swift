import Foundation

/// Failures of a hosting-provider API call (design §4.7, ADR-0037). Descriptions are plain language and never
/// contain tokens, `Authorization` values or response bodies beyond a short, token-scrubbed server message.
public enum ProviderError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// 401: the token was rejected (revoked, expired or wrong).
    case unauthorized
    /// 403 that is not a rate limit. `message` is the server's short explanation (scrubbed, truncated).
    case forbidden(String)
    case notFound
    /// GitHub 403/429 with `x-ratelimit-remaining: 0` or `retry-after`; GitLab 429. No automatic retry.
    case rateLimited(resetAt: Date?)
    /// Any other non-2xx status.
    case server(Int)
    /// The response wasn't what the API documents (not JSON, missing fields, foreign pagination link).
    case invalidResponse
    case transport(URLError)
    /// Self-managed GitLab: the API root returned 404 or HTML — the base URL's path prefix is probably wrong.
    case wrongPathPrefix
    /// The server's version is older than Jit supports (the associated value is the version text).
    case unsupportedVersion(String)

    /// Broad cause of a `.transport` failure, for diagnostics (design §3.7).
    public enum TransportFailure: Sendable, Equatable {
        case offline
        case dns
        case tls
        case timeout
        case proxy
        case unreachable
        case cancelled
        case other
    }

    public var transportFailure: TransportFailure? {
        guard case .transport(let error) = self else { return nil }
        return Self.classify(error)
    }

    static func classify(_ error: URLError) -> TransportFailure {
        // CFNetwork reports proxy failures through the stream error code (kCFErrorHTTPProxyConnectionFailure 310,
        // kCFErrorHTTPBadProxyCredentials 311, kCFErrorHTTPSProxyConnectionFailure 312, CONNECT failure 313).
        if let streamCode = error.userInfo["_kCFStreamErrorCodeKey"] as? Int, (310...313).contains(streamCode) {
            return .proxy
        }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
            .callIsActive:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .dns
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
            .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tls
        case .timedOut:
            return .timeout
        case .cannotConnectToHost:
            return .unreachable
        case .cancelled:
            return .cancelled
        default:
            return .other
        }
    }

    public var errorDescription: String? { description }
    public var debugDescription: String { "ProviderError: \(description)" }

    public var description: String {
        switch self {
        case .unauthorized:
            return "The server rejected the token. It may have expired or been revoked."
        case .forbidden(let message):
            let base = "The account doesn't have permission for this request."
            return message.isEmpty ? base : "\(base) The server said: \(message)"
        case .notFound:
            return "The server couldn't find what Jit asked for."
        case .rateLimited(let resetAt):
            guard let resetAt else { return "The server's rate limit was reached. Try again later." }
            let time = resetAt.formatted(date: .omitted, time: .shortened)
            return "The server's rate limit was reached. Try again after \(time)."
        case .server(let status):
            return "The server returned an unexpected error (HTTP \(status))."
        case .invalidResponse:
            return "The server's response wasn't in the expected format."
        case .transport(let error):
            switch Self.classify(error) {
            case .offline: return "You appear to be offline."
            case .dns: return "The server's name couldn't be found. Check the address, VPN or DNS settings."
            case .tls: return "A secure connection couldn't be established. The server's certificate wasn't trusted."
            case .timeout: return "The server didn't respond in time."
            case .proxy: return "The proxy refused or couldn't complete the connection."
            case .unreachable: return "Jit couldn't connect to the server."
            case .cancelled: return "The request was cancelled."
            case .other: return "A network error occurred (code \(error.code.rawValue))."
            }
        case .wrongPathPrefix:
            return "This doesn't look like a GitLab API. Check the server address, including any path prefix."
        case .unsupportedVersion(let version):
            return
                "GitLab \(version) is older than Jit supports (GitLab \(GitLabProvider.minimumSupportedGitLab) or later)."
        }
    }
}

/// Failures of an OAuth flow (ADR-0017). Plain language; never includes codes, tokens or verifiers.
public enum OAuthError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// No client ID is configured for this provider/instance — browser sign-in is unavailable.
    case notConfigured
    /// The user denied access or closed the browser window. Shown neutrally.
    case cancelled
    /// The device code or authorization expired before the user finished.
    case expired
    /// The callback didn't belong to the in-flight sign-in.
    case stateMismatch
    /// Refreshing the access token failed; the account should be marked expired.
    case refreshFailed
    /// The provider returned an OAuth error code (`invalid_grant`, `device_flow_disabled`, …).
    case provider(code: String)
    /// A network/HTTP failure underneath the flow.
    case request(ProviderError)
    case invalidResponse

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .notConfigured: return "Browser sign-in isn't configured for this server."
        case .cancelled: return "Sign-in was cancelled."
        case .expired: return "The sign-in request expired. Start again."
        case .stateMismatch: return "The sign-in response didn't match the request and was ignored."
        case .refreshFailed: return "The sign-in has expired. Sign in again."
        case .provider(let code):
            switch code {
            case "device_flow_disabled": return "Device sign-in isn't enabled for Jit's GitHub app."
            case "invalid_grant": return "The server rejected the sign-in grant. Sign in again."
            case "invalid_client", "incorrect_client_credentials", "unauthorized_client":
                return "The server doesn't recognize Jit's application ID."
            default: return "The server refused the sign-in (\(code))."
            }
        case .request(let error): return error.description
        case .invalidResponse: return "The server's sign-in response wasn't in the expected format."
        }
    }

    /// Keeps only `[a-z0-9_.-]` (max 64) so a server-chosen error code can't smuggle text into the UI.
    static func sanitizedCode(_ code: String) -> String {
        let allowed = code.lowercased().unicodeScalars.filter {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "." || $0 == "-"
        }
        let text = String(String.UnicodeScalarView(allowed.prefix(64)))
        return text.isEmpty ? "unknown_error" : text
    }
}
