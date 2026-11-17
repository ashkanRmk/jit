import Foundation

extension RepositoryHandle {
    public nonisolated func validateTagName(_ name: String) async throws(GitCoreError) {
        try Self.requireSafeName(name, what: "tag")
        let output = try await gitEngine.run(
            GitCommand(
                ["check-ref-format", "refs/tags/\(name)"], in: workingDirectory, kind: .read,
                acceptedExitCodes: [0, 1, 128]))
        guard output.exitCode == 0 else { throw .refused(summary: "“\(name)” isn't a valid tag name.") }
        guard try await Self.readRef(engine: gitEngine, in: workingDirectory, "refs/tags/\(name)") == nil else {
            throw .refused(summary: "A tag named “\(name)” already exists.")
        }
    }

    public func createTag(
        _ name: String, at commit: String, message: String?, context: ExecContext,
        expected: RepoStateToken?
    ) async throws(GitCoreError) {
        try await validateTagName(name)
        try Self.requireObjectID(commit)
        let identity = try message.map { _ throws(GitCoreError) in try context.requireIdentity() }
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, info.gitDirectory)
        try await performExclusive("Create tag \(name)", invalidating: [.refs]) { () throws(GitCoreError) in
            try await Self.ensureCurrent(expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            var arguments = ["-c", "tag.gpgSign=false", "tag"]
            if message != nil { arguments += ["-a", "-F", "-"] }
            arguments += ["--", name, commit]
            _ = try await Self.runClassified(
                GitEnvironment.integrationCommand(
                    arguments, in: directory, identity: identity, use: .committerOnly,
                    stdin: message.map { Array($0.utf8) }), engine: engine, gitDirectory: gitDirectory)
        }
    }

    /// Push only this exact tag; never --tags or a branch-shaped refspec.
    public func pushTag(_ name: String, remote: String, context: ExecContext) async throws(GitCoreError) {
        try Self.requireSafeName(name, what: "tag")
        try Self.requireSafeName(remote, what: "remote")
        guard let info = try await remotes().first(where: { $0.name == remote }) else {
            throw .refused(summary: "There's no remote named “\(remote)”.")
        }
        let (engine, directory, gitDirectory) = (gitEngine, workingDirectory, self.info.gitDirectory)
        try await performExclusive("Push tag \(name)", invalidating: [.refs]) { () throws(GitCoreError) in
            let lease = try await context.prepareAccess(for: info.pushURLs, purpose: .push)
            defer { lease?.release() }
            _ = try await Self.runClassified(
                GitEnvironment.remoteCommand(
                    ["push", "--porcelain", remote, "refs/tags/\(name):refs/tags/\(name)"],
                    in: directory, context: context, access: lease?.access), engine: engine, gitDirectory: gitDirectory)
        }
    }

}
