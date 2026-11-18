import Foundation

public struct RemoteTagDeletionPreview: Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let remote: String
    public let objectOID: String
    public let localObjectOID: String?
    public var maskedDestination: String { RemoteInfo.masked(destination).url }
    let destination: String
    let state: RepoStateToken
    let repository: String

    public var confirmationAction: DestructiveAction {
        .deleteRemoteTag(previewID: id, remote: remote, name: name, object: objectOID)
    }
}

extension RepositoryHandle {
    public func pushTag(
        _ name: String, remote: String, object: String? = nil, expected: RepoStateToken? = nil,
        context: ExecContext
    ) async throws(GitCoreError) {
        try await requireValidTagRef(name)
        if let object { try Self.requireObjectID(object) }
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Push tag \(name)", invalidating: [.refs]) { () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            guard let current = try await Self.readTagObject(name, engine: engine, in: directory) else {
                throw .refused(summary: "The local tag no longer exists.")
            }
            guard object == nil || object == current else {
                throw .staleSnapshot(summary: "The tag changed. Review it before pushing.")
            }
            let destination = try await self.tagPushDestination(remote)
            let access = try await context.prepareAccess(for: [destination], purpose: .push)
            defer { access?.release() }
            try await Self.runTagPush(
                ["--", destination, "\(current):refs/tags/\(name)"], engine: engine,
                directory: directory, gitDirectory: gitDirectory, context: context, access: access?.access)
        }
    }

    public func remoteTagDeletionPreview(named name: String, remote: String, context: ExecContext)
        async throws(GitCoreError) -> RemoteTagDeletionPreview
    {
        try await requireValidTagRef(name)
        let state = try await captureState()
        let destination = try await tagPushDestination(remote)
        let lease = try await context.prepareAccess(for: [destination], purpose: .lsRemote)
        defer { lease?.release() }
        let oid = try await Self.readRemoteTagObject(
            name, destination: destination, engine: gitEngine,
            directory: workingDirectory, context: context, access: lease?.access)
        guard try await captureState() == state, try await tagPushDestination(remote) == destination else {
            throw .staleSnapshot(summary: "The repository or remote changed. Refresh the remote tag preview.")
        }
        let local = try await Self.readTagObject(name, engine: gitEngine, in: workingDirectory)
        guard try await captureState() == state else {
            throw .staleSnapshot(summary: "The local tag changed. Refresh the preview.")
        }
        return RemoteTagDeletionPreview(
            name: name, remote: remote, objectOID: oid, localObjectOID: local, destination: destination,
            state: state, repository: info.gitDirectory)
    }

    public func deleteRemoteTag(_ preview: RemoteTagDeletionPreview, token: ConfirmationToken, context: ExecContext)
        async throws(GitCoreError)
    {
        try token.verify(preview.confirmationAction)
        guard preview.repository == info.gitDirectory else {
            throw .refused(summary: "This tag preview belongs to another repository.")
        }
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Delete tag \(preview.name) from \(preview.remote)", invalidating: [.refs]) {
            () throws(GitCoreError) in
            try await Self.ensureCurrent(preview.state, engine: engine, in: directory, gitDirectory: gitDirectory)
            guard try await self.tagPushDestination(preview.remote) == preview.destination else {
                throw .staleSnapshot(summary: "The push destination changed. Review it before deleting the tag.")
            }
            let lease = try await context.prepareAccess(for: [preview.destination], purpose: .push)
            defer { lease?.release() }
            let actual = try await Self.readRemoteTagObject(
                preview.name, destination: preview.destination,
                engine: engine, directory: directory, context: context, access: lease?.access)
            guard actual == preview.objectOID else {
                throw .staleSnapshot(
                    summary: "The remote tag changed after the preview. It was not deleted. Refresh the preview.")
            }
            try await Self.runTagPush(
                [
                    "--force-with-lease=refs/tags/\(preview.name):\(preview.objectOID)", "--", preview.destination,
                    ":refs/tags/\(preview.name)",
                ], engine: engine, directory: directory, gitDirectory: gitDirectory, context: context,
                access: lease?.access)
        }
    }

    private static func readRemoteTagObject(
        _ name: String, destination: String, engine: GitEngine,
        directory: String, context: ExecContext, access: RemoteAccess?
    ) async throws(GitCoreError) -> String {
        let output = try await engine.run(
            GitEnvironment.remoteCommand(
                ["ls-remote", "--refs", "--symref", "--", destination, "refs/tags/\(name)"], in: directory,
                context: context, access: access, stdoutLimit: 1024 * 1024))
        var oid: String?
        for line in output.stdout.split(separator: 0x0A) {
            let fields = line.split(separator: 0x09)
            guard fields.count == 2, String(decoding: fields[1], as: UTF8.self) == "refs/tags/" + name else { continue }
            let value = String(decoding: fields[0], as: UTF8.self)
            guard !value.hasPrefix("ref:") else {
                throw .refused(summary: "Symbolic remote tags cannot be deleted here.")
            }
            try Self.requireObjectID(value)
            guard oid == nil else { throw .refused(summary: "The remote returned ambiguous tag information.") }
            oid = value
        }
        guard let oid else { throw .refused(summary: "Tag “\(name)” does not exist at this push destination.") }
        return oid
    }

    /// Resolve the actual single push URL. Avoid a second Git URL rewrite of that prepared endpoint.
    func tagPushDestination(_ remote: String) async throws(GitCoreError) -> String {
        try Self.requireSafeName(remote, what: "remote")
        let output = try await runRead(["remote", "get-url", "--push", "--all", "--", remote], limit: 1024 * 1024)
        let urls = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(
            String.init)
        guard urls.count == 1, let raw = urls.first, !raw.contains("\r"), !raw.contains("\0") else {
            throw .refused(
                summary:
                    "Tag management needs one explicit push destination. Configure a remote with a single push URL.")
        }
        guard !RemoteInfo.masked(raw).hadCredentials else {
            throw .refused(
                summary:
                    "Remove embedded credentials from the remote URL and use a profile before managing remote tags.")
        }
        let endpoint: String
        if raw.contains(":") || raw.hasPrefix("/") {
            endpoint = raw
        } else {
            endpoint = URL(fileURLWithPath: workingDirectory).appendingPathComponent(raw).standardizedFileURL.path
        }
        let rules = try await gitEngine.run(
            GitCommand(
                ["config", "-z", "--get-regexp", #"^url\..*\.(insteadof|pushinsteadof)$"#], in: workingDirectory,
                acceptedExitCodes: [0, 1]))
        for record in rules.stdout.split(separator: 0) {
            guard let newline = record.firstIndex(of: 0x0A) else { continue }
            let prefix = String(decoding: record[record.index(after: newline)...], as: UTF8.self)
            if endpoint.hasPrefix(prefix) {
                throw .refused(
                    summary:
                        "A URL rewrite would reroute the prepared push destination. Use an explicit push URL without a matching rewrite."
                )
            }
        }
        return endpoint
    }

    private static func runTagPush(
        _ tail: [String], engine: GitEngine, directory: String, gitDirectory: String,
        context: ExecContext, access: RemoteAccess?
    ) async throws(GitCoreError) {
        let output = try await runClassified(
            GitEnvironment.remoteCommand(
                ["push", "--porcelain", "--no-follow-tags", "--no-mirror", "--recurse-submodules=no"] + tail,
                in: directory, context: context, access: access, acceptedExitCodes: [0, 1]), engine: engine,
            gitDirectory: gitDirectory)
        let results = PushPorcelainParser.parse(output.stdoutText)
        if let rejection = PushPorcelainParser.rejection(results) {
            if rejection == .staleLease {
                throw .staleSnapshot(
                    summary: "The remote tag changed after the preview. It was not deleted. Refresh the preview.")
            }
            let reason =
                results.first { [.rejected, .remoteRejected, .failed].contains($0.status) }?.reason
                ?? "remote refused the update"
            throw .refused(
                summary:
                    "Tag operation rejected: \(Redaction.redact(reason)). Review the remote tag and its policies before trying again."
            )
        }
        guard output.exitCode == 0, !results.isEmpty, PushPorcelainParser.rejection(results) == nil else {
            throw .failed(
                GitErrorClassifier.classify(
                    exitCode: output.exitCode == 0 ? 1 : output.exitCode,
                    stderr: output.stderrText + "\n" + output.stdoutText))
        }
    }
}
