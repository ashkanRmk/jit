import Foundation

public enum CommitSurgeryAction: String, Sendable, Hashable {
    case editMessage, drop
    public var title: String { self == .editMessage ? "Edit Message" : "Drop Commit" }
}

/// A direct action's immutable provenance and editable message. Only a repository read creates one.
public struct CommitSurgeryPlan: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let action: CommitSurgeryAction
    public let commit: CommitSummary
    public let author: String
    public let originalMessage: String
    public let expected: RepoStateToken
    public let publishedCount: Int
    fileprivate let gitDirectory: String
    private let replay: InteractiveRebasePlan?
    public var message: String

    public var usesAmend: Bool { replay == nil }
    public var affectedCount: Int { replay?.commits.count ?? 1 }
    public var descendantCount: Int { affectedCount - 1 }
    public var validationIssues: [String] {
        guard action == .editMessage else { return [] }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ["Enter a commit message."] }
        if message.utf8.contains(0) || message.utf8.count > 1024 * 1024 {
            return ["Commit messages must be at most 1 MB and cannot contain NUL bytes."]
        }
        return generatedRebase?.validationIssues ?? []
    }

    public var generatedRebase: InteractiveRebasePlan? {
        guard var replay, let index = replay.steps.firstIndex(where: { $0.oid == commit.oid }) else { return nil }
        replay.steps[index].action = action == .editMessage ? .reword : .drop
        if action == .editMessage { replay.steps[index].message = message }
        return replay
    }

    public func confirmation(context: String) -> ConfirmationRequest {
        let authorization =
            generatedRebase.map { DestructiveAction.interactiveRebase(planID: $0.id, steps: $0.steps) }
            ?? .editCommitMessage(planID: id, commit: commit.oid, message: message)
        let laterCommits = "\(descendantCount) later \(descendantCount == 1 ? "commit" : "commits")"
        let publishedCommits = "\(publishedCount) published \(publishedCount == 1 ? "commit" : "commits")"
        return ConfirmationRequest(
            action: authorization,
            title: action == .drop ? "Drop commit \(commit.shortOID)?" : "Edit message of \(commit.shortOID)?",
            context: context,
            changes: action == .drop
                ? "Remove this commit and its changes from \(expected.branch ?? "this branch"). Replay \(laterCommits). Other branch and tag pointers stay in place."
                : (usesAmend
                    ? "Replace this commit's message. Its tree, parents and author are preserved; the active profile becomes the committer. Other branch and tag pointers stay in place."
                    : "Replace this commit's message and rewrite \(laterCommits). Authors are preserved; the active profile becomes the committer. Other branch and tag pointers stay in place."),
            losses: publishedCount > 0
                ? ["This rewrites \(publishedCommits). A later push requires force-with-lease."] : [],
            recoverability:
                "Recover the previous branch tip through Repository → Reflog. Abort restores the branch if a replay stops.",
            recoveryValue: expected.head, verb: action == .drop ? "Drop Commit" : "Save Message")
    }

    fileprivate init(
        action: CommitSurgeryAction, oid: String, author: String, message: String, gitDirectory: String,
        expected: RepoStateToken, replay: InteractiveRebasePlan?, publishedCount: Int
    ) {
        self.gitDirectory = gitDirectory
        id = UUID(); self.action = action; self.author = author; self.message = message
        originalMessage = message; self.expected = expected; self.replay = replay; self.publishedCount = publishedCount
        commit = CommitSummary(oid: oid, subject: String(message.split(separator: "\n").first ?? ""))
    }
}

extension RepositoryHandle {
    public nonisolated func commitSurgeryPlan(for oid: String, action: CommitSurgeryAction)
        async throws(GitCoreError) -> CommitSurgeryPlan
    {
        _ = try requireWorkingTree()
        try Self.requireObjectID(oid)
        let expected = try await captureState()
        guard expected.operation == .none, expected.headRef != nil, let head = expected.head else {
            throw .refused(summary: "Editing history needs a checked-out branch and no operation in progress.")
        }
        try await Self.requireCleanTrackedTree(engine: gitEngine, in: workingDirectory)
        let replay: InteractiveRebasePlan?
        if action == .editMessage && oid == head {
            replay = nil
        } else {
            let parents = try await parents(of: oid)
            guard parents.count == 1, let parent = parents.first else {
                throw .refused(summary: "Choose a non-root, non-merge commit in a linear range of the current branch.")
            }
            let candidate = try await interactiveRebasePlan(after: parent.oid)
            guard candidate.expected == expected, candidate.commits.first?.oid == oid else {
                throw .refused(summary: "The selected commit must belong to the current branch's linear history.")
            }
            replay = candidate
        }
        let raw = try await runRead(["cat-file", "commit", oid], limit: 2 * 1024 * 1024)
        guard let separator = raw.indices.dropLast().first(where: { raw[$0] == 10 && raw[$0 + 1] == 10 }) else {
            throw .internalError(summary: "Couldn't read the selected commit message.")
        }
        guard let message = String(bytes: raw[(separator + 2)...], encoding: .utf8) else {
            throw .refused(summary: "This commit's message is not UTF-8. Edit it in Terminal.")
        }
        guard message.utf8.count <= 1024 * 1024, !message.utf8.contains(0) else {
            throw .refused(summary: "The selected commit's message exceeds 1 MB or contains NUL bytes.")
        }
        let identity = try await runRead(["show", "-s", "--format=%an <%ae>", oid, "--"], limit: 64 * 1024)
        let publishedCount: Int
        if let replay {
            publishedCount = replay.publishedCount
        } else {
            let unpublished = try await runRead(
                ["rev-list", "--max-count=1", oid, "--not", "--remotes", "--"], limit: 1024)
            publishedCount = unpublished.isEmpty ? 1 : 0
        }
        guard try await captureState() == expected else {
            throw .staleSnapshot(summary: "The repository changed while preparing this action. Try again.")
        }
        return CommitSurgeryPlan(
            action: action, oid: oid,
            author: String(decoding: identity, as: UTF8.self).trimmingCharacters(in: .newlines), message: message,
            gitDirectory: info.gitDirectory, expected: expected, replay: replay, publishedCount: publishedCount)
    }

    public func applyCommitSurgery(
        _ plan: CommitSurgeryPlan, token: ConfirmationToken, helperPath: String,
        context: ExecContext, progress: AsyncStream<OperationProgress>.Continuation? = nil
    )
        async throws(GitCoreError) -> IntegrationOutcome
    {
        guard plan.gitDirectory == info.gitDirectory else {
            throw .refused(summary: "This history action was prepared for another working tree. Try again here.")
        }
        guard plan.validationIssues.isEmpty else {
            throw .refused(summary: plan.validationIssues.joined(separator: "\n"))
        }
        if let replay = plan.generatedRebase {
            return try await executeInteractiveRebase(
                replay, token: token, helperPath: helperPath, context: context,
                operationName: plan.action.title, progress: progress)
        }
        try token.verify(.editCommitMessage(planID: plan.id, commit: plan.commit.oid, message: plan.message))
        let directory = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let identity = try context.requireIdentity()
        return try await performExclusive(plan.action.title, invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.ensureCurrent(plan.expected, engine: engine, in: directory, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.requireCleanTrackedTree(engine: engine, in: directory)
            var command = GitCommand(
                [
                    "-c", "commit.gpgSign=false", "commit", "--amend", "--only", "--allow-empty",
                    "--cleanup=verbatim", "-F", "-",
                ], in: directory, kind: .write, timeout: nil,
                stdin: Array(plan.message.utf8))
            command.environment = Self.identityEnvironment(
                CommitRequest(message: plan.message, amend: true, identity: identity))
            do throws(GitCoreError) { _ = try await engine.run(command) } catch {
                throw Self.mapWriteError(error, gitDirectory: gitDirectory)
            }
            return .committed(commit: try await Self.readHead(engine: engine, in: directory) ?? "")
        }
    }
}
