import Foundation

/// A parsed Git remote URL (https, http, ssh://, git://, file and scp-like `user@host:path`). Used to resolve
/// which credentials and network policy apply (Phase 5 design §4.2). The user part is kept only to detect
/// embedded credentials, never to use them.
public struct RemoteURL: Sendable, Hashable {
    public enum Scheme: String, Sendable, Hashable {
        case https
        case http
        case ssh
        case git
        case file
    }

    public var scheme: Scheme
    /// Lowercased; empty for `file`.
    public var host: String
    /// Explicit or the scheme's default (443, 80, 22, 9418; 0 for file).
    public var port: Int
    public var path: String
    public var user: String?
    /// `https://user:secret@host` — the URL itself carries a password (masked everywhere, never used by Jit).
    public var hasEmbeddedPassword: Bool

    public var isSSH: Bool { scheme == .ssh }
    public var isHTTP: Bool { scheme == .https || scheme == .http }

    public static func parse(_ raw: String) -> RemoteURL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") {
            let schemeText = text[..<range.lowerBound].lowercased()
            let scheme: Scheme
            switch schemeText {
            case "https": scheme = .https
            case "http": scheme = .http
            case "ssh", "git+ssh", "ssh+git": scheme = .ssh
            case "git": scheme = .git
            case "file": scheme = .file
            default: return nil
            }
            let rest = text[range.upperBound...]
            if scheme == .file {
                return RemoteURL(
                    scheme: .file, host: "", port: 0, path: String(rest), user: nil, hasEmbeddedPassword: false)
            }
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[..<slash]
            let path = String(rest[slash...])
            var user: String?
            var password = false
            if let at = authority.lastIndex(of: "@") {
                let userInfo = authority[..<at]
                password = userInfo.contains(":")
                user = String(userInfo.split(separator: ":", maxSplits: 1).first ?? "")
                authority = authority[authority.index(after: at)...]
            }
            var host = String(authority)
            var port: Int?
            if host.hasPrefix("[") {
                // IPv6 literal: [::1]:8443
                guard let close = host.firstIndex(of: "]") else { return nil }
                let after = host[host.index(after: close)...]
                if after.hasPrefix(":") { port = Int(after.dropFirst()) }
                host = String(host[host.index(after: host.startIndex)..<close])
            } else if let colon = host.lastIndex(of: ":") {
                guard let value = Int(host[host.index(after: colon)...]) else { return nil }
                port = value
                host = String(host[..<colon])
            }
            guard !host.isEmpty else { return nil }
            let defaultPort: Int
            switch scheme {
            case .https: defaultPort = 443
            case .http: defaultPort = 80
            case .ssh: defaultPort = 22
            case .git: defaultPort = 9418
            case .file: defaultPort = 0
            }
            return RemoteURL(
                scheme: scheme, host: host.lowercased(), port: port ?? defaultPort, path: path,
                user: user?.isEmpty == true ? nil : user, hasEmbeddedPassword: password)
        }
        // scp-like: [user@]host:path (no slash before the colon; a leading "/" or "./" is a local path).
        guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/"), colon != text.startIndex else {
            return text.hasPrefix("/") || text.hasPrefix(".")
                ? RemoteURL(scheme: .file, host: "", port: 0, path: text, user: nil, hasEmbeddedPassword: false)
                : nil
        }
        var host = text[..<colon]
        var user: String?
        if let at = host.lastIndex(of: "@") {
            user = String(host[..<at])
            host = host[host.index(after: at)...]
        }
        guard !host.isEmpty else { return nil }
        return RemoteURL(
            scheme: .ssh, host: host.lowercased(), port: 22, path: String(text[text.index(after: colon)...]),
            user: user, hasEmbeddedPassword: false)
    }

    /// The URL with any user info removed (`https://host/path`) — what Jit shows and logs.
    public static func masked(_ raw: String) -> String {
        guard let range = raw.range(of: "://") else { return raw }
        let rest = raw[range.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[..<slash]
        guard let at = authority.lastIndex(of: "@") else { return raw }
        return String(raw[..<range.upperBound]) + "•••@" + authority[authority.index(after: at)...] + rest[slash...]
    }
}
