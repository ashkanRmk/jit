import Darwin
import Foundation

/// Runs `git http-backend` for one request. The request body streams into the child's stdin through
/// `DispatchIO` (with backpressure); stdout is collected and sent with a Content-Length once the child exits.
final class CGIRun: @unchecked Sendable {
    private let server: GitServer
    private let session: HTTPSession
    private let request: HTTPRequest
    private let body: BodyReader
    private let pathInfo: String
    private let remoteUser: String?
    private var queue: DispatchQueue { session.conn.queue }

    private var output = Data()
    private var stdinIO: DispatchIO?
    private var bodyFinished = false
    private var bodyReusable = true
    private let group = DispatchGroup()

    init(
        server: GitServer, session: HTTPSession, request: HTTPRequest, body: BodyReader, pathInfo: String,
        remoteUser: String?
    ) {
        self.server = server
        self.session = session
        self.request = request
        self.body = body
        self.pathInfo = pathInfo
        self.remoteUser = remoteUser
    }

    private var environment: [String: String] {
        let config = server.config
        var env: [String: String] = [
            "PATH": "\(config.gitExecPath):/usr/bin:/bin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/tmp",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.receivepack",
            "GIT_CONFIG_VALUE_0": "true",
            "GIT_PROJECT_ROOT": config.reposRoot,
            "GIT_HTTP_EXPORT_ALL": "1",
            "GATEWAY_INTERFACE": "CGI/1.1",
            "SERVER_PROTOCOL": "HTTP/1.1",
            "SERVER_SOFTWARE": "jit-test-rig",
            "REQUEST_METHOD": request.method,
            "PATH_INFO": pathInfo,
            "QUERY_STRING": request.query,
            "REMOTE_ADDR": "127.0.0.1",
        ]
        if let remoteUser {
            env["REMOTE_USER"] = remoteUser
            env["AUTH_TYPE"] = "Basic"
        }
        if let type = request.header("Content-Type") { env["CONTENT_TYPE"] = type }
        // Chunked bodies have no length: http-backend then reads stdin to EOF.
        if case .length(let length) = body.mode, length > 0 { env["CONTENT_LENGTH"] = String(length) }
        // gzip bodies pass through untouched; http-backend inflates them itself.
        if let encoding = request.header("Content-Encoding") { env["HTTP_CONTENT_ENCODING"] = encoding }
        if let protocolHeader = request.header("Git-Protocol") { env["HTTP_GIT_PROTOCOL"] = protocolHeader }
        return env
    }

    func start() {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return session.reply(.text(500, "pipe failed\n"), to: request, body: body)
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        let childIn = FileHandle(fileDescriptor: inPipe[0], closeOnDealloc: true)
        let childOut = FileHandle(fileDescriptor: outPipe[1], closeOnDealloc: true)
        let childErr = FileHandle(fileDescriptor: errPipe[1], closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server.config.gitExecPath + "/git-http-backend")
        process.environment = environment
        process.standardInput = childIn
        process.standardOutput = childOut
        process.standardError = childErr
        process.terminationHandler = { [self] process in
            registry.remove(process)
            queue.async { [self] in group.leave() }
        }
        group.enter()  // process exit
        group.enter()  // stdout EOF
        do {
            try process.run()
        } catch {
            for fd in [inPipe[1], outPipe[0], errPipe[0]] { Darwin.close(fd) }
            try? childIn.close()
            try? childOut.close()
            try? childErr.close()
            warn("cannot start git-http-backend: \(error)")
            return session.reply(.text(500, "cannot start git-http-backend\n"), to: request, body: body)
        }
        registry.add(process)
        try? childIn.close()
        try? childOut.close()
        try? childErr.close()

        let stdinFD = inPipe[1]
        let input = DispatchIO(type: .stream, fileDescriptor: stdinFD, queue: queue) { _ in Darwin.close(stdinFD) }
        stdinIO = input

        let stdoutFD = outPipe[0]
        let stdout = DispatchIO(type: .stream, fileDescriptor: stdoutFD, queue: queue) { _ in Darwin.close(stdoutFD) }
        stdout.setLimit(lowWater: 1)
        stdout.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
            if let data, !data.isEmpty { output.append(contentsOf: data) }
            if done {
                stdout.close()
                group.leave()
            }
        }

        let stderrFD = errPipe[0]
        let stderr = DispatchIO(type: .stream, fileDescriptor: stderrFD, queue: queue) { _ in Darwin.close(stderrFD) }
        stderr.setLimit(lowWater: 1)
        stderr.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty { FileHandle.standardError.write(Data(data)) }
            if done { stderr.close() }
        }

        pumpBody()
        group.notify(queue: queue) { [self] in finish() }
    }

    private func pumpBody() {
        body.next { [self] event in
            switch event {
            case .data(let data):
                guard let input = stdinIO else { return pumpBody() }  // child gone: keep draining
                let chunk = data.withUnsafeBytes { DispatchData(bytes: $0) }
                input.write(offset: 0, data: chunk, queue: queue) { [self] done, _, error in
                    if error != 0 {
                        stdinIO?.close(flags: .stop)
                        stdinIO = nil
                        pumpBody()
                    } else if done {
                        pumpBody()
                    }
                }
            case .end:
                bodyFinished = true
                stdinIO?.close()
                stdinIO = nil
            case .failed:
                bodyFinished = true
                bodyReusable = false
                stdinIO?.close(flags: .stop)
                stdinIO = nil
            }
        }
    }

    private func finish() {
        let reusable = bodyFinished && bodyReusable
        guard let response = Self.parseCGI(output) else {
            return session.respond(.text(502, "malformed CGI response\n"), to: request, reusable: reusable)
        }
        session.respond(response, to: request, reusable: reusable)
    }

    /// CGI output: header lines (CRLF or LF), blank line, body. `Status:` sets the HTTP status.
    static func parseCGI(_ output: Data) -> HTTPResponse? {
        let crlf = output.range(of: Data("\r\n\r\n".utf8))
        let lf = output.range(of: Data("\n\n".utf8))
        let separator: Range<Data.Index>
        switch (crlf, lf) {
        case (let a?, let b?): separator = a.lowerBound <= b.lowerBound ? a : b
        case (let a?, nil): separator = a
        case (nil, let b?): separator = b
        case (nil, nil): return nil
        }
        let headText = String(decoding: output[output.startIndex..<separator.lowerBound], as: UTF8.self)
        var status = 200
        var headers: [(String, String)] = []
        for rawLine in headText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "status": status = Int(value.prefix(3)) ?? 500
            case "content-length", "transfer-encoding", "connection": continue
            default: headers.append((name, value))
            }
        }
        return HTTPResponse(status: status, headers: headers, body: Data(output[separator.upperBound...]))
    }
}
