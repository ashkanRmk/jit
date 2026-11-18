import Darwin
import Foundation

/// Copies data only. Git's editor command contains this helper's quoted path and a constant mode;
/// user messages never become shell source. The done todo is the durable message key, not a call counter.
enum RebaseEditor {
    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func run(mode: String, target: String) -> Int32 {
        var stage = "environment"
        do {
            guard let directory = ProcessInfo.processInfo.environment["JIT_REBASE_DIRECTORY"], directory.hasPrefix("/")
            else { throw CocoaError(.fileReadCorruptFile) }
            let directoryURL = URL(fileURLWithPath: directory)
            stage = "manifest"
            let manifest = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directoryURL.appendingPathComponent("manifest.json")))
            stage = "directory validation"
            guard let fields = manifest as? [String: Any], let gitDirectory = fields["gitDirectory"] as? String,
                canonical(directory) == canonical(gitDirectory + "/jit-interactive-rebase")
            else { throw CocoaError(.fileReadCorruptFile) }
            stage = "target validation"
            let targetURL = URL(fileURLWithPath: target)
            let allowed =
                mode == "sequence-editor"
                ? gitDirectory + "/rebase-merge/git-rebase-todo" : gitDirectory + "/COMMIT_EDITMSG"
            guard let actualTarget = canonical(targetURL.path), let expectedTarget = canonical(allowed),
                actualTarget == expectedTarget
            else {
                FileHandle.standardError.write(Data("jit-git-helper: unexpected editor target\n".utf8))
                return 1
            }
            let data: Data
            if mode == "sequence-editor" {
                stage = "todo"
                data = try Data(contentsOf: directoryURL.appendingPathComponent("todo"))
            } else {
                guard let messages = fields["messages"] as? [String: String] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let done = try String(contentsOfFile: gitDirectory + "/rebase-merge/done", encoding: .utf8)
                let commands = done.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
                guard let command = commands.last else { throw CocoaError(.fileReadCorruptFile) }
                let words = command.split(whereSeparator: \.isWhitespace)
                guard words.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
                let oid = String(words[1])
                // Git may abbreviate completed todo IDs. Never guess an ambiguous prefix.
                let messageKeys =
                    fields["messageKeys"] as? [String: String]
                    ?? Dictionary(uniqueKeysWithValues: messages.keys.map { ($0, $0) })
                let matches = messageKeys.keys.filter { $0.hasPrefix(oid) }
                guard matches.count == 1, let source = matches.first, let key = messageKeys[source],
                    let message = messages[key]
                else { throw CocoaError(.fileReadCorruptFile) }
                data = Data((message + "\n").utf8)
            }
            stage = "write"
            try data.write(to: targetURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("jit-git-helper: could not complete \(stage); preparation was kept\n".utf8))
            return 1
        }
    }
}
