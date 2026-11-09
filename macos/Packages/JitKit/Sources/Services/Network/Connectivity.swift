import Foundation
import Network
import Observation
import Synchronization

/// The network path as Jit last saw it (ADR-0038). Event-driven: `NWPathMonitor` calls back on changes only.
public enum PathStatus: String, Sendable, Hashable {
    case unknown
    case satisfied
    case unsatisfied
    case requiresConnection

    public var isOffline: Bool { self == .unsatisfied }
}

public struct PathSnapshot: Sendable, Hashable {
    public var status: PathStatus
    public var isConstrained: Bool
    public var isExpensive: Bool
    /// A VPN-like interface (utun/ipsec/ppp) is part of the path — best effort.
    public var vpnInterface: Bool

    public init(status: PathStatus, isConstrained: Bool = false, isExpensive: Bool = false, vpnInterface: Bool = false)
    {
        self.status = status
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
        self.vpnInterface = vpnInterface
    }
}

/// Seam for tests: inject path changes without the network.
public protocol PathMonitoring: Sendable {
    func start(_ handler: @escaping @Sendable (PathSnapshot) -> Void)
    func cancel()
}

public final class SystemPathMonitor: PathMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jit.path-monitor")

    public init() {}

    public func start(_ handler: @escaping @Sendable (PathSnapshot) -> Void) {
        monitor.pathUpdateHandler = { path in
            let status: PathStatus
            switch path.status {
            case .satisfied: status = .satisfied
            case .unsatisfied: status = .unsatisfied
            case .requiresConnection: status = .requiresConnection
            @unknown default: status = .unknown
            }
            let vpn = path.availableInterfaces.contains { interface in
                let name = interface.name
                return name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            }
            handler(
                PathSnapshot(
                    status: status, isConstrained: path.isConstrained, isExpensive: path.isExpensive,
                    vpnInterface: vpn))
        }
        monitor.start(queue: queue)
    }

    public func cancel() { monitor.cancel() }
}

/// App-wide connectivity (design §4.10 VPN/offline). Remote operations and provider requests fail immediately
/// while offline; nothing retries automatically. After an offline failure, the path coming back sets
/// `backOnline` so the UI can show a passive "Back online — Retry" affordance.
@MainActor @Observable
public final class ConnectivityState {
    public private(set) var path = PathSnapshot(status: .unknown)
    /// Set when the path became satisfied after an operation failed offline; cleared by `acknowledge()`.
    public private(set) var backOnline = false
    @ObservationIgnored private var failedWhileOffline = false
    @ObservationIgnored private let monitor: any PathMonitoring
    @ObservationIgnored private var started = false
    @ObservationIgnored let latest = LatestPath()

    public init(monitor: any PathMonitoring = SystemPathMonitor()) {
        self.monitor = monitor
    }

    /// Started when the app becomes active (no work before a window exists).
    public func start() {
        guard !started else { return }
        started = true
        let latest = latest
        monitor.start { [weak self] snapshot in
            latest.value.withLock { $0 = snapshot }
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    func apply(_ snapshot: PathSnapshot) {
        let wasOffline = path.status.isOffline
        path = snapshot
        if wasOffline, !snapshot.status.isOffline, failedWhileOffline {
            backOnline = true
            failedWhileOffline = false
        }
    }

    public func noteOfflineFailure() { failedWhileOffline = true }

    public func acknowledge() { backOnline = false }

    /// Thread-safe checker for `ProfileAccessProvider` and provider clients.
    public nonisolated var checker: any ConnectivityChecking { latest }
}

final class LatestPath: ConnectivityChecking {
    let value = Mutex<PathSnapshot?>(nil)
    func isOffline() async -> Bool { value.withLock { $0?.status.isOffline ?? false } }
}

/// Plain-language hints for network failures (VPN, DNS, timeouts).
public enum NetworkHints {
    /// Single-label names, private suffixes and RFC 1918 results suggest a company network.
    public static func looksInternal(host: String) -> Bool {
        let lower = host.lowercased()
        if !lower.contains(".") { return true }
        for suffix in [".corp", ".internal", ".local", ".lan", ".intranet", ".home.arpa", ".private"]
        where lower.hasSuffix(suffix) {
            return true
        }
        return isPrivateIPv4(lower)
    }

    public static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    public static func vpnHint(host: String) -> String? {
        looksInternal(host: host)
            ? "If this server is on your company network, connect your VPN and try again." : nil
    }
}
