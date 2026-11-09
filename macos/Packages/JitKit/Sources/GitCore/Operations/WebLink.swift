import Foundation

/// Remote URL → web URL for github.com and gitlab.com (design §4.12, ADR-0034). Never fetches anything;
/// unknown hosts map to `nil` (no menu item). Self-managed hosts arrive with Phase 5.
public enum WebLink {
    public enum Target: Sendable, Hashable {
        case commit(String)
        case branch(String)
    }

    public static func map(remoteURL: String, target: Target) -> URL? {
        guard let (host, path) = hostAndPath(remoteURL) else { return nil }
        var segments = path.split(separator: "/").map(String.init)
        guard var last = segments.last else { return nil }
        if last.hasSuffix(".git") { last.removeLast(4) }
        segments[segments.count - 1] = last
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let project = segments.map(encode).joined(separator: "/")
        switch host {
        case "github.com", "www.github.com":
            guard segments.count == 2 else { return nil }
            switch target {
            case .commit(let sha): return URL(string: "https://github.com/\(project)/commit/\(encode(sha))")
            case .branch(let name): return URL(string: "https://github.com/\(project)/tree/\(encodePath(name))")
            }
        case "gitlab.com", "www.gitlab.com":
            guard segments.count >= 2 else { return nil }
            switch target {
            case .commit(let sha): return URL(string: "https://gitlab.com/\(project)/-/commit/\(encode(sha))")
            case .branch(let name): return URL(string: "https://gitlab.com/\(project)/-/tree/\(encodePath(name))")
            }
        default:
            return nil
        }
    }

    /// Host (lowercased, no port, no user) and path of https, http, ssh:// and scp-like URLs.
    static func hostAndPath(_ raw: String) -> (String, String)? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = url.range(of: "://") {
            let scheme = url[..<range.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme) else { return nil }
            var rest = url[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = rest[..<slash]
            rest = rest[slash...]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            if let colon = authority.lastIndex(of: ":") { authority = authority[..<colon] }
            var path = String(rest)
            while path.hasSuffix("/") { path.removeLast() }
            return (authority.lowercased(), path)
        }
        // scp-like: [user@]host:path
        guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
        var host = url[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        var path = String(url[url.index(after: colon)...])
        while path.hasSuffix("/") { path.removeLast() }
        return (host.lowercased(), path)
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    /// Branch names keep `/` between segments; each segment is percent-encoded.
    static func encodePath(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }
}
