import Foundation
import Network

struct GitServerConfig: Sendable {
    var port = 0
    var reposRoot = ""
    var users: [RigUser]?
    var anyUsername = false
    var deniedUsers: Set<String> = []
    var pathPrefix = ""
    var throttleBytesPerSecond = 0
    var sshBase: String?
    var gitExecPath = ""
    var isTLS = false
    var log: RigLog?

    static let usage = """
        TestRig git-server --repos <dir> [options]
          --port <n>               listen port on 127.0.0.1 (default 0 = pick a free port)
          --repos <dir>            GIT_PROJECT_ROOT for git http-backend (served under /git/)
          --p12 <file>             serve TLS with this PKCS#12 identity (imported in memory only)
          --p12-password <pw>      PKCS#12 password (or env JIT_RIG_P12_PASSWORD)
          --users <file>           require Basic auth on /git/ and tokens on /api/v4 (lines 'username:token')
          --any-username           accept any username with a valid token (GitLab PAT behaviour)
          --deny-user <name>       authenticated but forbidden (403); repeatable
          --path-prefix </prefix>  mount everything under the prefix (404 elsewhere)
          --throttle-kbps <n>      limit response bodies to n KiB/s
          --ssh-base <url>         ssh URL base for the real 'project' in the API stub
          --git <path>             git binary used to find git-http-backend (default: git on PATH)
          --log <file>             request log (method, path, status; never credentials)
        """
}

final class GitServer: @unchecked Sendable {
    let config: GitServerConfig
    let api: GitLabAPI

    init(config: GitServerConfig) {
        self.config = config
        self.api = GitLabAPI(users: config.users ?? [], denied: config.deniedUsers, sshBase: config.sshBase)
    }

    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try Options(
            arguments,
            valued: [
                "port", "repos", "p12", "p12-password", "users", "deny-user", "path-prefix", "throttle-kbps",
                "ssh-base", "git", "log",
            ],
            flags: ["any-username"])
        var config = GitServerConfig()
        config.port = try options.int("port", default: 0, range: 0...65535)
        guard let repos = options.string("repos") else { throw RigError.usage("--repos is required") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repos, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RigError.usage("--repos \(repos) is not a directory")
        }
        config.reposRoot = URL(fileURLWithPath: repos).standardizedFileURL.path
        if let users = options.string("users") { config.users = try RigUser.load(path: users) }
        config.anyUsername = options.has("any-username")
        config.deniedUsers = Set(options.strings("deny-user"))
        if let prefix = options.string("path-prefix") {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            config.pathPrefix = trimmed.isEmpty ? "" : "/" + trimmed
        }
        config.throttleBytesPerSecond = try options.int("throttle-kbps", default: 0, range: 0...1_000_000) * 1024
        config.sshBase = options.string("ssh-base")
        config.gitExecPath = try gitExecPath(git: options.string("git"))
        if let log = options.string("log") { config.log = try RigLog(path: log) }

        var identity: sec_identity_t?
        if let p12 = options.string("p12") {
            guard
                let password = options.string("p12-password")
                    ?? ProcessInfo.processInfo.environment["JIT_RIG_P12_PASSWORD"]
            else { throw RigError.usage("--p12 needs --p12-password or JIT_RIG_P12_PASSWORD") }
            identity = try loadIdentity(p12Path: p12, password: password)
            config.isTLS = true
        }

        let server = GitServer(config: config)
        try startListener(
            parameters: tcpParameters(identity: identity), port: config.port,
            role: config.isTLS ? "https" : "http", label: "rig.http"
        ) { conn in
            HTTPSession(server: server, conn: conn).next()
        }
    }

    // MARK: Routing

    func handle(_ request: HTTPRequest, body: BodyReader, session: HTTPSession) {
        var path = request.path
        if !config.pathPrefix.isEmpty {
            guard path == config.pathPrefix || path.hasPrefix(config.pathPrefix + "/") else {
                return session.reply(.text(404, "Not Found\n"), to: request, body: body)
            }
            path = String(path.dropFirst(config.pathPrefix.count))
            if path.isEmpty { path = "/" }
        }
        if path.hasPrefix("/git/") {
            git(request, pathInfo: String(path.dropFirst("/git".count)), body: body, session: session)
        } else if path == "/api/v4" || path.hasPrefix("/api/v4/") {
            let scheme = config.isTLS ? "https" : "http"
            let host = request.header("Host") ?? "127.0.0.1"
            let response = api.handle(
                request, route: String(path.dropFirst("/api/v4".count)),
                baseURL: "\(scheme)://\(host)\(config.pathPrefix)")
            session.reply(response, to: request, body: body)
        } else {
            session.reply(.text(404, "Not Found\n"), to: request, body: body)
        }
    }

    private func git(_ request: HTTPRequest, pathInfo raw: String, body: BodyReader, session: HTTPSession) {
        guard let pathInfo = raw.removingPercentEncoding,
            !pathInfo.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else { return session.reply(.text(400, "Bad Request\n"), to: request, body: body) }

        var remoteUser: String?
        if let users = config.users {
            let challenge = [("WWW-Authenticate", "Basic realm=\"rig\"")]
            guard let credentials = decodeBasic(request.header("Authorization")),
                let user = users.first(where: {
                    $0.token == credentials.secret && (config.anyUsername || $0.name == credentials.user)
                })
            else { return session.reply(.text(401, "Unauthorized\n", headers: challenge), to: request, body: body) }
            if config.deniedUsers.contains(user.name) || config.deniedUsers.contains(credentials.user) {
                return session.reply(.text(403, "Forbidden\n"), to: request, body: body)
            }
            remoteUser = user.name
        }
        CGIRun(
            server: self, session: session, request: request, body: body, pathInfo: pathInfo, remoteUser: remoteUser
        ).start()
    }

    private static func gitExecPath(git: String?) throws -> String {
        let process = Process()
        if let git {
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["--exec-path"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "--exec-path"]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0,
            FileManager.default.isExecutableFile(atPath: path + "/git-http-backend")
        else { throw RigError.setup("git-http-backend not found (git --exec-path gave '\(path)')") }
        return path
    }
}

/// One client connection: reads requests in a keep-alive loop.
final class HTTPSession: @unchecked Sendable {
    let server: GitServer
    let conn: RigConnection

    init(server: GitServer, conn: RigConnection) {
        self.server = server
        self.conn = conn
    }

    func next() {
        conn.read(until: headerTerminator, max: maxHeadBytes) { [self] head in
            guard let head else { return conn.close() }
            guard let request = HTTPRequest.parse(head), let mode = request.bodyMode else {
                return respond(.text(400, "Bad Request\n"), to: nil, reusable: false)
            }
            server.handle(request, body: BodyReader(conn: conn, mode: mode), session: self)
        }
    }

    /// Discards any unread request body, then responds.
    func reply(_ response: HTTPResponse, to request: HTTPRequest, body: BodyReader) {
        body.drain { [self] reusable in respond(response, to: request, reusable: reusable) }
    }

    func respond(_ response: HTTPResponse, to request: HTTPRequest?, reusable: Bool) {
        let keepAlive = reusable && (request?.wantsKeepAlive ?? false)
        if let request {
            server.config.log?.write("\(request.method) \(request.path) \(response.status)")
        }
        conn.send(response.head(keepAlive: keepAlive)) { [self] error in
            guard error == nil else { return conn.close() }
            sendBody(response.body, from: 0) { [self] in
                if keepAlive { next() } else { conn.close() }
            }
        }
    }

    /// Without throttling the body goes in one write; with throttling, in 100 ms slices.
    private func sendBody(_ body: Data, from offset: Int, done: @escaping @Sendable () -> Void) {
        guard offset < body.count else { return done() }
        let rate = server.config.throttleBytesPerSecond
        let end = rate > 0 ? min(body.count, offset + max(1, rate / 10)) : body.count
        conn.send(body.subdata(in: offset..<end)) { [self] error in
            guard error == nil else { return conn.close() }
            if rate > 0 && end < body.count {
                conn.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                    sendBody(body, from: end, done: done)
                }
            } else {
                sendBody(body, from: end, done: done)
            }
        }
    }
}
