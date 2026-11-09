import AppKit
import GitCore
import Observation
import Services

/// A sheet the repository's operations present (design §3.2–§3.7). One at a time, window-modal.
enum OperationSheet: Identifiable {
    case confirm(ConfirmationRequest)
    case error(PresentableError)
    case newBranch(start: String, label: String)
    case rename(branch: String)
    case setUpstream(branch: String, remotes: [String])
    case publish(branch: String, remotes: [String])
    case pushRejected(request: PushRequest, outcome: PushOutcome)
    case notFastForward(ahead: Int, behind: Int)
    case merge(source: String, label: String, conflicts: [String])
    case rebase(onto: String, label: String, plan: RebasePlan)
    case mainline(commit: String, parents: [CommitSummary], isRevert: Bool)
    case blockedSwitch(target: SwitchTarget, paths: [String], untracked: Bool)
    case stashCreate(paths: [String])
    case remotes([RemoteInfo])
    case detached(oid: String)
    case unmerged(branch: String, commits: [CommitSummary], tip: String, expected: RepoStateToken)
    case insecureClone

    var id: String {
        switch self {
        case .confirm(let request): "confirm-\(request.id)"
        case .error(let error): "error-\(error.title)"
        case .newBranch(let start, _): "new-\(start)"
        case .rename(let branch): "rename-\(branch)"
        case .setUpstream(let branch, _): "upstream-\(branch)"
        case .publish(let branch, _): "publish-\(branch)"
        case .pushRejected(let request, _): "rejected-\(request.localBranch)"
        case .notFastForward: "nff"
        case .merge(let source, _, _): "merge-\(source)"
        case .rebase(let onto, _, _): "rebase-\(onto)"
        case .mainline(let commit, _, _): "mainline-\(commit)"
        case .blockedSwitch: "blocked"
        case .stashCreate: "stash"
        case .remotes: "remotes"
        case .detached(let oid): "detached-\(oid)"
        case .unmerged(let branch, _, _, _): "unmerged-\(branch)"
        case .insecureClone: "insecure"
        }
    }
}

/// Everything a repository tab can do in Phase 4 (design §3): every entry point — command bar, menus, context
/// menus, banner, resolver — calls in here. It prepares sheets with a `RepoStateToken`, captures the profile
/// snapshot when the user confirms, runs the operation through the session (→ `OperationCenter` → the
/// repository's single writer) and turns outcomes into the next sheet (non-fast-forward, rejection, blocked
/// switch, conflicts).
@MainActor @Observable
final class OperationsController {
    let session: RepositorySession
    let model: AppModel
    var sheet: OperationSheet?
    /// The open conflict resolver (covers the graph area).
    var resolver: ResolverModel?
    var showsActivity = false
    /// Detached-HEAD explanation shown once per session.
    @ObservationIgnored var explainedDetached = false
    /// Rebase ours/theirs explanation shown once per session.
    @ObservationIgnored var explainedRebaseLabels = false

    @ObservationIgnored var refs: RefSnapshot? {
        didSet { if refs?.revision != oldValue?.revision { refreshWebRemote() } }
    }
    /// The remote URL web links map from (upstream's remote, else `origin`), cached for synchronous menus.
    @ObservationIgnored private(set) var webRemoteURL: String?
    @ObservationIgnored var selectCommit: (ObjectID) -> Void = { _ in }
    @ObservationIgnored var showWorkingDirectory: () -> Void = {}
    /// Shows any commit (a stash) in the inspector, even when the graph doesn't list it.
    @ObservationIgnored var inspectCommit: (ObjectID) -> Void = { _ in }
    @ObservationIgnored private var pendingDestructive: ((ConfirmationToken) -> Void)?
    @ObservationIgnored private var retry: (() -> Void)?
    @ObservationIgnored private var lastRejected: PushRequest?

    init(session: RepositorySession, model: AppModel) {
        self.session = session
        self.model = model
    }

    // MARK: Context

    var repositoryName: String { ((session.info?.topLevel ?? session.path) as NSString).lastPathComponent }
    var currentBranch: String? { session.status?.branch.head }
    var headIsDetached: Bool { session.status?.branch.isDetached ?? false }
    var contextLine: String {
        var branch = currentBranch ?? "detached HEAD"
        if case .rebasing(let head, _, _, _, _, _) = session.operationState { branch = "rebasing \(head)" }
        return [repositoryName, branch].joined(separator: " · ")
    }

    /// The identity captured now (when the user confirms) — a later profile switch changes nothing.
    var execContext: ExecContext {
        ExecContext(
            identity: model.profiles.snapshot().map { IdentitySnapshot(author: $0.author, committer: $0.committer) })
    }

    var identityLine: String? {
        guard let profile = model.profiles.activeProfile else { return nil }
        let committer = profile.committer ?? profile.author
        return "Commits as \(committer.name) <\(committer.email)> · \(profile.displayName) profile"
    }

    var hasProfile: Bool { model.profiles.activeProfile != nil }

    func chooseProfile() {
        sheet = nil
        NSApp.sendAction(Selector(("showProfileSwitcher:")), to: nil, from: nil)
    }

    // MARK: Presenting results

    func present(_ error: PresentableError, retry: (() -> Void)? = nil) {
        guard !error.isCancellation else { return }
        self.retry = retry
        sheet = .error(error)
        NSAccessibility.post(
            element: NSApp.mainWindow as Any, notification: .announcementRequested,
            userInfo: [.announcement: error.title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Runs a recovery action from an error sheet.
    func perform(_ action: RecoveryAction) {
        sheet = nil
        switch action {
        case .retry: retry?()
        case .refresh: session.reload()
        case .resolveConflicts: openNextConflict()
        case .abortOperation: abort()
        case .chooseProfile: chooseProfile()
        case .stashAndRetry: showWorkingDirectory()
        case .showWorkingDirectory: showWorkingDirectory()
        case .openInTerminal: RepositoryActions.openInTerminal(session.info?.topLevel ?? session.path)
        case .revealInFinder: RepositoryActions.revealInFinder(session.info?.topLevel ?? session.path)
        case .pullFastForward: pull(.fastForwardOnly)
        case .pullRebase: pull(.rebase)
        case .forcePushWithLease: if let request = lastRejected { confirmForcePush(request) }
        case .unsetUpstream: if let branch = currentBranch { setUpstream(branch, to: nil) }
        case .publishBranch: push()
        case .createBranch: newBranch(at: "HEAD", label: "HEAD")
        }
    }

    /// Shows the confirmation sheet; `action` runs only with the token the sheet mints.
    func confirm(_ request: ConfirmationRequest, then action: @escaping (ConfirmationToken) -> Void) {
        pendingDestructive = action
        sheet = .confirm(request)
    }

    func confirmed(_ request: ConfirmationRequest) {
        sheet = nil
        let action = pendingDestructive
        pendingDestructive = nil
        action?(request.confirm())
    }

    func cancelSheet() {
        sheet = nil
        pendingDestructive = nil
    }

    private func requireProfile() -> ExecContext? {
        let context = execContext
        guard context.identity != nil else {
            present(PresentableError.make(.noActiveProfile))
            return nil
        }
        return context
    }

    /// A retry action for an error sheet (a type, so trailing success closures never bind to it).
    struct Retry {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private func handle<T>(
        _ result: Result<T, PresentableError>, retry: Retry? = nil, _ success: (T) -> Void = { _ in }
    ) {
        switch result {
        case .success(let value): success(value)
        case .failure(let error): present(error, retry: retry?.run)
        }
    }

    private func handleIntegration(_ outcome: IntegrationOutcome) {
        switch outcome {
        case .stoppedWithConflicts: openNextConflict()
        case .notFastForward(let ahead, let behind): sheet = .notFastForward(ahead: ahead, behind: behind)
        default: break
        }
    }

    // MARK: Remote

    func fetch(remote: String? = nil, prune: Bool? = nil) {
        Task {
            let remotes = (try? await session.repository?.remotes()) ?? []
            let target =
                remote ?? (remotes.count == 1 ? remotes.first?.name : nil)
                ?? (remotes.contains { $0.name == "origin" } ? "origin" : nil)
            let effectivePrune = prune ?? remotes.first { $0.name == target }?.prune ?? remotes.first?.prune ?? false
            guard !remotes.isEmpty else {
                present(
                    PresentableError(
                        title: "This repository has no remotes.",
                        explanation: "Add a remote in Terminal (git remote add). Remote management arrives later."))
                return
            }
            handle(
                await session.fetch(FetchRequest(remote: target, prune: effectivePrune)),
                retry: Retry { [weak self] in self?.fetch(remote: remote, prune: prune) })
        }
    }

    func fetchAll() { fetch(remote: nil, prune: nil) }

    func pull(_ mode: PullMode = .fastForwardOnly) {
        let context = mode == .fastForwardOnly ? execContext : requireProfile()
        guard let context else { return }
        Task {
            handle(await session.pull(mode, context: context), retry: Retry { [weak self] in self?.pull(mode) }) {
                [weak self] outcome in
                if let integration = outcome.integration { self?.handleIntegration(integration) }
            }
        }
    }

    /// Push the current branch; no upstream → publish sheet (design §3.4).
    func push() {
        guard let branch = currentBranch,
            !(session.status?.branch.isUnborn ?? true) || session.status?.branch.oid != nil
        else {
            present(
                PresentableError(
                    title: "You're not on a branch.",
                    explanation: "Create a branch here or switch to one before pushing.", actions: [.createBranch]))
            return
        }
        Task {
            guard let repository = session.repository else { return }
            let remotes = ((try? await repository.remotes()) ?? []).map(\.name)
            guard !remotes.isEmpty else {
                present(
                    PresentableError(
                        title: "This repository has no remotes.",
                        explanation: "Add a remote in Terminal (git remote add)."))
                return
            }
            if let upstream = try? await repository.upstream(of: branch) {
                let remoteBranch = String(upstream.shortName.dropFirst(upstream.remote.count + 1))
                run(PushRequest(remote: upstream.remote, localBranch: branch, remoteBranch: remoteBranch))
            } else {
                sheet = .publish(branch: branch, remotes: remotes)
            }
        }
    }

    func run(_ request: PushRequest) {
        Task {
            handle(await session.push(request), retry: Retry { [weak self] in self?.run(request) }) {
                [weak self] outcome in
                guard let self else { return }
                if outcome.rejection != nil {
                    lastRejected = request
                    sheet = .pushRejected(request: request, outcome: outcome)
                }
            }
        }
    }

    /// Force push with lease: the destructive sheet shows the expected remote SHA and what would be overwritten.
    func confirmForcePush(_ request: PushRequest) {
        Task {
            guard let repository = session.repository else { return }
            _ = await session.fetch(FetchRequest(remote: request.remote, prune: false))
            guard
                let expected = try? await repository.remoteTrackingOID(
                    remote: request.remote, branch: request.remoteBranch)
            else {
                present(
                    PresentableError(
                        title: "Nothing to force push over.",
                        explanation: "The remote branch doesn't exist; push normally."))
                return
            }
            let lost =
                (try? await repository.commits(
                    in: "refs/remotes/\(request.remote)/\(request.remoteBranch)",
                    notIn: "refs/heads/\(request.localBranch)")) ?? []
            let losses =
                lost.prefix(8).map { "\($0.shortOID) \($0.subject)" }
                + (lost.count > 8 ? ["and \(lost.count - 8) more"] : [])
            let confirmation = ConfirmationRequest(
                action: .forcePush(remote: request.remote, remoteRef: request.remoteBranch, expected: expected),
                title: "Force push \(request.localBranch) to \(request.remote)/\(request.remoteBranch)?",
                context: contextLine,
                changes:
                    "The remote branch is replaced by your local branch — only if it is still at \(expected.prefix(7)) (with lease), so commits pushed since are never overwritten.",
                losses: lost.isEmpty
                    ? []
                    : [
                        "\(lost.count) \(lost.count == 1 ? "commit" : "commits") on the remote would no longer be on the branch:"
                    ] + losses,
                recoverability:
                    "Recoverable on the remote only through its reflog or another clone. Expected remote tip:",
                recoveryValue: expected, verb: "Force Push", isHighRisk: true)
            confirm(confirmation) { [weak self] token in
                guard let self else { return }
                Task {
                    self.handle(await self.session.forcePushWithLease(request, expected: expected, token: token)) {
                        outcome in
                        if outcome.rejection == .staleLease {
                            self.present(
                                PresentableError(
                                    title: "The remote moved since you fetched.",
                                    explanation: "Nothing was overwritten. Fetch and review the new commits first.",
                                    actions: [.pullRebase]))
                        }
                    }
                }
            }
        }
    }

    func showRemotes() {
        Task {
            let remotes = (try? await session.repository?.remotes()) ?? []
            sheet = .remotes(remotes)
        }
    }

    // MARK: Branches

    func newBranch(at start: String, label: String) {
        sheet = .newBranch(start: start, label: label)
    }

    func createBranch(_ name: String, at start: String, switchTo: Bool) {
        Task {
            let token = await session.captureState()
            handle(await session.createBranch(name, at: start, switchTo: switchTo, expected: token)) {
                [weak self] outcome in
                if case .wouldOverwrite(let paths, let untracked) = outcome {
                    self?.sheet = .blockedSwitch(target: .branch(name), paths: paths, untracked: untracked)
                }
            }
        }
    }

    func switchTo(_ target: SwitchTarget) {
        if case .detach(let oid) = target, !explainedDetached {
            explainedDetached = true
            sheet = .detached(oid: oid)
            return
        }
        Task {
            let token = await session.captureState()
            handle(
                await session.switchTo(target, expected: token), retry: Retry { [weak self] in self?.switchTo(target) }
            ) { [weak self] outcome in
                if case .wouldOverwrite(let paths, let untracked) = outcome {
                    self?.sheet = .blockedSwitch(target: target, paths: paths, untracked: untracked)
                }
            }
        }
    }

    func detachConfirmed(_ oid: String) {
        sheet = nil
        switchTo(.detach(oid))
    }

    /// Double-click / Check Out on a ref: local → switch; remote → its local branch, or a new tracking branch.
    func checkout(ref: GitRef) {
        switch ref.kind {
        case .local:
            switchTo(.branch(ref.shortName))
        case .remote:
            guard let remote = ref.remoteName, let branch = ref.remoteBranchName,
                let tip = ref.commit?.hex(refs?.format ?? .sha1)
            else { return }
            if refs?.ref(named: "refs/heads/\(branch)") != nil {
                switchTo(.branch(branch))
            } else {
                switchTo(.trackRemote(remote: remote, branch: branch, localName: branch))
            }
        case .tag, .other:
            if let commit = ref.commit { switchTo(.detach(commit.hex(refs?.format ?? .sha1))) }
        }
    }

    func stashAndSwitch(_ target: SwitchTarget) {
        sheet = nil
        guard let context = requireProfile() else { return }
        Task {
            let token = await session.captureState()
            handle(await session.stashAndSwitch(target, context: context, expected: token))
        }
    }

    func rename(_ branch: String) { sheet = .rename(branch: branch) }

    func renameBranch(_ old: String, to new: String) {
        Task {
            let token = await session.captureState()
            handle(await session.renameBranch(old, to: new, expected: token))
        }
    }

    func delete(branch: String) {
        guard branch != currentBranch else {
            present(
                PresentableError(
                    title: "You can't delete the current branch.", explanation: "Switch to another branch first."))
            return
        }
        Task {
            let tip =
                (try? await session.repository?.commits(in: "refs/heads/\(branch)", notIn: nil, limit: 1).first?.oid)
                ?? ""
            let request = ConfirmationRequest(
                action: .deleteBranch(name: branch, force: false), title: "Delete branch \(branch)?",
                context: contextLine,
                changes:
                    "The local branch is removed. Commits that are merged elsewhere stay; the remote branch is not touched.",
                recoverability: "Recoverable via reflog: the tip was", recoveryValue: tip.isEmpty ? nil : tip,
                verb: "Delete Branch")
            guard let token = await session.captureState() else { return }
            confirm(request) { [weak self] confirmed in
                guard let self else { return }
                Task {
                    let result = await self.session.deleteBranch(branch, token: confirmed, expected: token)
                    if case .failure(let error) = result, error.kind == .branchNotFullyMerged {
                        let base = (try? await self.session.repository?.upstream(of: branch))?.ref ?? "HEAD"
                        let commits =
                            (try? await self.session.repository?.commits(in: "refs/heads/\(branch)", notIn: base)) ?? []
                        self.sheet = .unmerged(branch: branch, commits: commits, tip: tip, expected: token)
                    } else {
                        self.handle(result)
                    }
                }
            }
        }
    }

    func forceDelete(branch: String, commits: [CommitSummary], tip: String, expected: RepoStateToken) {
        let request = ConfirmationRequest(
            action: .deleteBranch(name: branch, force: true), title: "Delete unmerged branch \(branch)?",
            context: contextLine,
            changes:
                "The branch is removed even though its commits aren't merged into \(currentBranch ?? "HEAD") or its upstream.",
            losses: ["\(commits.count) \(commits.count == 1 ? "commit" : "commits") not merged:"]
                + commits.prefix(8).map { "\($0.shortOID) \($0.subject)" },
            recoverability: "Recoverable via reflog: the tip was", recoveryValue: tip.isEmpty ? nil : tip,
            verb: "Delete Branch")
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task { self.handle(await self.session.deleteBranch(branch, token: token, expected: expected)) }
        }
    }

    func deleteRemote(ref: GitRef) {
        guard let remote = ref.remoteName, let branch = ref.remoteBranchName,
            let tip = ref.commit?.hex(refs?.format ?? .sha1)
        else { return }
        let request = ConfirmationRequest(
            action: .deleteRemoteBranch(remote: remote, branch: branch),
            title: "Delete \(remote)/\(branch) on the remote?",
            context: contextLine,
            changes: "The branch is deleted on \(remote) for everyone who uses it. Local branches are not touched.",
            recoverability: "Recoverable only by pushing the commit again. The remote tip was",
            recoveryValue: ref.commit?.hex(refs?.format ?? .sha1), verb: "Delete Remote Branch", isHighRisk: true)
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task {
                self.handle(
                    await self.session.deleteRemoteBranch(
                        remote: remote, branch: branch, expectedTip: tip, token: token)
                ) {
                    outcome in
                    if outcome.rejection == .staleLease {
                        self.present(
                            PresentableError(
                                title: "The remote branch moved.",
                                explanation:
                                    "Someone pushed to it since you last fetched, so it was not deleted. Fetch and review it first."
                            ))
                    }
                }
            }
        }
    }

    func setUpstream(for branch: String) {
        Task {
            let remotes = (refs?.remotes ?? []).map(\.shortName).filter { !$0.hasSuffix("/HEAD") }
            sheet = .setUpstream(branch: branch, remotes: remotes)
        }
    }

    func setUpstream(_ branch: String, to upstream: String?) {
        Task { handle(await session.setUpstream(of: branch, to: upstream)) }
    }

    func copyLink(_ target: WebLink.Target) {
        Task {
            guard let url = await webLink(target) else { return }
            Pasteboard.copy(url.absoluteString)
        }
    }

    private func refreshWebRemote() {
        Task {
            guard let repository = session.repository else { return }
            let remotes = (try? await repository.remotes()) ?? []
            let upstreamRemote = try? await repository.upstream()?.remote
            let remote =
                remotes.first { $0.name == upstreamRemote } ?? remotes.first { $0.name == "origin" } ?? remotes.first
            webRemoteURL = remote?.fetchURLs.first
        }
    }

    /// The web link for `target`, when the remote (upstream's, else `origin`) maps to a known host.
    func webLink(_ target: WebLink.Target) async -> URL? {
        guard let repository = session.repository else { return nil }
        let remotes = (try? await repository.remotes()) ?? []
        let upstreamRemote = try? await repository.upstream()?.remote
        let remote =
            remotes.first { $0.name == upstreamRemote } ?? remotes.first { $0.name == "origin" } ?? remotes.first
        guard let url = remote?.fetchURLs.first else { return nil }
        return WebLink.map(remoteURL: url, target: target)
    }

    // MARK: Integration

    /// The short name when no other ref shares it (Git then writes "Merge branch 'x'"), else the full name.
    func unambiguousName(for ref: GitRef) -> String {
        let short = ref.shortName
        let clashes = (refs?.refs ?? []).filter { $0.fullName != ref.fullName && $0.shortName == short }
        return clashes.isEmpty && !short.hasPrefix("-") ? short : ref.fullName
    }

    func merge(source: String, label: String) {
        Task {
            let conflicts = (try? await session.repository?.predictMergeConflicts(source: source)) ?? []
            sheet = .merge(source: source, label: label, conflicts: conflicts)
        }
    }

    func runMerge(_ request: MergeRequest) {
        let context = request.strategy == .fastForwardOnly ? execContext : requireProfile()
        guard let context else { return }
        Task {
            let token = await session.captureState()
            handle(await session.merge(request, context: context, expected: token)) { [weak self] in
                self?.handleIntegration($0)
            }
        }
    }

    func rebase(onto: String, label: String) {
        Task {
            guard let plan = try? await session.repository?.rebasePlan(onto: onto) else { return }
            sheet = .rebase(onto: onto, label: label, plan: plan)
        }
    }

    func runRebase(onto: String) {
        guard let context = requireProfile() else { return }
        Task {
            let token = await session.captureState()
            handle(await session.rebase(onto: onto, context: context, expected: token)) { [weak self] in
                self?.handleIntegration($0)
            }
        }
    }

    func cherryPick(_ commits: [String]) {
        guard requireProfile() != nil else { return }
        Task {
            if commits.count == 1, let parents = try? await session.repository?.parents(of: commits[0]),
                parents.count > 1
            {
                sheet = .mainline(commit: commits[0], parents: parents, isRevert: false)
                return
            }
            runCherryPick(commits, mainline: nil)
        }
    }

    func runCherryPick(_ commits: [String], mainline: Int?) {
        guard let context = requireProfile() else { return }
        Task {
            let token = await session.captureState()
            handle(await session.cherryPick(commits, mainline: mainline, context: context, expected: token)) {
                [weak self] in
                self?.handleIntegration($0)
            }
        }
    }

    func revert(_ commit: String) {
        guard requireProfile() != nil else { return }
        Task {
            if let parents = try? await session.repository?.parents(of: commit), parents.count > 1 {
                sheet = .mainline(commit: commit, parents: parents, isRevert: true)
                return
            }
            runRevert(commit, mainline: nil)
        }
    }

    func runRevert(_ commit: String, mainline: Int?) {
        guard let context = requireProfile() else { return }
        Task {
            let token = await session.captureState()
            handle(await session.revert(commit, mainline: mainline, context: context, expected: token)) { [weak self] in
                self?.handleIntegration($0)
            }
        }
    }

    func continueOperation() {
        guard let context = requireProfile() else { return }
        Task {
            handle(await session.continueOperation(context: context)) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .stoppedWithConflicts: openNextConflict()
                case .stoppedInProgress(let message)
                where message.contains("nothing to commit") || message.contains("empty"):
                    present(
                        PresentableError(
                            title: "This commit is now empty.",
                            explanation: "Your resolution matches what is already there. Skip the commit to continue."))
                default: break
                }
            }
        }
    }

    func skip() {
        guard let context = requireProfile() else { return }
        Task { await self.confirmSkip(context: context) }
    }

    private func confirmSkip(context: ExecContext) async {
        guard let expected = await session.captureState() else { return }
        let state = session.operationState
        var commit = "the current commit"
        switch state {
        case .rebasing(_, _, _, _, let stopped?, _), .cherryPicking(let stopped?, _, _), .reverting(let stopped?, _, _):
            commit = "\(stopped.shortOID) “\(stopped.subject)”"
        default: break
        }
        let request = ConfirmationRequest(
            action: .skipCurrent, title: "Skip \(commit)?", context: contextLine,
            changes: "This commit is left out and the operation moves on to the next one.",
            losses: ["Any resolutions you made for this commit are discarded."],
            recoverability: "The original commit stays reachable from its branch and the reflog.", verb: "Skip Commit")
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task {
                self.handle(await self.session.skipCurrent(context: context, token: token, expected: expected)) {
                    outcome in
                    if case .stoppedWithConflicts = outcome { self.openNextConflict() }
                }
            }
        }
    }

    func abort() {
        Task { await self.confirmAbort() }
    }

    private func confirmAbort() async {
        guard let expected = await session.captureState() else { return }
        let title: String
        switch session.operationState {
        case .merging(let source, _):
            title = "Abort merging \(source.isEmpty ? "" : source + " ")into \(currentBranch ?? "HEAD")?"
        case .rebasing(let head, _, _, _, _, _): title = "Abort rebasing \(head)?"
        case .cherryPicking: title = "Abort the cherry-pick?"
        case .reverting: title = "Abort the revert?"
        default: title = "Abort the operation?"
        }
        let resolved = session.status?.summary.map { $0.staged } ?? 0
        let request = ConfirmationRequest(
            action: .abortOperation, title: title, context: contextLine,
            changes: "The branch, index and working tree return to where they were before the operation started.",
            losses: resolved > 0 ? ["Resolutions and staged changes made during the operation are discarded."] : [],
            recoverability:
                "Resolved files are not kept. Commits already replayed during a rebase stay reachable from the reflog.",
            verb: "Abort")
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task {
                self.handle(await self.session.abortOperation(token: token, expected: expected))
                self.resolver = nil
            }
        }
    }

    // MARK: Conflicts

    func openNextConflict() {
        Task {
            let entries = await session.conflicts()
            guard let first = entries.first else { return }
            openResolver(entries: entries, path: first.path)
        }
    }

    func openConflict(path: String) {
        Task {
            let entries = await session.conflicts()
            guard entries.contains(where: { $0.path == path }) else { return }
            openResolver(entries: entries, path: path)
        }
    }

    private func openResolver(entries: [ConflictEntry], path: String) {
        if let resolver, resolver.entry?.path == path { return }
        let resolver = ResolverModel(controller: self, entries: entries)
        self.resolver = resolver
        resolver.open(path: path)
    }

    func closeResolver() { resolver = nil }

    func resolveFallback(_ entry: ConflictEntry, choice: ConflictFallbackChoice, label: String, effect: String) {
        let request = ConfirmationRequest(
            action: .resolveConflict(path: entry.path, choice: choice.rawValue), title: "\(label) for “\(entry.path)”?",
            context: contextLine, changes: effect,
            recoverability: "Until you continue, Abort returns everything to before the operation.", verb: label)
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task {
                self.handle(await self.session.resolveWithSide(entry.path, choice: choice, token: token)) { _ in
                    self.resolver?.reloadEntries()
                }
            }
        }
    }

    // MARK: Stash

    func createStash(paths: [String] = []) { sheet = .stashCreate(paths: paths) }

    func runStash(_ request: StashPushRequest) {
        guard let context = requireProfile() else { return }
        Task { handle(await session.stashPush(request, context: context)) }
    }

    func quickStash() {
        runStash(StashPushRequest(message: nil, includeUntracked: true))
    }

    func apply(_ entry: StashEntry, pop: Bool) {
        let context = execContext
        Task {
            handle(await session.applyStash(entry, pop: pop, context: context)) { [weak self] outcome in
                if case .conflicts = outcome { self?.openNextConflict() }
            }
        }
    }

    func popLatest() {
        guard let latest = session.stashes?.first else { return }
        apply(latest, pop: true)
    }

    func drop(_ entry: StashEntry) {
        let request = ConfirmationRequest(
            action: .dropStash(index: entry.index, oid: entry.oid), title: "Drop \(entry.name)?", context: contextLine,
            changes: "“\(entry.message)” is removed from the stash list.",
            recoverability: "Recoverable only by its SHA (git stash apply <sha>) until Git prunes it:",
            recoveryValue: entry.oid, verb: "Drop Stash")
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task { self.handle(await self.session.dropStash(entry, token: token)) }
        }
    }
}
