import Foundation
import GitCore

/// Phase 4 operations (design §4.2): each one is recorded in `operations`, runs through the repository's
/// `RepositoryHandle` (the single writer), and refreshes exactly what it may have changed. Identity is the
/// `ExecContext` captured by the caller when the user confirmed (profile snapshot at enqueue).
extension RepositorySession {
    /// The repository handle for read-only helpers (plans, previews, state tokens).
    public var repository: RepositoryHandle? { handle }

    /// The current state token (taken when a sheet is prepared; validated when it runs).
    public func captureState() async -> RepoStateToken? {
        try? await handle?.captureState()
    }

    // MARK: Generic runner

    @discardableResult
    func perform<T: Sendable>(
        _ title: String, cancellation: OperationCancellation = .notCancellable,
        refresh: Set<InvalidationKind> = Set(InvalidationKind.allCases),
        summarize: @escaping @Sendable (T) -> OperationSummary,
        _ body:
            @escaping @Sendable (RepositoryHandle, AsyncStream<OperationProgress>.Continuation)
            async throws(GitCoreError) -> T
    ) async -> Result<T, PresentableError> {
        guard let handle, lifecycle != .closed else {
            return .failure(PresentableError.make(.cancelled))
        }
        let result = await operations.run(title, cancellation: cancellation, summarize: summarize) {
            progress throws(GitCoreError) in
            try await body(handle, progress)
        }
        afterOperation(refresh)
        return result
    }

    func afterOperation(_ refresh: Set<InvalidationKind>) {
        scheduleRefresh(refresh, reason: .user)
        if !refresh.isDisjoint(with: [.refs, .head]) { history?.refsMayHaveChanged() }
        refreshOperationState()
        if refresh.contains(.refs) { refreshStashesIfLoaded() }
    }

    // MARK: State

    /// Re-reads the operation state for the banner (file reads + `ls-files -u`, off the main actor).
    public func refreshOperationState() {
        guard let handle else { return }
        operationStateTask?.cancel()
        operationStateTask = Task {
            guard let state = try? await handle.operationState(), !Task.isCancelled else { return }
            if state != self.operationState { self.operationState = state }
        }
    }

    /// Loads the stash list (first use) or refreshes it.
    public func loadStashes() {
        guard let handle else { return }
        stashTask?.cancel()
        stashTask = Task {
            guard let list = try? await handle.stashes(), !Task.isCancelled else { return }
            if list != self.stashes { self.stashes = list }
        }
    }

    func refreshStashesIfLoaded() {
        if stashes != nil { loadStashes() }
    }

    // MARK: Remote

    public func fetch(_ request: FetchRequest) async -> Result<FetchOutcome, PresentableError> {
        let title = request.remote.map { "Fetch \($0)" } ?? "Fetch all remotes"
        return await perform(title, cancellation: .cancellable, refresh: [.refs], summarize: OutcomeText.describe) {
            handle, progress throws(GitCoreError) in
            try await handle.fetch(request, progress: progress)
        }
    }

    public func pull(_ mode: PullMode, context: ExecContext) async -> Result<PullOutcome, PresentableError> {
        let title: String
        switch mode {
        case .fastForwardOnly: title = "Pull (fast-forward only)"
        case .merge: title = "Pull with merge"
        case .rebase: title = "Pull with rebase"
        }
        return await perform(title, cancellation: .cancellable, summarize: OutcomeText.describe) {
            handle, progress throws(GitCoreError) in
            try await handle.pull(mode, context: context, progress: progress)
        }
    }

    public func push(_ request: PushRequest) async -> Result<PushOutcome, PresentableError> {
        await perform(
            "Push \(request.localBranch) to \(request.remote)", cancellation: .cancellableWithWarning,
            refresh: [.refs, .config], summarize: OutcomeText.describe
        ) { handle, progress throws(GitCoreError) in
            try await handle.push(request, progress: progress)
        }
    }

    public func forcePushWithLease(_ request: PushRequest, expected: String, token: ConfirmationToken) async
        -> Result<PushOutcome, PresentableError>
    {
        await perform(
            "Force push \(request.localBranch) with lease", cancellation: .cancellableWithWarning, refresh: [.refs],
            summarize: OutcomeText.describe
        ) { handle, progress throws(GitCoreError) in
            try await handle.forcePushWithLease(request, expected: expected, token: token, progress: progress)
        }
    }

    // MARK: Branches

    public func createBranch(_ name: String, at start: String, switchTo: Bool, expected: RepoStateToken?) async
        -> Result<SwitchOutcome, PresentableError>
    {
        await perform("Create branch \(name)", summarize: OutcomeText.describe) { handle, _ throws(GitCoreError) in
            try await handle.createBranch(name, startPoint: start, switchTo: switchTo, expected: expected)
        }
    }

    public func switchTo(_ target: SwitchTarget, expected: RepoStateToken?) async -> Result<
        SwitchOutcome, PresentableError
    > {
        await perform(Self.title(for: target), summarize: OutcomeText.describe) { handle, _ throws(GitCoreError) in
            try await handle.switchTo(target, expected: expected)
        }
    }

    public func stashAndSwitch(_ target: SwitchTarget, context: ExecContext, expected: RepoStateToken?) async
        -> Result<StashEntry?, PresentableError>
    {
        await perform("Stash and \(Self.title(for: target).lowercased())") { _ in
            OperationSummary("Switched; your changes are in a stash.")
        } _: { handle, _ throws(GitCoreError) in
            try await handle.stashAndSwitch(target, context: context, expected: expected)
        }
    }

    public func renameBranch(_ old: String, to new: String, expected: RepoStateToken?) async -> Result<
        Void, PresentableError
    > {
        await perform("Rename \(old) to \(new)", refresh: [.refs, .head, .config]) { _ in
            OperationSummary("Renamed.")
        } _: {
            handle, _ throws(GitCoreError) in
            try await handle.renameBranch(old, to: new, expected: expected)
        }
    }

    public func deleteBranch(_ name: String, token: ConfirmationToken, expected: RepoStateToken?) async
        -> Result<Void, PresentableError>
    {
        await perform("Delete branch \(name)", refresh: [.refs, .config]) { _ in
            OperationSummary("Deleted.")
        } _: {
            handle, _ throws(GitCoreError) in
            try await handle.deleteBranch(name, token: token, expected: expected)
        }
    }

    public func deleteRemoteBranch(remote: String, branch: String, token: ConfirmationToken) async
        -> Result<PushOutcome, PresentableError>
    {
        await perform("Delete \(remote)/\(branch)", refresh: [.refs], summarize: OutcomeText.describe) {
            handle, _ throws(GitCoreError) in
            try await handle.deleteRemoteBranch(remote: remote, branch: branch, token: token)
        }
    }

    public func setUpstream(of branch: String, to upstream: String?) async -> Result<Void, PresentableError> {
        await perform(upstream == nil ? "Unset upstream" : "Set upstream", refresh: [.config, .refs]) { _ in
            OperationSummary(upstream.map { "Now tracking \($0)." } ?? "Upstream removed.")
        } _: { handle, _ throws(GitCoreError) in
            try await handle.setUpstream(of: branch, to: upstream)
        }
    }

    // MARK: Integration

    public func merge(_ request: MergeRequest, context: ExecContext, expected: RepoStateToken?) async
        -> Result<IntegrationOutcome, PresentableError>
    {
        await perform("Merge \(Self.shortRef(request.source))", summarize: OutcomeText.describe) {
            handle, _ throws(GitCoreError) in
            try await handle.merge(request, context: context, expected: expected)
        }
    }

    public func rebase(onto: String, context: ExecContext, expected: RepoStateToken?) async
        -> Result<IntegrationOutcome, PresentableError>
    {
        await perform("Rebase onto \(Self.shortRef(onto))", summarize: OutcomeText.describe) {
            handle, _ throws(GitCoreError) in
            try await handle.rebase(onto: onto, context: context, expected: expected)
        }
    }

    public func cherryPick(_ commits: [String], mainline: Int?, context: ExecContext, expected: RepoStateToken?) async
        -> Result<IntegrationOutcome, PresentableError>
    {
        let title = commits.count == 1 ? "Cherry-pick \(commits[0].prefix(7))" : "Cherry-pick \(commits.count) commits"
        return await perform(title, summarize: OutcomeText.describe) { handle, _ throws(GitCoreError) in
            try await handle.cherryPick(commits, mainline: mainline, context: context, expected: expected)
        }
    }

    public func revert(_ commit: String, mainline: Int?, context: ExecContext, expected: RepoStateToken?) async
        -> Result<IntegrationOutcome, PresentableError>
    {
        await perform("Revert \(commit.prefix(7))", summarize: OutcomeText.describe) { handle, _ throws(GitCoreError) in
            try await handle.revert(commit, mainline: mainline, context: context, expected: expected)
        }
    }

    public func continueOperation(context: ExecContext) async -> Result<IntegrationOutcome, PresentableError> {
        await perform("Continue", summarize: OutcomeText.describe) { handle, _ throws(GitCoreError) in
            try await handle.continueOperation(context: context)
        }
    }

    public func skipCurrent(context: ExecContext, token: ConfirmationToken) async -> Result<
        IntegrationOutcome, PresentableError
    > {
        await perform("Skip commit", summarize: OutcomeText.describe) { handle, _ throws(GitCoreError) in
            try await handle.skipCurrent(context: context, token: token)
        }
    }

    public func abortOperation(token: ConfirmationToken) async -> Result<Void, PresentableError> {
        await perform("Abort") { _ in
            OperationSummary("Aborted; the repository is back where it was.")
        } _: {
            handle, _ throws(GitCoreError) in
            try await handle.abortOperation(token: token)
        }
    }

    // MARK: Conflicts

    public func conflicts() async -> [ConflictEntry] {
        (try? await handle?.conflicts()) ?? []
    }

    public func saveResolution(_ path: String, content: [UInt8], expected: FileHash) async -> Result<
        FileHash, PresentableError
    > {
        guard let handle else { return .failure(PresentableError.make(.cancelled)) }
        do {
            let hash = try await handle.saveResolution(path, content: content, expected: expected)
            scheduleRefresh([.worktree], reason: .user)
            return .success(hash)
        } catch {
            return .failure(PresentableError.make(error))
        }
    }

    public func markResolved(_ path: String, expected: FileHash) async -> Result<Void, PresentableError> {
        await perform("Mark \((path as NSString).lastPathComponent) resolved", refresh: [.index, .worktree]) { _ in
            OperationSummary("Marked as resolved.")
        } _: { handle, _ throws(GitCoreError) in
            try await handle.markResolved(path, expected: expected)
        }
    }

    public func resolveWithSide(_ path: String, choice: ConflictFallbackChoice, token: ConfirmationToken) async
        -> Result<Void, PresentableError>
    {
        await perform("Resolve \((path as NSString).lastPathComponent)", refresh: [.index, .worktree]) { _ in
            OperationSummary("Resolved.")
        } _: { handle, _ throws(GitCoreError) in
            try await handle.resolveWithSide(path, choice: choice, token: token)
        }
    }

    // MARK: Stash

    public func stashPush(_ request: StashPushRequest, context: ExecContext) async -> Result<
        StashEntry?, PresentableError
    > {
        await perform("Stash changes", refresh: [.index, .worktree, .refs]) { _ in
            OperationSummary("Stashed.")
        } _: {
            handle, _ throws(GitCoreError) in
            try await handle.stashPush(request, context: context)
        }
    }

    public func applyStash(_ entry: StashEntry, pop: Bool, context: ExecContext) async
        -> Result<StashApplyOutcome, PresentableError>
    {
        await perform(pop ? "Pop \(entry.name)" : "Apply \(entry.name)", refresh: [.index, .worktree, .refs]) {
            outcome in
            switch outcome {
            case .applied: OperationSummary(pop ? "Popped." : "Applied.")
            case .conflicts(let paths, _):
                OperationSummary(
                    "Applied with \(paths.count) conflicted \(paths.count == 1 ? "file" : "files"); the stash was kept.",
                    needsAttention: true)
            }
        } _: { handle, _ throws(GitCoreError) in
            try await handle.applyStash(index: entry.index, oid: entry.oid, pop: pop, context: context)
        }
    }

    public func dropStash(_ entry: StashEntry, token: ConfirmationToken) async -> Result<Void, PresentableError> {
        await perform("Drop \(entry.name)", refresh: [.refs]) { _ in
            OperationSummary("Dropped.")
        } _: { handle, _ throws(GitCoreError) in
            try await handle.dropStash(index: entry.index, oid: entry.oid, token: token)
        }
    }

    // MARK: Descriptions

    static func shortRef(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref.count == 40 || ref.count == 64 ? String(ref.prefix(7)) : ref
    }

    static func title(for target: SwitchTarget) -> String {
        switch target {
        case .branch(let name): "Switch to \(name)"
        case .trackRemote(let remote, let branch, _): "Check out \(remote)/\(branch)"
        case .detach(let oid): "Check out \(oid.prefix(7))"
        }
    }
}

/// One-line outcome texts for the activity list (nonisolated, so operations can summarize off the main actor).
public enum OutcomeText {
    public static func describe(_ outcome: FetchOutcome) -> OperationSummary {
        if outcome.cancelled {
            return OperationSummary(
                outcome.changedRefs == 0
                    ? "Fetch cancelled — no refs changed."
                    : "Fetch cancelled — \(outcome.changedRefs) refs had already changed.")
        }
        return OperationSummary(
            outcome.changedRefs == 0
                ? "Already up to date." : "\(outcome.changedRefs) \(outcome.changedRefs == 1 ? "ref" : "refs") updated."
        )
    }

    public static func describe(_ outcome: PullOutcome) -> OperationSummary {
        if outcome.fetch.cancelled { return OperationSummary("Pull cancelled during fetch — nothing was integrated.") }
        return outcome.integration.map(describe) ?? OperationSummary("Fetched.")
    }

    public static func describe(_ outcome: IntegrationOutcome) -> OperationSummary {
        switch outcome {
        case .upToDate: OperationSummary("Already up to date.")
        case .fastForwarded(_, let to): OperationSummary("Fast-forwarded to \(to.prefix(7)).")
        case .merged(let commit): OperationSummary("Merged (\(commit.prefix(7))).")
        case .rebased(let count): OperationSummary("Rebased \(count) \(count == 1 ? "commit" : "commits").")
        case .committed(let commit): OperationSummary("Created \(commit.prefix(7)).")
        case .notFastForward(let ahead, let behind):
            OperationSummary(
                "Can't fast-forward: \(ahead) local and \(behind) incoming \(behind == 1 ? "commit" : "commits"). Choose merge or rebase.",
                needsAttention: true)
        case .stoppedWithConflicts(let paths):
            OperationSummary(
                "Stopped with \(paths.count) conflicted \(paths.count == 1 ? "file" : "files").", needsAttention: true)
        case .stoppedInProgress(let message):
            OperationSummary(
                message.isEmpty ? "Stopped; the operation is still in progress." : message, needsAttention: true)
        case .finished: OperationSummary("Done.")
        }
    }

    public static func describe(_ outcome: PushOutcome) -> OperationSummary {
        if outcome.cancelled {
            let pushed = outcome.refs.first?.status == .fastForward
            return OperationSummary(
                pushed
                    ? "Push cancelled — but the remote already has your commits."
                    : "Push cancelled — the remote is unchanged.")
        }
        switch outcome.rejection {
        case nil:
            if outcome.refs.allSatisfy({ $0.status == .upToDate }) { return OperationSummary("Everything up to date.") }
            if outcome.refs.first?.status == .deleted { return OperationSummary("Deleted on the remote.") }
            return OperationSummary("Pushed.")
        case .nonFastForward?:
            return OperationSummary("Rejected: the remote has commits you don't have.", needsAttention: true)
        case .staleLease?:
            return OperationSummary("Rejected: the remote moved since you last fetched.", needsAttention: true)
        case .remoteHook(let reason)?:
            return OperationSummary("Rejected by the remote (\(reason)).", needsAttention: true)
        case .other(let reason)?: return OperationSummary("Rejected (\(reason)).", needsAttention: true)
        }
    }

    public static func describe(_ outcome: SwitchOutcome) -> OperationSummary {
        switch outcome {
        case .switched: OperationSummary("Done.")
        case .wouldOverwrite(let paths, _):
            OperationSummary(
                "Blocked: \(paths.count) \(paths.count == 1 ? "file has" : "files have") changes that would be overwritten.",
                needsAttention: true)
        }
    }
}
