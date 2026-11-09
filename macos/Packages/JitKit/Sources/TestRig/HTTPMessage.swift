import Foundation

let headerTerminator = Data("\r\n\r\n".utf8)
let maxHeadBytes = 64 * 1024

struct HTTPRequest: Sendable {
    let method: String
    let target: String
    let version: String
    let headers: [(name: String, value: String)]

    static func parse(_ head: Data) -> HTTPRequest? {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers.append(
                (
                    String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                ))
        }
        return HTTPRequest(
            method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers)
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var path: String {
        if let mark = target.firstIndex(of: "?") { return String(target[..<mark]) }
        return target
    }

    var query: String {
        if let mark = target.firstIndex(of: "?") { return String(target[target.index(after: mark)...]) }
        return ""
    }

    var wantsKeepAlive: Bool {
        version == "HTTP/1.1" && header("Connection")?.lowercased().contains("close") != true
    }

    /// `nil` when the framing headers are malformed.
    var bodyMode: BodyReader.Mode? {
        if let encoding = header("Transfer-Encoding") {
            return encoding.lowercased().contains("chunked") ? .chunked : nil
        }
        guard let length = header("Content-Length") else { return .length(0) }
        guard let value = Int(length), value >= 0 else { return nil }
        return .length(value)
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    static func text(_ status: Int, _ text: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers, body: Data(text.utf8))
    }

    func head(keepAlive: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\n"
        text += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(text.utf8)
    }
}

func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 204: "No Content"
    case 304: "Not Modified"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 407: "Proxy Authentication Required"
    case 413: "Payload Too Large"
    case 500: "Internal Server Error"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    default: "Status"
    }
}

enum BodyEvent: Sendable {
    case data(Data)
    case end
    case failed
}

/// Streams a request body (Content-Length or chunked) off a connection.
final class BodyReader: @unchecked Sendable {
    enum Mode: Sendable {
        case length(Int)
        case chunked
    }

    let mode: Mode
    private let conn: RigConnection
    private var remaining: Int
    private var needsChunkCRLF = false
    private var done = false

    init(conn: RigConnection, mode: Mode) {
        self.conn = conn
        self.mode = mode
        if case .length(let length) = mode { remaining = length } else { remaining = 0 }
    }

    var isEmpty: Bool {
        if case .length(0) = mode { return true }
        return false
    }

    func next(_ completion: @escaping @Sendable (BodyEvent) -> Void) {
        if done {
            completion(.end)
            return
        }
        switch mode {
        case .length:
            if remaining == 0 {
                done = true
                completion(.end)
                return
            }
            conn.readSome(max: min(remaining, RigConnection.maxChunk)) { [self] data in
                guard let data else { return completion(.failed) }
                remaining -= data.count
                completion(.data(data))
            }
        case .chunked:
            nextChunked(completion)
        }
    }

    private func nextChunked(_ completion: @escaping @Sendable (BodyEvent) -> Void) {
        if remaining > 0 {
            conn.readSome(max: min(remaining, RigConnection.maxChunk)) { [self] data in
                guard let data else { return completion(.failed) }
                remaining -= data.count
                if remaining == 0 { needsChunkCRLF = true }
                completion(.data(data))
            }
            return
        }
        if needsChunkCRLF {
            conn.readLine { [self] line in
                guard let line, line.isEmpty else { return completion(.failed) }
                needsChunkCRLF = false
                nextChunked(completion)
            }
            return
        }
        conn.readLine { [self] line in
            guard let line else { return completion(.failed) }
            let sizeText = String(decoding: line, as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return completion(.failed)
            }
            if size == 0 {
                skipTrailers(completion)
            } else {
                remaining = size
                nextChunked(completion)
            }
        }
    }

    private func skipTrailers(_ completion: @escaping @Sendable (BodyEvent) -> Void) {
        conn.readLine { [self] line in
            guard let line else { return completion(.failed) }
            if line.isEmpty {
                done = true
                completion(.end)
            } else {
                skipTrailers(completion)
            }
        }
    }

    /// Reads and discards the rest of the body; `true` when the connection can be reused.
    func drain(_ completion: @escaping @Sendable (Bool) -> Void) {
        next { [self] event in
            switch event {
            case .data: drain(completion)
            case .end: completion(true)
            case .failed: completion(false)
            }
        }
    }
}
