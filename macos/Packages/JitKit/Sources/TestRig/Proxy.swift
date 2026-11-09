import Foundation
import Network

struct ProxyConfig: Sendable {
    var port = 0
    var socksPort: Int?
    var credentials: (user: String, password: String)?
    var allowRemote = false
    var log: RigLog?

    static let usage = """
        TestRig proxy [options]
          --port <n>          HTTP proxy (CONNECT + absolute-URI forwarding) on 127.0.0.1 (default 0 = free port)
          --socks-port <n>    also run a SOCKS5 proxy (CONNECT only; 0 = free port)
          --auth <user:pw>    require Proxy-Authorization: Basic / SOCKS5 username+password (RFC 1929)
          --allow-remote      allow non-loopback targets (default: loopback only, the rig never needs internet)
          --log <file>        log each tunnel target host:port and result (never credentials)
        """

    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try Options(arguments, valued: ["port", "socks-port", "auth", "log"], flags: ["allow-remote"])
        var config = ProxyConfig()
        config.port = try options.int("port", default: 0, range: 0...65535)
        if options.string("socks-port") != nil {
            config.socksPort = try options.int("socks-port", default: 0, range: 0...65535)
        }
        if let auth = options.string("auth") {
            guard let colon = auth.firstIndex(of: ":") else { throw RigError.usage("--auth must be user:password") }
            config.credentials = (String(auth[..<colon]), String(auth[auth.index(after: colon)...]))
        }
        config.allowRemote = options.has("allow-remote")
        if let log = options.string("log") { config.log = try RigLog(path: log) }

        let frozen = config
        try startListener(
            parameters: tcpParameters(identity: nil), port: config.port, role: "http-proxy", label: "rig.proxy"
        ) { conn in
            HTTPProxySession(config: frozen, conn: conn).start()
        }
        if let socksPort = config.socksPort {
            try startListener(
                parameters: tcpParameters(identity: nil), port: socksPort, role: "socks5", label: "rig.socks"
            ) { conn in
                SOCKS5Session(config: frozen, conn: conn).start()
            }
        }
    }

    func allows(_ host: String) -> Bool { allowRemote || isLoopbackHost(host) }
}

/// Splits `host:port` / `[v6]:port`.
func splitHostPort(_ text: String, defaultPort: UInt16?) -> (host: String, port: UInt16)? {
    if text.hasPrefix("[") {
        guard let close = text.firstIndex(of: "]") else { return nil }
        let host = String(text[text.index(after: text.startIndex)..<close])
        let rest = text[text.index(after: close)...]
        if rest.isEmpty, let defaultPort { return (host, defaultPort) }
        guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
        return (host, port)
    }
    if let colon = text.lastIndex(of: ":") {
        guard let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        return (String(text[..<colon]), port)
    }
    guard let defaultPort, !text.isEmpty else { return nil }
    return (text, defaultPort)
}

final class HTTPProxySession: @unchecked Sendable {
    private let config: ProxyConfig
    private let conn: RigConnection

    init(config: ProxyConfig, conn: RigConnection) {
        self.config = config
        self.conn = conn
    }

    func start() {
        conn.read(until: headerTerminator, max: maxHeadBytes) { [self] head in
            guard let head else { return conn.close() }
            guard let request = HTTPRequest.parse(head) else { return fail(400, "-") }
            if let credentials = config.credentials {
                guard let given = decodeBasic(request.header("Proxy-Authorization")),
                    given.user == credentials.user, given.secret == credentials.password
                else {
                    return fail(
                        407, request.method == "CONNECT" ? request.target : "-",
                        headers: [("Proxy-Authenticate", "Basic realm=\"rig-proxy\"")])
                }
            }
            if request.method == "CONNECT" { connect(request) } else { forward(request) }
        }
    }

    private func fail(_ status: Int, _ target: String, headers: [(String, String)] = []) {
        config.log?.write("HTTP-PROXY \(target) \(status)")
        conn.send(HTTPResponse.text(status, "\(reasonPhrase(status))\n", headers: headers).head(keepAlive: false)) {
            [self] _ in
            conn.send(Data("\(reasonPhrase(status))\n".utf8)) { [self] _ in conn.close() }
        }
    }

    private func connect(_ request: HTTPRequest) {
        guard let (host, port) = splitHostPort(request.target, defaultPort: nil) else {
            return fail(400, request.target)
        }
        let target = "\(host):\(port)"
        guard config.allows(host) else { return fail(403, target) }
        conn.connectUpstream(
            host: host, port: port,
            ready: { [self] upstream in
                config.log?.write("CONNECT \(target) 200")
                conn.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) { [self] error in
                    guard error == nil else {
                        upstream.close()
                        return conn.close()
                    }
                    Tunnel(conn, upstream).start()
                }
            },
            failed: { [self] _ in fail(502, target) })
    }

    /// Absolute-URI request (`GET http://host:port/path`): rewritten to origin form with `Connection: close`,
    /// then the rest of the exchange is spliced.
    private func forward(_ request: HTTPRequest) {
        guard let url = URLComponents(string: request.target), url.scheme?.lowercased() == "http",
            let host = url.host, !host.isEmpty
        else { return fail(400, "-") }
        let port = UInt16(url.port ?? 80)
        let target = "\(host):\(port)"
        guard config.allows(host) else { return fail(403, target) }
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { path += "?\(query)" }
        let dropped: Set<String> = ["proxy-authorization", "proxy-connection", "connection", "keep-alive"]
        var head = "\(request.method) \(path) \(request.version)\r\n"
        for (name, value) in request.headers where !dropped.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        let headData = Data(head.utf8)
        conn.connectUpstream(
            host: host, port: port,
            ready: { [self] upstream in
                config.log?.write("HTTP \(target) forwarded")
                upstream.send(headData) { [self] error in
                    guard error == nil else {
                        upstream.close()
                        return conn.close()
                    }
                    Tunnel(conn, upstream).start()
                }
            },
            failed: { [self] _ in fail(502, target) })
    }
}

/// SOCKS5 (RFC 1928) CONNECT with no-auth or username/password (RFC 1929).
final class SOCKS5Session: @unchecked Sendable {
    private let config: ProxyConfig
    private let conn: RigConnection

    init(config: ProxyConfig, conn: RigConnection) {
        self.config = config
        self.conn = conn
    }

    func start() {
        conn.read(exactly: 2) { [self] greeting in
            guard let greeting, greeting[greeting.startIndex] == 5 else { return conn.close() }
            conn.read(exactly: Int(greeting[greeting.startIndex + 1])) { [self] methods in
                guard let methods else { return conn.close() }
                let wanted: UInt8 = config.credentials == nil ? 0x00 : 0x02
                guard methods.contains(wanted) else {
                    config.log?.write("SOCKS5 - no-acceptable-auth")
                    return conn.send(Data([5, 0xFF])) { [self] _ in conn.close() }
                }
                conn.send(Data([5, wanted])) { [self] error in
                    guard error == nil else { return conn.close() }
                    if wanted == 0x02 { authenticate() } else { readRequest() }
                }
            }
        }
    }

    private func authenticate() {
        conn.read(exactly: 2) { [self] header in
            guard let header, header[header.startIndex] == 1 else { return conn.close() }
            conn.read(exactly: Int(header[header.startIndex + 1])) { [self] user in
                guard let user else { return conn.close() }
                conn.read(exactly: 1) { [self] length in
                    guard let length else { return conn.close() }
                    conn.read(exactly: Int(length[length.startIndex])) { [self] password in
                        guard let password, let credentials = config.credentials else { return conn.close() }
                        let ok =
                            user == Data(credentials.user.utf8) && password == Data(credentials.password.utf8)
                        conn.send(Data([1, ok ? 0 : 1])) { [self] error in
                            guard ok, error == nil else {
                                config.log?.write("SOCKS5 - auth-failed")
                                return conn.close()
                            }
                            readRequest()
                        }
                    }
                }
            }
        }
    }

    private func readRequest() {
        conn.read(exactly: 4) { [self] header in
            guard let header else { return conn.close() }
            let bytes = [UInt8](header)
            guard bytes[0] == 5 else { return conn.close() }
            guard bytes[1] == 1 else { return reply(0x07) }  // command not supported
            switch bytes[3] {
            case 1:
                conn.read(exactly: 4) { [self] address in
                    guard let address else { return conn.close() }
                    readPort(host: address.map(String.init).joined(separator: "."))
                }
            case 3:
                conn.read(exactly: 1) { [self] length in
                    guard let length else { return conn.close() }
                    conn.read(exactly: Int(length[length.startIndex])) { [self] name in
                        guard let name else { return conn.close() }
                        readPort(host: String(decoding: name, as: UTF8.self))
                    }
                }
            case 4:
                conn.read(exactly: 16) { [self] address in
                    guard let address else { return conn.close() }
                    let host = stride(from: 0, to: 16, by: 2).map { offset in
                        String(
                            UInt16(address[address.startIndex + offset]) << 8
                                | UInt16(address[address.startIndex + offset + 1]), radix: 16)
                    }.joined(separator: ":")
                    readPort(host: host)
                }
            default:
                reply(0x08)  // address type not supported
            }
        }
    }

    private func readPort(host: String) {
        conn.read(exactly: 2) { [self] raw in
            guard let raw else { return conn.close() }
            let bytes = [UInt8](raw)
            let port = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            guard config.allows(host) else {
                config.log?.write("SOCKS5 \(target) not-allowed")
                return reply(0x02)
            }
            conn.connectUpstream(
                host: host, port: port,
                ready: { [self] upstream in
                    config.log?.write("SOCKS5 \(target) connected")
                    conn.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])) { [self] error in
                        guard error == nil else {
                            upstream.close()
                            return conn.close()
                        }
                        Tunnel(conn, upstream).start()
                    }
                },
                failed: { [self] _ in
                    config.log?.write("SOCKS5 \(target) refused")
                    reply(0x05)
                })
        }
    }

    private func reply(_ code: UInt8) {
        conn.send(Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0])) { [self] _ in conn.close() }
    }
}
