import Foundation

/// Minimal `--name value` / `--flag` parser. Unknown options are errors so typos in scripts fail loudly.
struct Options {
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, valued: Set<String>, flags known: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { throw RigError.usage("unexpected argument '\(argument)'") }
            let name = String(argument.dropFirst(2))
            if known.contains(name) {
                flags.insert(name)
            } else if valued.contains(name) {
                guard let value = iterator.next() else { throw RigError.usage("--\(name) needs a value") }
                values[name, default: []].append(value)
            } else {
                throw RigError.usage("unknown option --\(name)")
            }
        }
    }

    func string(_ name: String) -> String? { values[name]?.last }
    func strings(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func int(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = string(name) else { return fallback }
        guard let value = Int(raw), range.contains(value) else {
            throw RigError.usage("--\(name) must be an integer in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }
}

struct RigUser: Sendable {
    let id: Int
    let name: String
    let token: String

    /// `username:token` per line; blank lines and `#` comments ignored.
    static func load(path: String) throws -> [RigUser] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var users: [RigUser] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                throw RigError.usage("users file line without ':' in \(path)")
            }
            let name = String(trimmed[..<colon])
            let token = String(trimmed[trimmed.index(after: colon)...])
            guard !name.isEmpty, !token.isEmpty else { throw RigError.usage("empty user or token in \(path)") }
            users.append(RigUser(id: users.count + 1, name: name, token: token))
        }
        guard !users.isEmpty else { throw RigError.usage("users file \(path) has no entries") }
        return users
    }
}

/// Decodes `Basic base64(user:secret)`.
func decodeBasic(_ header: String?) -> (user: String, secret: String)? {
    guard let header else { return nil }
    let parts = header.split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "basic",
        let data = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces)),
        let text = String(data: data, encoding: .utf8), let colon = text.firstIndex(of: ":")
    else { return nil }
    return (String(text[..<colon]), String(text[text.index(after: colon)...]))
}

/// The rig never talks to the internet: proxies only reach loopback unless `--allow-remote` is passed.
func isLoopbackHost(_ host: String) -> Bool {
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    return bare == "localhost" || bare == "::1" || bare == "0:0:0:0:0:0:0:1" || bare.hasPrefix("127.")
}
