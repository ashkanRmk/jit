import Foundation

extension RepositoryHandle {
    public nonisolated func validateTagName(_ name: String) async throws(GitCoreError) {
        try await requireValidTagRef(name)
        guard try await Self.readRef(engine: gitEngine, in: workingDirectory, "refs/tags/\(name)") == nil else {
            throw .refused(summary: "A tag named “\(name)” already exists.")
        }
    }

    @discardableResult
    public func createTag(
        _ name: String, at commit: String, message: String?, context: ExecContext,
        expected: RepoStateToken?
    ) async throws(GitCoreError) -> String {
        try await validateTagName(name)
        try Self.requireObjectID(commit)
        if let message {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0"),
                message.utf8.count <= 1024 * 1024
            else {
                throw .refused(summary: "Enter a nonempty tag message of at most 1 MiB without NUL characters.")
            }
        }
        let resolved = try await runRead(
            ["rev-parse", "--verify", "--end-of-options", commit + "^{commit}"], limit: 256)
        let target = String(decoding: resolved, as: UTF8.self).trimmingCharacters(in: .newlines)
        try Self.requireObjectID(target)
        let identity = try message.map { _ throws(GitCoreError) in try context.requireIdentity() }
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        return try await performExclusive("Create tag \(name)", invalidating: [.refs]) {
            () throws(GitCoreError) -> String in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            var arguments = ["-c", "tag.gpgSign=false", "tag"]
            let file = try message.map { text throws(GitCoreError) in try Self.writeTagMessage(text) }
            defer { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
            if let file { arguments += ["-a", "--cleanup=verbatim", "-F", file.path] }
            arguments += ["--", name, target]
            _ = try await Self.runClassified(
                GitEnvironment.integrationCommand(
                    arguments, in: directory, identity: identity, use: .committerOnly), engine: engine,
                gitDirectory: gitDirectory)
            guard let object = try await Self.readTagObject(name, engine: engine, in: directory) else {
                throw .staleSnapshot(summary: "The created tag disappeared before its object could be recorded.")
            }
            return object
        }
    }

    static func writeTagMessage(_ message: String) throws(GitCoreError) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jit-tag-message-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("message")
            guard
                FileManager.default.createFile(
                    atPath: file.path, contents: Data(message.utf8), attributes: [.posixPermissions: 0o600])
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw .io(summary: "Couldn't write the private tag message file.")
        }
    }
}
