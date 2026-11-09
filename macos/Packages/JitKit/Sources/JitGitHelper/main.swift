// jit-git-helper — the one helper binary Jit gives Git (ADR-0016, ADR-0036). Modes:
//   credential get|store|erase   Git credential helper: asks Jit's operation-scoped broker for one credential.
//   (JIT_HELPER_MODE=askpass)    SSH_ASKPASS: answers a key-passphrase prompt through the broker; refuses others.
//   (JIT_HELPER_MODE=ssh)        GIT_SSH_COMMAND target: execs /usr/bin/ssh with an argv array (no shell) and the
//                                options from JIT_SSH_* (key, known_hosts files, strict config, proxy).
// It holds no secrets at rest, logs nothing, and exits after one request.
import Darwin
import Foundation

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment

if arguments.count >= 2 && arguments[1] == "credential" {
    exit(HelperMain.credential(action: arguments.count >= 3 ? arguments[2] : ""))
}
switch environment["JIT_HELPER_MODE"] {
case "askpass":
    exit(HelperMain.askpass(prompt: arguments.count >= 2 ? arguments[1] : ""))
case "ssh":
    HelperMain.execSSH(gitArguments: Array(arguments.dropFirst()))
default:
    FileHandle.standardError.write(Data("jit-git-helper: no mode\n".utf8))
    exit(2)
}

enum HelperMain {
    static let maxMessage = 64 * 1024

    // MARK: credential

    static func credential(action: String) -> Int32 {
        guard ["get", "store", "erase"].contains(action) else { return 0 }
        var fields: [(String, String)] = []
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            // Only routing fields go to the broker; Git's `password` (on store/erase) is never forwarded.
            if ["protocol", "host", "username", "path"].contains(key) {
                fields.append((key, String(line[line.index(after: equals)...])))
            }
        }
        var request = [("mode", "credential"), ("action", action)]
        request += fields
        guard let response = Broker.exchange(request) else { return action == "get" ? 1 : 0 }
        guard action == "get", response.status == "ok", let username = response.values["username"],
            let password = response.secret
        else { return 0 }
        var output = Array("username=\(username)\npassword=".utf8)
        output += password
        output += Array("\n".utf8)
        output.withUnsafeBytes { buffer in writeAll(STDOUT_FILENO, buffer) }
        wipe(&output)
        return 0
    }

    // MARK: askpass

    static func askpass(prompt: String) -> Int32 {
        let lower = prompt.lowercased()
        // Host-key confirmations and passwords are never answered (ssh options also disable them).
        if lower.contains("yes/no") || lower.contains("fingerprint") || lower.contains("password") {
            return 1
        }
        guard let response = Broker.exchange([("mode", "askpass"), ("prompt", prompt)]), response.status == "ok",
            var secret = response.secret
        else { return 1 }
        secret += Array("\n".utf8)
        secret.withUnsafeBytes { buffer in writeAll(STDOUT_FILENO, buffer) }
        wipe(&secret)
        return 0
    }

    // MARK: ssh

    static func execSSH(gitArguments: [String]) -> Never {
        var argv = ["/usr/bin/ssh"]
        if environment["JIT_SSH_STRICT"] != "0" { argv += ["-F", "none"] }
        let useAgent = environment["JIT_SSH_AGENT"] == "1"
        if let key = environment["JIT_SSH_KEY"], !key.isEmpty {
            argv += ["-o", "IdentitiesOnly=yes", "-i", key]
            if !useAgent { argv += ["-o", "IdentityAgent=none"] }
        } else {
            // Agent-only: no default ~/.ssh/id_* files.
            argv += ["-o", "IdentityFile=none"]
        }
        let knownHosts = (environment["JIT_SSH_KNOWN_HOSTS"] ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.contains("\"") }
        if !knownHosts.isEmpty {
            argv += ["-o", "UserKnownHostsFile=" + knownHosts.map { "\"\($0)\"" }.joined(separator: " ")]
        }
        argv += [
            "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "BatchMode=no",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "ConnectTimeout=30",
        ]
        if let proxy = environment["JIT_SSH_PROXY"] {
            let parts = proxy.split(separator: " ")
            if parts.count == 2, ["socks5", "connect"].contains(parts[0]), isHostPort(String(parts[1])) {
                let mode = parts[0] == "socks5" ? "5" : "connect"
                argv += ["-o", "ProxyCommand=/usr/bin/nc -X \(mode) -x \(parts[1]) %h %p"]
            }
        }
        argv += gitArguments
        // Passphrase prompts come back to this binary in askpass mode — set here because Git's own environment
        // keeps SSH_ASKPASS disabled (ProcessEnvironment.nonInteractive); without a broker, ssh can't prompt.
        if environment["JIT_BROKER_SOCKET"] != nil, let selfPath = Bundle.main.executablePath {
            setenv("SSH_ASKPASS", selfPath, 1)
            setenv("SSH_ASKPASS_REQUIRE", "force", 1)
        }
        setenv("JIT_HELPER_MODE", "askpass", 1)
        unsetenv("JIT_SSH_KEY")
        let cArguments = argv.map { strdup($0) } + [nil]
        execv("/usr/bin/ssh", cArguments)
        FileHandle.standardError.write(Data("jit-git-helper: could not start ssh\n".utf8))
        exit(127)
    }

    static func isHostPort(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
            (1...65_535).contains(port)
        else { return false }
        let host = value[..<colon]
        return !host.isEmpty && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy {
                $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".")
            }
    }

    // MARK: helpers

    static func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < buffer.count, let base = buffer.baseAddress {
            let written = write(descriptor, base + offset, buffer.count - offset)
            if written < 0 && errno == EINTR { continue }
            if written <= 0 { return }
            offset += written
        }
    }

    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
        }
        bytes.removeAll()
    }
}

/// One request/response over the broker socket. Message: `key=value` lines, blank line terminator; the first
/// line is the nonce. The response's secret is raw bytes after a `secret-length=<n>` header, never parsed as text.
enum Broker {
    struct Response {
        var status: String
        var values: [String: String]
        var secret: [UInt8]?
    }

    static func exchange(_ fields: [(String, String)]) -> Response? {
        guard let path = environment["JIT_BROKER_SOCKET"], let nonce = environment["JIT_BROKER_NONCE"],
            !path.isEmpty, !nonce.isEmpty
        else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var message = "nonce=\(nonce)\n"
        for (key, value) in fields where !value.contains("\n") && !key.contains("=") {
            message += "\(key)=\(value)\n"
        }
        message += "\n"
        Array(message.utf8).withUnsafeBytes { HelperMain.writeAll(descriptor, $0) }
        shutdown(descriptor, SHUT_WR)
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while received.count < HelperMain.maxMessage {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            received += chunk[0..<count]
        }
        chunk.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { memset_s(base, buffer.count, 0, buffer.count) }
        }
        defer { HelperMain.wipe(&received) }
        return parse(received)
    }

    /// Header lines until `secret-length=<n>\n` (then exactly n raw bytes) or a blank line.
    static func parse(_ bytes: [UInt8]) -> Response? {
        var values: [String: String] = [:]
        var index = 0
        while index < bytes.count {
            guard let newline = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let line = String(decoding: bytes[index..<newline], as: UTF8.self)
            index = newline + 1
            if line.isEmpty { break }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if key == "secret-length" {
                guard let length = Int(value), length >= 0, index + length <= bytes.count else { return nil }
                let secret = Array(bytes[index..<(index + length)])
                return Response(status: values["status"] ?? "", values: values, secret: secret)
            }
            values[key] = value
        }
        return Response(status: values["status"] ?? "", values: values, secret: nil)
    }
}
