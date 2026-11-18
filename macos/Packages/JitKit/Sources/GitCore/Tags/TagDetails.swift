import Foundation

public struct TagDetails: Sendable, Equatable {
    public let name: String
    public let objectOID: String
    public let targetOID: String
    public let targetType: String
    public let isAnnotated: Bool
    public let tagger: String?
    public let date: Date?
    public let message: String
    let repository: String

    public var deletionAction: DestructiveAction { .deleteTag(name: name, object: objectOID) }
}

extension RepositoryHandle {
    public func tagDetails(named name: String, object expectedObject: String? = nil) async throws(GitCoreError)
        -> TagDetails
    {
        try await requireValidTagRef(name)
        guard let object = try await Self.readTagObject(name, engine: gitEngine, in: workingDirectory) else {
            throw .refused(summary: "Tag “\(name)” no longer exists. Refresh the tags.")
        }
        if let expectedObject, object != expectedObject {
            throw .staleSnapshot(summary: "The tag changed. Refresh its details.")
        }
        let type = String(decoding: try await runRead(["cat-file", "-t", object], limit: 256), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let peeled = String(
            decoding: try await runRead(["rev-parse", "--verify", "--end-of-options", object + "^{}"], limit: 256),
            as: UTF8.self
        ).trimmingCharacters(in: .newlines)
        try Self.requireObjectID(peeled)
        let targetType = String(decoding: try await runRead(["cat-file", "-t", peeled], limit: 256), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        var tagger: String?
        var date: Date?
        var message = ""
        if type == "tag" {
            let raw = String(
                decoding: try await runRead(["cat-file", "tag", object], limit: 4 * 1024 * 1024), as: UTF8.self)
            guard let blank = raw.range(of: "\n\n") else {
                throw .refused(summary: "This tag object has no readable annotation.")
            }
            if let line = raw[..<blank.lowerBound].split(separator: "\n").first(where: { $0.hasPrefix("tagger ") }) {
                let fields = line.dropFirst(7).split(separator: " ")
                guard fields.count >= 3, let seconds = TimeInterval(fields[fields.count - 2]), seconds.isFinite else {
                    throw .refused(summary: "This tag has an unreadable tagger date.")
                }
                tagger = fields.dropLast(2).joined(separator: " ")
                date = Date(timeIntervalSince1970: seconds)
            }
            message = Self.annotationMessage(String(raw[blank.upperBound...]))
        }
        guard try await Self.readTagObject(name, engine: gitEngine, in: workingDirectory) == object else {
            throw .staleSnapshot(summary: "The tag changed while reading its details. Refresh it.")
        }
        return TagDetails(
            name: name, objectOID: object, targetOID: peeled, targetType: targetType,
            isAnnotated: type == "tag", tagger: tagger, date: date, message: message, repository: info.gitDirectory)
    }

    static func annotationMessage(_ text: String) -> String {
        var message = text
        for marker in [
            "-----BEGIN PGP SIGNATURE-----", "-----BEGIN SSH SIGNATURE-----", "-----BEGIN SIGNED MESSAGE-----",
        ] {
            if let range = message.range(of: marker) { message = String(message[..<range.lowerBound]) }
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readTagObject(_ name: String, engine: GitEngine, in directory: String) async throws(GitCoreError)
        -> String?
    {
        let ref = "refs/tags/" + name
        let symbolic = try await engine.run(
            GitCommand(["symbolic-ref", "-q", ref], in: directory, acceptedExitCodes: [0, 1]))
        guard symbolic.exitCode != 0 else {
            throw .refused(summary: "Symbolic tags cannot be managed here. Use Git directly.")
        }
        return try await readRef(engine: engine, in: directory, ref)
    }

    nonisolated func requireValidTagRef(_ name: String) async throws(GitCoreError) {
        try Self.requireSafeName(name, what: "tag")
        let output = try await gitEngine.run(
            GitCommand(
                ["check-ref-format", "refs/tags/\(name)"], in: workingDirectory, acceptedExitCodes: [0, 1, 128]))
        guard output.exitCode == 0 else { throw .refused(summary: "“\(name)” isn't a valid tag name.") }
    }

    @discardableResult
    public func deleteTag(_ tag: TagDetails, token: ConfirmationToken, expected: RepoStateToken?)
        async throws(GitCoreError) -> TagDetails
    {
        try token.verify(tag.deletionAction)
        guard tag.repository == info.gitDirectory else {
            throw .refused(summary: "This tag was prepared for another repository.")
        }
        try await requireValidTagRef(tag.name)
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        return try await performExclusive("Delete tag \(tag.name)", invalidating: [.refs]) {
            () throws(GitCoreError) -> TagDetails in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            guard try await Self.readTagObject(tag.name, engine: engine, in: directory) == tag.objectOID else {
                throw .staleSnapshot(summary: "The tag changed. Review it before deleting again.")
            }
            _ = try await Self.runClassified(
                GitCommand(
                    ["update-ref", "--no-deref", "-d", "refs/tags/\(tag.name)", tag.objectOID], in: directory,
                    kind: .write), engine: engine, gitDirectory: gitDirectory)
            return tag
        }
    }
}
