import Darwin
import Dispatch
import Foundation

/// A tiny local HTTP server for auth-failure tests: answers every request with a fixed status (401 with a
/// `WWW-Authenticate` challenge by default) and closes. Listens on 127.0.0.1 on a free port.
public final class HTTPStubServer: @unchecked Sendable {
    public let port: UInt16
    private let socket: Int32
    private let source: any DispatchSourceRead
    private let queue = DispatchQueue(label: "jit.tests.http-stub")

    public init(status: String = "401 Unauthorized") throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        socket = fd
        let response = Array(
            "HTTP/1.1 \(status)\r\nWWW-Authenticate: Basic realm=\"jit-tests\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .utf8)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            _ = read(client, &buffer, buffer.count)
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
        source.setCancelHandler { close(fd) }
        source.activate()
    }

    public var url: String { "http://127.0.0.1:\(port)/repo.git" }

    deinit { source.cancel() }
}
