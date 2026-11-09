import CFNetwork
import Foundation
import GitCore
import Synchronization

/// Resolves the proxy for a URL the way macOS would (design §4.10, ADR-0018): manual and direct modes map
/// directly; "System" reads `CFNetworkCopySystemProxySettings` and `CFNetworkCopyProxiesForURL` (exception lists
/// included) and runs a PAC script once per request when one is configured. Git doesn't read macOS proxy
/// settings, so the result becomes `-c http.<url>.proxy=…` for that invocation only.
public struct SystemProxyResolver: ProxyResolving {
    /// Injectable system settings (tests); `nil` reads the live settings.
    let settings: (@Sendable () -> [String: Any]?)?

    public init(settings: (@Sendable () -> [String: Any]?)? = nil) {
        self.settings = settings
    }

    public func resolve(_ url: RemoteURL, mode: ProxyMode, global: ProxyMode) async -> ResolvedProxy {
        let effective: ProxyMode = mode == .inheritGlobal ? global : mode
        switch effective {
        case .direct: return .direct
        case .manual(let proxy): return ResolvedProxy(proxy: proxy, source: .manual)
        case .inheritGlobal, .system: return await system(url)
        }
    }

    func system(_ url: RemoteURL) async -> ResolvedProxy {
        guard
            let target = URL(
                string: url.isSSH ? "https://\(url.host)/" : "\(url.scheme.rawValue)://\(url.host):\(url.port)/")
        else { return .direct }
        let system = settings?() ?? (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any])
        guard let system else { return .direct }
        let list =
            (CFNetworkCopyProxiesForURL(target as CFURL, system as CFDictionary).takeRetainedValue()
                as? [[String: Any]]) ?? []
        for entry in list {
            let type = entry[kCFProxyTypeKey as String] as? String
            if type == (kCFProxyTypeNone as String) {
                // macOS returns "none" both for exceptions and for no proxy; exceptions are listed in settings.
                let exceptions = (system[kCFNetworkProxiesExceptionsList as String] as? [String]) ?? []
                let excepted = exceptions.contains { Self.matches(host: url.host, pattern: $0) }
                return ResolvedProxy(proxy: nil, source: excepted ? .exception : .direct)
            }
            if type == (kCFProxyTypeAutoConfigurationURL as String),
                let script = entry[kCFProxyAutoConfigurationURLKey as String] as? URL
            {
                if let proxy = await Self.runPAC(script, for: target, sshFallback: url.isSSH) {
                    return ResolvedProxy(proxy: proxy, source: .pac)
                }
                continue
            }
            if let proxy = Self.manual(from: entry, ssh: url.isSSH) {
                return ResolvedProxy(proxy: proxy, source: .system)
            }
        }
        return .direct
    }

    static func manual(from entry: [String: Any], ssh: Bool) -> ManualProxy? {
        let type = entry[kCFProxyTypeKey as String] as? String
        guard let host = entry[kCFProxyHostNameKey as String] as? String,
            let port = (entry[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue
        else { return nil }
        let kind: ManualProxy.Kind
        // An HTTPS-tunnelling proxy is spoken to over HTTP (CONNECT).
        if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) {
            kind = .http
        } else if type == (kCFProxyTypeSOCKS as String) {
            kind = .socks5
        } else {
            return nil
        }
        let proxy = ManualProxy(
            id: ProxyConfigID(rawValue: "system-\(host):\(port)"), kind: kind, host: host, port: port)
        return proxy.isValid ? proxy : nil
    }

    /// `*.corp.example`, `.corp.example`, exact hosts and `*.local`.
    static func matches(host: String, pattern raw: String) -> Bool {
        let pattern = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if pattern == host { return true }
        if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
        if pattern.hasPrefix(".") { return host.hasSuffix(pattern) }
        return false
    }

    /// Runs a PAC script with CFNetwork on the main run loop (the app's; one execution per operation). The first
    /// usable PROXY/SOCKS entry wins; `DIRECT` → nil.
    static func runPAC(_ script: URL, for target: URL, sshFallback: Bool) async -> ManualProxy? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ManualProxy?, Never>) in
            final class Box: @unchecked Sendable {
                let continuation: CheckedContinuation<ManualProxy?, Never>
                let finished = Mutex(false)
                var source: CFRunLoopSource?
                init(_ continuation: CheckedContinuation<ManualProxy?, Never>) { self.continuation = continuation }
                func finish(_ value: ManualProxy?) {
                    let first = finished.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
                    continuation.resume(returning: value)
                }
            }
            let box = Box(continuation)
            DispatchQueue.main.async {
                var context = CFStreamClientContext(
                    version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil, release: nil,
                    copyDescription: nil)
                let source = CFNetworkExecuteProxyAutoConfigurationURL(
                    script as CFURL, target as CFURL,
                    { info, proxies, _ in
                        let box = Unmanaged<Box>.fromOpaque(info).takeRetainedValue()
                        let list = (proxies as? [[String: Any]]) ?? []
                        let proxy = list.lazy.compactMap { SystemProxyResolver.manual(from: $0, ssh: false) }.first
                        box.finish(proxy)
                    }, &context)
                box.source = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { box.finish(nil) }
            }
        }
    }
}

/// Builds the per-instance URLSession configuration (ephemeral, no cache/cookies) with proxy and trust policy
/// (design §4.7, §4.10).
public enum NetworkSessionFactory {
    public static func configuration(proxy: ResolvedProxy) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        switch proxy.source {
        case .system, .pac:
            if let manual = proxy.proxy { configuration.connectionProxyDictionary = dictionary(manual) }
        case .manual:
            if let manual = proxy.proxy { configuration.connectionProxyDictionary = dictionary(manual) }
        case .direct, .exception:
            configuration.connectionProxyDictionary = [:]
        }
        return configuration
    }

    static func dictionary(_ proxy: ManualProxy) -> [AnyHashable: Any] {
        switch proxy.kind {
        case .http, .https:
            return [
                kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: proxy.host,
                kCFNetworkProxiesHTTPPort: proxy.port,
                "HTTPSEnable": 1, "HTTPSProxy": proxy.host, "HTTPSPort": proxy.port,
            ]
        case .socks5:
            return ["SOCKSEnable": 1, "SOCKSProxy": proxy.host, "SOCKSPort": proxy.port]
        }
    }
}
