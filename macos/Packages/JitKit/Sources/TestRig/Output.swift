import Foundation
import Network

// Process-wide output helpers and shutdown registry for the dev-only rig (ADR-0039).

/// Prints `READY <port> <role>` to stdout and flushes; scripts and tests wait for this line.
func emitReady(port: UInt16, role: String) {
    FileHandle.standardOutput.write(Data("READY \(port) \(role)\n".utf8))
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("TestRig: \(message)\n".utf8))
}

/// Append-only request/tunnel log. Callers pass only method, path, status or host:port — never header values,
/// so credentials (Authorization, PRIVATE-TOKEN, Proxy-Authorization, SOCKS passwords) cannot reach the file.
final class RigLog: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "rig.log")

    init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw RigError.usage("cannot create log file \(path)")
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw RigError.usage("cannot open log file \(path)")
        }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    func write(_ line: String) {
        let stamp = Date().formatted(.iso8601)
        queue.async { [handle] in
            handle.write(Data("\(stamp) \(line)\n".utf8))
        }
    }
}

/// Tracks listeners and CGI children so SIGTERM/SIGINT can stop them before exiting.
final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ listener: NWListener) { lock.withLock { listeners.append(listener) } }
    func add(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
    func remove(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = nil } }

    func shutdown() {
        let (ls, ps) = lock.withLock { (listeners, Array(processes.values)) }
        for listener in ls { listener.cancel() }
        for process in ps where process.isRunning { process.terminate() }
    }
}

let registry = Registry()

enum RigError: Error, CustomStringConvertible {
    case usage(String)
    case setup(String)

    var description: String {
        switch self {
        case .usage(let message), .setup(let message): message
        }
    }
}
