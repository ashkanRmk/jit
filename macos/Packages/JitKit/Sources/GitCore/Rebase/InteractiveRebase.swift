import Foundation

/// Private, per-worktree state survives conflicts and relaunch. No executable text is stored here.
struct RebasePreparation: Codable, Sendable {
    let gitDirectory: String
    let head: String
    let headRef: String
    let onto: String
    let identity: IdentitySnapshot
    let messages: [String: String]
    let messageKeys: [String: String]

    static func directory(_ gitDirectory: String) -> String { gitDirectory + "/jit-interactive-rebase" }

    static func environment(helperPath: String, gitDirectory: String) throws(GitCoreError) -> [String: String] {
        guard helperPath.hasPrefix("/"), !helperPath.utf8.contains(0),
            FileManager.default.isExecutableFile(atPath: helperPath)
        else {
            throw .refused(
                summary:
                    "Jit's Git helper is unavailable. Reinstall Jit or finish this rebase in Terminal; Abort is still available."
            )
        }
        return [
            "GIT_SEQUENCE_EDITOR": GitEnvironment.shellQuote(helperPath) + " sequence-editor",
            "GIT_EDITOR": GitEnvironment.shellQuote(helperPath) + " message-editor",
            "JIT_REBASE_DIRECTORY": directory(gitDirectory),
        ]
    }

    static func load(gitDirectory: String) throws(GitCoreError) -> RebasePreparation? {
        let directory = directory(gitDirectory)
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        do {
            let preparation = try JSONDecoder().decode(
                Self.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/manifest.json")))
            func read(_ name: String) throws -> String {
                try String(contentsOfFile: gitDirectory + "/rebase-merge/" + name, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard preparation.gitDirectory == gitDirectory,
                preparation.head == (try read("orig-head")), preparation.headRef == (try read("head-name")),
                preparation.onto == (try read("onto"))
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return preparation
        } catch {
            throw .refused(
                summary:
                    "The prepared rebase data is missing or does not match this operation. Finish in Terminal or Abort; prepared messages were kept."
            )
        }
    }

    static func cleanUpIfFinished(gitDirectory: String) {
        if case .rebasing = OperationStateDetector.detect(gitDirectory: gitDirectory) { return }
        try? FileManager.default.removeItem(atPath: directory(gitDirectory))
    }
}

extension RepositoryHandle {
    public func startInteractiveRebase(
        _ plan: InteractiveRebasePlan, token: ConfirmationToken, helperPath: String, context: ExecContext,
        progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> IntegrationOutcome {
        try await executeInteractiveRebase(
            plan, token: token, helperPath: helperPath, context: context,
            operationName: "Interactive rebase", progress: progress)
    }

    /// Direct history actions reuse replay while retaining their own recovery-journal label.
    func executeInteractiveRebase(
        _ plan: InteractiveRebasePlan, token: ConfirmationToken, helperPath: String, context: ExecContext,
        operationName: String, progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> IntegrationOutcome {
        try token.verify(.interactiveRebase(planID: plan.id, steps: plan.steps))
        guard plan.validationIssues.isEmpty else {
            throw .refused(summary: plan.validationIssues.joined(separator: "\n"))
        }
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let identity = try context.requireIdentity()
        let environment = try RebasePreparation.environment(helperPath: helperPath, gitDirectory: gitDirectory)
        return try await performExclusive(operationName, invalidating: Set(InvalidationKind.allCases)) {
            () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.ensureCurrent(plan.expected, engine: engine, in: topLevel, gitDirectory: gitDirectory)
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.requireCleanTrackedTree(engine: engine, in: topLevel)
            guard plan.expected.operation == .none, let head = plan.expected.head, let headRef = plan.expected.headRef
            else {
                throw .refused(summary: "Finish the current operation and check out a branch first.")
            }
            let directory = RebasePreparation.directory(gitDirectory)
            defer { RebasePreparation.cleanUpIfFinished(gitDirectory: gitDirectory) }
            var messages: [String: String] = [:]
            var messageKeys: [String: String] = [:]
            var combinedKey: String?
            for step in plan.steps where step.action != .drop {
                switch step.action {
                case .reword, .squash:
                    messages[step.oid] = step.message
                    combinedKey = step.oid
                case .fixup: break
                default:
                    messages[step.oid] = plan.commits.first { $0.oid == step.oid }?.message
                    combinedKey = step.oid
                }
                messageKeys[step.oid] = combinedKey
            }
            let preparation = RebasePreparation(
                gitDirectory: gitDirectory, head: head, headRef: headRef,
                onto: plan.onto, identity: identity, messages: messages, messageKeys: messageKeys)
            do {
                // Stale data from an already finished/externally aborted rebase is safe to replace.
                if FileManager.default.fileExists(atPath: directory) {
                    try FileManager.default.removeItem(atPath: directory)
                }
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                func write(_ data: Data, named name: String) throws {
                    let path = directory + "/" + name
                    guard
                        FileManager.default.createFile(
                            atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
                    else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try write(JSONEncoder().encode(preparation), named: "manifest.json")
                // No subjects/messages in the todo: only validated actions and original full object IDs.
                let todo = plan.steps.map { "\($0.action.rawValue) \($0.oid)\n" }.joined()
                try write(Data(todo.utf8), named: "todo")
            } catch {
                throw .internalError(summary: "Couldn't save the private rebase preparation. Nothing was rewritten.")
            }
            return try await Self.runIntegration(
                [
                    "-c", "commit.gpgSign=false", "-c", "commit.cleanup=verbatim", "-c",
                    "rebase.abbreviateCommands=false",
                    "-c", "rebase.autoSquash=false", "-c", "rebase.rescheduleFailedExec=false", "-c",
                    "core.commentChar=#",
                    "rebase", "--interactive", "--force-rebase", "--no-autostash", "--no-autosquash",
                    "--no-update-refs",
                    "--keep-empty", "--empty=ask", "--no-rebase-merges", "--no-fork-point", "--onto", plan.onto,
                    plan.base,
                ],
                identity: identity, use: .committerOnly, engine: engine, topLevel: topLevel,
                gitDirectory: gitDirectory, headBefore: head, ahead: plan.resultCount, isRebase: true,
                environment: environment, progress: progress)
        }
    }

    /// An edit stop has no conflicts and Git records an amend target. Read on existing repo events only.
    public nonisolated func rebaseIsStoppedForEdit() async throws(GitCoreError) -> Bool {
        guard case .rebasing = OperationStateDetector.detect(gitDirectory: info.gitDirectory),
            FileManager.default.fileExists(atPath: info.gitDirectory + "/rebase-merge/amend")
        else { return false }
        return try await unmergedPaths().isEmpty
    }
}
