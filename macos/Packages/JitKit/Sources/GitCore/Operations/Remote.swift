import Foundation

// MARK: - Shared helpers

extension RepositoryHandle {
    /// Runs a mutating command and classifies a failure (design §4.11); `index.lock` → `.indexLocked`.
    static func runClassified(_ command: GitCommand, engine: GitEngine, gitDirectory: String)
        async throws(GitCoreError) -> ProcessOutput
    {
        do {
            return try await engine.run(command)
        } catch .processFailed(let code, _, let detail) {
            let failure = GitErrorClassifier.classify(exitCode: code, stderr: detail)
            if failure.kind == .indexLocked { throw .indexLocked(path: gitDirectory + "/index.lock") }
            throw .failed(failure)
        }
    }

    /// Runs `body` in a task the caller's cancellation cannot reach: steps that must not be interrupted
    /// once started (the integration step of a pull, the state read-back after a cancelled transfer).
    static func uncancellable<T: Sendable>(_ body: @escaping @Sendable () async throws(GitCoreError) -> T)
        async throws(GitCoreError) -> T
    {
        let task = Task.detached { () async -> Result<T, GitCoreError> in
            do throws(GitCoreError) { return .success(try await body()) } catch { return .failure(error) }
        }
        return try await task.value.get()
    }

    /// Validates a name Jit passes as a bare argument (remote, branch): never empty, never option-like.
    static func requireSafeName(_ name: String, what: String) throws(GitCoreError) {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), !name.contains("\n") else {
            throw .refused(summary: "“\(name)” isn't a valid \(what) name.")
        }
    }

    static func requireObjectID(_ oid: String) throws(GitCoreError) {
        guard (oid.count == 40 || oid.count == 64), oid.allSatisfy(\.isHexDigit) else {
            throw .refused(summary: "“\(oid)” isn't a commit ID.")
        }
    }

    /// `[0x…]` refs → OID lines of `for-each-ref`, for before/after comparisons.
    static func refMap(engine: GitEngine, in directory: String, pattern: String? = nil) async throws(GitCoreError)
        -> [String: String]
    {
        // Symbolic refs (`origin/HEAD`) are skipped: they move with their target and would count twice.
        var arguments = ["for-each-ref", "--format=%(if)%(symref)%(then)%(else)%(refname)%00%(objectname)%(end)"]
        if let pattern { arguments.append(pattern) }
        let output = try await engine.run(
            GitCommand(arguments, in: directory, kind: .read, stdoutLimit: 256 * 1024 * 1024))
        var map: [String: String] = [:]
        for line in output.stdout.split(separator: 0x0A) where !line.isEmpty {
            guard let nul = line.firstIndex(of: 0) else { continue }
            map[String(decoding: line[..<nul], as: UTF8.self)] = String(
                decoding: line[line.index(after: nul)...], as: UTF8.self)
        }
        return map
    }

    static func changedRefs(_ before: [String: String], _ after: [String: String]) -> Int {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.count
    }
}

// MARK: - Remotes

/// One configured remote (read-only inspector, design §3.4).
public struct RemoteInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var fetchURLs: [String]
    public var pushURLs: [String]
    public var fetchRefspecs: [String]
    /// Effective `remote.<name>.prune` / `fetch.prune`.
    public var prune: Bool

    public var id: String { name }

    /// URLs with any `user:password@` part masked, and whether one was found.
    public static func masked(_ url: String) -> (url: String, hadCredentials: Bool) {
        var stripped = url
        var hasPassword = false
        if let scheme = url.range(of: "://"), let at = url[scheme.upperBound...].firstIndex(of: "@") {
            let userinfo = url[scheme.upperBound..<at]
            // A bare username (`ssh://git@host`) is not a credential; `user:secret@` is.
            if userinfo.contains(":") {
                hasPassword = true
                stripped = url.replacingCharacters(in: scheme.upperBound..<at, with: "***")
            }
        }
        // Token-shaped strings elsewhere in the URL (`?private_token=`, `ghp_…`).
        var redacted = stripped
        redacted.replace(/(?i)(?<key>token|password|passwd|secret)=[^\s&]+/) { "\($0.output.key)=***" }
        redacted.replace(/\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_\-]{20,})\b/) {
            _ in
            "***"
        }
        return (redacted, hasPassword || redacted != stripped)
    }
}

public struct FetchRequest: Sendable, Hashable {
    /// `nil` fetches every remote (`--all`).
    public var remote: String?
    /// Passed explicitly (`--prune` / `--no-prune`) so the UI never lies about what happened.
    public var prune: Bool

    public init(remote: String?, prune: Bool) {
        self.remote = remote
        self.prune = prune
    }
}

public struct FetchOutcome: Sendable, Equatable {
    /// Refs that changed (added, moved, deleted).
    public var changedRefs: Int
    public var cancelled: Bool
    public var remoteLines: [String]
}

extension RepositoryHandle {
    /// Configured remotes with URLs, refspecs and the effective prune setting.
    public nonisolated func remotes() async throws(GitCoreError) -> [RemoteInfo] {
        let names = String(decoding: try await runRead(["remote"], limit: 1024 * 1024), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
        guard !names.isEmpty else { return [] }
        let config = try await gitEngine.run(
            GitCommand(
                ["config", "-z", "--get-regexp", #"^(remote\..*\.(url|pushurl|fetch|prune)|fetch\.prune)$"#],
                in: workingDirectory, kind: .read, acceptedExitCodes: [0, 1]))
        var values: [(String, String)] = []
        for record in config.stdout.split(separator: 0) {
            guard let newline = record.firstIndex(of: 0x0A) else { continue }
            values.append(
                (
                    String(decoding: record[..<newline], as: UTF8.self).lowercased(),
                    String(decoding: record[record.index(after: newline)...], as: UTF8.self)
                ))
        }
        let globalPrune = values.last { $0.0 == "fetch.prune" }.map { $0.1 == "true" } ?? false
        return names.map { name in
            let key = "remote.\(name.lowercased())."
            func all(_ suffix: String) -> [String] { values.filter { $0.0 == key + suffix }.map(\.1) }
            let fetchURLs = all("url")
            let pushURLs = all("pushurl")
            let prune = all("prune").last.map { $0 == "true" } ?? globalPrune
            return RemoteInfo(
                name: name, fetchURLs: fetchURLs, pushURLs: pushURLs.isEmpty ? fetchURLs : pushURLs,
                fetchRefspecs: all("fetch"), prune: prune)
        }
    }

    /// `git fetch --progress [--prune|--no-prune] <remote>|--all` (design §4.6). Cancellable at any time:
    /// Git updates refs at the end, so a cancelled fetch reports what (if anything) changed.
    public func fetch(
        _ request: FetchRequest, context: ExecContext = .anonymous,
        progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> FetchOutcome {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let remoteInfos = try await remotes()
        let known = remoteInfos.map(\.name)
        if let remote = request.remote {
            guard known.contains(remote) else { throw .refused(summary: "There's no remote named “\(remote)”.") }
        } else if known.isEmpty {
            throw .refused(summary: "This repository has no remotes.")
        }
        let urls = remoteInfos.filter { request.remote == nil || $0.name == request.remote }.flatMap(\.fetchURLs)
        return try await performExclusive(
            request.remote.map { "Fetch \($0)" } ?? "Fetch all remotes", invalidating: [.refs, .head]
        ) { () throws(GitCoreError) -> FetchOutcome in
            let before = try await Self.refMap(engine: engine, in: directory)
            var arguments = ["fetch", "--progress", request.prune ? "--prune" : "--no-prune"]
            if let remote = request.remote { arguments.append(remote) } else { arguments.append("--all") }
            let lease = try await context.prepareAccess(for: urls, purpose: .fetch)
            defer { lease?.release() }
            var command = GitEnvironment.remoteCommand(
                arguments, in: directory, context: context, access: lease?.access)
            let sink = ProgressSink(progress)
            command.stderrObserver = sink.observer
            do throws(GitCoreError) {
                _ = try await Self.runClassified(command, engine: engine, gitDirectory: gitDirectory)
            } catch .cancelled {
                let after = try await Self.uncancellable { () throws(GitCoreError) in
                    try await Self.refMap(engine: engine, in: directory)
                }
                return FetchOutcome(
                    changedRefs: Self.changedRefs(before, after), cancelled: true, remoteLines: sink.remoteLines)
            }
            let after = try await Self.refMap(engine: engine, in: directory)
            return FetchOutcome(
                changedRefs: Self.changedRefs(before, after), cancelled: false, remoteLines: sink.remoteLines)
        }
    }
}

// MARK: - Pull (ADR-0030)

public enum PullMode: String, Sendable, Hashable, CaseIterable {
    /// `merge --ff-only @{upstream}` (default).
    case fastForwardOnly
    /// `merge --no-edit @{upstream}` (fast-forward when possible, else a merge commit).
    case merge
    /// `rebase --no-autostash --no-update-refs @{upstream}`.
    case rebase
}

public enum IntegrationOutcome: Sendable, Equatable {
    case upToDate
    case fastForwarded(from: String, to: String)
    case merged(commit: String)
    case rebased(count: Int)
    case committed(commit: String)
    /// A fast-forward was required but the branches diverged; nothing changed.
    case notFastForward(ahead: Int, behind: Int)
    /// Stopped with conflicts in these paths; the repository is in an operation state (banner).
    case stoppedWithConflicts(paths: [String])
    /// The operation stopped for another reason and is still in progress (e.g. an empty commit after
    /// resolution: offer Skip).
    case stoppedInProgress(message: String)
    /// Continue/abort/skip finished the operation.
    case finished
}

public struct PullOutcome: Sendable, Equatable {
    public var fetch: FetchOutcome
    public var integration: IntegrationOutcome?
}

extension RepositoryHandle {
    /// The current branch's upstream: (`origin`, `refs/remotes/origin/main`, `origin/main`), or `nil`.
    public nonisolated func upstream(of branch: String? = nil) async throws(GitCoreError)
        -> (remote: String, ref: String, shortName: String)?
    {
        // `<branch>@{upstream}`: Git does not accept a full ref name before `@{upstream}`.
        if let branch { try Self.requireSafeName(branch, what: "branch") }
        let target = branch.map { "\($0)@{upstream}" } ?? "@{upstream}"
        let output = try await gitEngine.run(
            GitCommand(
                ["rev-parse", "--symbolic-full-name", target], in: workingDirectory, kind: .read,
                acceptedExitCodes: [0, 128]))
        guard output.exitCode == 0 else { return nil }
        let ref = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("refs/remotes/") else { return nil }
        let short = String(ref.dropFirst("refs/remotes/".count))
        let name = try await currentBranchName(branch)
        guard let name else { return nil }
        let remote = try await gitEngine.run(
            GitCommand(
                ["config", "--get", "branch.\(name).remote"], in: workingDirectory, kind: .read,
                acceptedExitCodes: [0, 1])
        ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteName = remote.isEmpty ? String(short.split(separator: "/").first ?? "") : remote
        return (remoteName, ref, short)
    }

    nonisolated func currentBranchName(_ branch: String?) async throws(GitCoreError) -> String? {
        if let branch { return branch }
        let output = try await gitEngine.run(
            GitCommand(
                ["symbolic-ref", "-q", "--short", "HEAD"], in: workingDirectory, kind: .read, acceptedExitCodes: [0, 1])
        )
        let name = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.exitCode == 0 && !name.isEmpty ? name : nil
    }

    static func aheadBehind(engine: GitEngine, in directory: String, _ left: String, _ right: String)
        async throws(GitCoreError) -> (ahead: Int, behind: Int)
    {
        let output = try await engine.run(
            GitCommand(
                ["rev-list", "--left-right", "--count", "\(left)...\(right)", "--"], in: directory, kind: .read))
        let parts = output.stdoutText.split(whereSeparator: { $0 == "\t" || $0.isWhitespace })
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else { return (0, 0) }
        return (ahead, behind)
    }

    /// Explicit two-step pull (design §4.6, ADR-0030): fetch the upstream's remote (cancellable), then the
    /// chosen integration (not cancellable once started). `pull.*` configuration never changes the action.
    public func pull(
        _ mode: PullMode, context: ExecContext, progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> PullOutcome {
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        guard let branch = try await currentBranchName(nil) else {
            throw .failed(ClassifiedFailure(kind: .detachedHead, summary: "You're not on a branch."))
        }
        guard let upstream = try await upstream() else {
            throw .refused(summary: "This branch has no upstream. Publish it or set an upstream first.")
        }
        if mode != .fastForwardOnly { _ = try context.requireIdentity() }
        let fetched = try await fetch(
            FetchRequest(remote: upstream.remote, prune: false), context: context, progress: progress)
        if fetched.cancelled { return PullOutcome(fetch: fetched, integration: nil) }
        let integration = try await performExclusive(
            "Integrate \(upstream.shortName)", invalidating: Set(InvalidationKind.allCases)
        ) { () throws(GitCoreError) -> IntegrationOutcome in
            try await Self.uncancellable { () throws(GitCoreError) -> IntegrationOutcome in
                try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
                // Between the fetch and now, Terminal may have switched branches or changed the upstream.
                let now = try await engine.run(
                    GitCommand(
                        ["symbolic-ref", "-q", "--short", "HEAD"], in: topLevel, kind: .read, acceptedExitCodes: [0, 1])
                ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                let upstreamNow = try await engine.run(
                    GitCommand(
                        ["rev-parse", "--symbolic-full-name", "\(branch)@{upstream}"], in: topLevel, kind: .read,
                        acceptedExitCodes: [0, 128])
                ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard now == branch, upstreamNow == upstream.ref else {
                    throw .staleSnapshot(
                        summary:
                            "The branch or its upstream changed while fetching. Nothing was integrated — review and pull again."
                    )
                }
                let counts = try await Self.aheadBehind(engine: engine, in: topLevel, "HEAD", upstream.ref)
                if counts.behind == 0 { return .upToDate }
                let head = try await Self.readHead(engine: engine, in: topLevel) ?? ""
                switch mode {
                case .fastForwardOnly:
                    if counts.ahead > 0 { return .notFastForward(ahead: counts.ahead, behind: counts.behind) }
                    let command = GitEnvironment.integrationCommand(
                        ["merge", "--ff-only", "--no-edit", upstream.ref], in: topLevel, identity: nil, use: .none)
                    _ = try await Self.runClassified(command, engine: engine, gitDirectory: gitDirectory)
                    return .fastForwarded(from: head, to: try await Self.readHead(engine: engine, in: topLevel) ?? "")
                case .merge:
                    return try await Self.runIntegration(
                        ["merge", "--no-edit", "--ff", upstream.ref], identity: context.identity,
                        use: .authorAndCommitter, engine: engine, topLevel: topLevel, gitDirectory: gitDirectory,
                        headBefore: head, ahead: counts.ahead)
                case .rebase:
                    return try await Self.runIntegration(
                        ["rebase", "--no-autostash", "--no-autosquash", "--no-update-refs", upstream.ref],
                        identity: context.identity, use: .committerOnly, engine: engine, topLevel: topLevel,
                        gitDirectory: gitDirectory, headBefore: head, ahead: counts.ahead, isRebase: true)
                }
            }
        }
        return PullOutcome(fetch: fetched, integration: integration)
    }

    /// Runs merge/rebase/cherry-pick/revert and interprets the result: conflicts (unmerged entries) are an
    /// outcome, not an error.
    static func runIntegration(
        _ arguments: [String], identity: IdentitySnapshot?, use: IdentityUse, engine: GitEngine, topLevel: String,
        gitDirectory: String, headBefore: String, ahead: Int = 0, isRebase: Bool = false
    ) async throws(GitCoreError) -> IntegrationOutcome {
        let command = GitEnvironment.integrationCommand(
            arguments, in: topLevel, identity: identity, use: use, acceptedExitCodes: [0, 1])
        let output: ProcessOutput
        do {
            output = try await engine.run(command)
        } catch .processFailed(let code, _, let detail) {
            let failure = GitErrorClassifier.classify(exitCode: code, stderr: detail)
            let unmerged = try await unmergedPathList(engine: engine, in: topLevel)
            if !unmerged.isEmpty { return .stoppedWithConflicts(paths: unmerged) }
            if failure.kind == .indexLocked { throw .indexLocked(path: gitDirectory + "/index.lock") }
            throw .failed(failure)
        }
        let unmerged = try await unmergedPathList(engine: engine, in: topLevel)
        if !unmerged.isEmpty { return .stoppedWithConflicts(paths: unmerged) }
        if output.exitCode != 0 {
            let state = OperationStateDetector.detect(gitDirectory: gitDirectory)
            let text = (output.stdoutText + "\n" + output.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            if state != .none {
                return .stoppedInProgress(message: Redaction.redact(text))
            }
            throw .failed(GitErrorClassifier.classify(exitCode: output.exitCode, stderr: text))
        }
        let head = try await readHead(engine: engine, in: topLevel) ?? ""
        if head == headBefore { return .upToDate }
        if isRebase { return .rebased(count: ahead) }
        let parents =
            try await engine.run(
                GitCommand(["rev-list", "--parents", "-n", "1", head, "--"], in: topLevel, kind: .read)
            ).stdoutText.split(separator: " ").count - 1
        if parents > 1 { return .merged(commit: head) }
        let isDescendant = try await engine.run(
            GitCommand(
                ["merge-base", "--is-ancestor", headBefore, head], in: topLevel, kind: .read,
                acceptedExitCodes: [0, 1, 128]))
        if arguments.first == "merge", isDescendant.exitCode == 0 { return .fastForwarded(from: headBefore, to: head) }
        return .committed(commit: head)
    }

    static func unmergedPathList(engine: GitEngine, in directory: String) async throws(GitCoreError) -> [String] {
        let output = try await engine.run(
            GitCommand(["ls-files", "-u", "-z"], in: directory, kind: .read, stdoutLimit: 64 * 1024 * 1024))
        var paths: [String] = []
        var seen = Set<String>()
        for record in output.stdout.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }
}

// MARK: - Push

public struct PushRequest: Sendable, Hashable {
    public var remote: String
    public var localBranch: String
    public var remoteBranch: String
    /// `-u`: track the remote branch (publish).
    public var setUpstream: Bool

    public init(remote: String, localBranch: String, remoteBranch: String? = nil, setUpstream: Bool = false) {
        self.remote = remote
        self.localBranch = localBranch
        self.remoteBranch = remoteBranch ?? localBranch
        self.setUpstream = setUpstream
    }
}

/// One ref line of `git push --porcelain`.
public struct PushRefResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case fastForward, forced, new, deleted, upToDate, rejected, remoteRejected, failed
    }

    public var status: Status
    public var source: String
    public var destination: String
    /// `non-fast-forward`, `fetch first`, `stale info`, `pre-receive hook declined`, …
    public var reason: String?
}

public struct PushOutcome: Sendable, Equatable {
    public enum Rejection: Sendable, Equatable {
        /// The remote has commits this branch lacks.
        case nonFastForward
        /// Force-with-lease: the remote moved since the expected value.
        case staleLease
        /// A server-side hook (protected branch, policy) declined; see `remoteLines`.
        case remoteHook(reason: String)
        case other(reason: String)
    }

    public var refs: [PushRefResult]
    public var remoteLines: [String]
    public var rejection: Rejection?
    /// The push was cancelled; `refs` describes the remote's actual state read back afterwards.
    public var cancelled: Bool

    public var succeeded: Bool { rejection == nil && !cancelled }
}

/// Parses `git push --porcelain` stdout: `<flag>\t<from>:<to>\t<summary>` lines between `To <url>` and
/// `Done`.
public enum PushPorcelainParser {
    public static func parse(_ text: String) -> [PushRefResult] {
        var results: [PushRefResult] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let flag = fields[0].first, fields[0].count == 1 else { continue }
            let refs = fields[1].split(separator: ":", maxSplits: 1).map(String.init)
            let summary = String(fields[2])
            var reason: String?
            if let open = summary.lastIndex(of: "("), let close = summary.lastIndex(of: ")"), open < close {
                reason = String(summary[summary.index(after: open)..<close])
            }
            let status: PushRefResult.Status
            switch flag {
            case " ": status = .fastForward
            case "+": status = .forced
            case "*": status = .new
            case "-": status = .deleted
            case "=": status = .upToDate
            case "!": status = summary.contains("remote rejected") ? .remoteRejected : .rejected
            default: status = .failed
            }
            results.append(
                PushRefResult(
                    status: status, source: refs.first ?? "", destination: refs.count > 1 ? refs[1] : "",
                    reason: reason))
        }
        return results
    }

    static func rejection(_ refs: [PushRefResult]) -> PushOutcome.Rejection? {
        guard let bad = refs.first(where: { [.rejected, .remoteRejected, .failed].contains($0.status) }) else {
            return nil
        }
        let reason = bad.reason ?? "rejected"
        if bad.status == .remoteRejected { return .remoteHook(reason: reason) }
        if reason.contains("stale info") { return .staleLease }
        if reason.contains("non-fast-forward") || reason.contains("fetch first") { return .nonFastForward }
        return .other(reason: reason)
    }
}

extension RepositoryHandle {
    /// `git push --progress --porcelain [-u] <remote> refs/heads/<local>:refs/heads/<remote>` (design §4.6).
    public func push(
        _ request: PushRequest, context: ExecContext = .anonymous,
        progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> PushOutcome {
        try await push(request, lease: nil, context: context, progress: progress)
    }

    /// Force push with lease (ADR-0030): `--force-with-lease=<ref>:<expected> --force-if-includes`, never
    /// plain `--force`. Only with a confirmed token naming the same remote, ref and expected OID.
    public func forcePushWithLease(
        _ request: PushRequest, expected: String, token: ConfirmationToken, context: ExecContext = .anonymous,
        progress: AsyncStream<OperationProgress>.Continuation? = nil
    ) async throws(GitCoreError) -> PushOutcome {
        try Self.requireObjectID(expected)
        try token.verify(.forcePush(remote: request.remote, remoteRef: request.remoteBranch, expected: expected))
        return try await push(request, lease: expected, context: context, progress: progress)
    }

    private func push(
        _ request: PushRequest, lease: String?, context: ExecContext,
        progress: AsyncStream<OperationProgress>.Continuation?
    ) async throws(GitCoreError) -> PushOutcome {
        let directory = workingDirectory
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try Self.requireSafeName(request.remote, what: "remote")
        try await requireValidBranchRef(request.localBranch)
        try await requireValidBranchRef(request.remoteBranch)
        guard let remoteInfo = try await remotes().first(where: { $0.name == request.remote }) else {
            throw .refused(summary: "There's no remote named “\(request.remote)”.")
        }
        let urls = remoteInfo.pushURLs
        let destination = "refs/heads/\(request.remoteBranch)"
        return try await performExclusive(
            "Push \(request.localBranch) to \(request.remote)", invalidating: [.refs, .config]
        ) { () throws(GitCoreError) -> PushOutcome in
            var arguments = ["push", "--progress", "--porcelain"]
            if request.setUpstream { arguments.append("--set-upstream") }
            if let lease {
                arguments += ["--force-with-lease=\(destination):\(lease)", "--force-if-includes"]
            }
            arguments += [request.remote, "refs/heads/\(request.localBranch):\(destination)"]
            let lease = try await context.prepareAccess(for: urls, purpose: .push)
            defer { lease?.release() }
            var command = GitEnvironment.remoteCommand(
                arguments, in: directory, context: context, access: lease?.access, acceptedExitCodes: [0, 1])
            let sink = ProgressSink(progress)
            command.stderrObserver = sink.observer
            let output: ProcessOutput
            do throws(GitCoreError) {
                output = try await engine.run(command)
            } catch .cancelled {
                // The remote may already have the new value: read back what it says now.
                let actual = try await Self.uncancellable { () throws(GitCoreError) -> String? in
                    let remote = try await engine.run(
                        GitEnvironment.remoteCommand(
                            ["ls-remote", "--refs", request.remote, destination], in: directory, context: context,
                            access: lease?.access))
                    return remote.stdoutText.split(separator: "\t").first.map(String.init)
                }
                let local = try? await Self.uncancellable { () throws(GitCoreError) -> String? in
                    try await Self.readRef(engine: engine, in: directory, "refs/heads/\(request.localBranch)")
                }
                let pushed = actual != nil && actual == local ?? nil
                return PushOutcome(
                    refs: [
                        PushRefResult(
                            status: pushed ? .fastForward : .failed, source: request.localBranch,
                            destination: destination, reason: pushed ? "the remote has the new commits" : nil)
                    ], remoteLines: sink.remoteLines, rejection: nil, cancelled: true)
            } catch .processFailed(let code, _, let detail) {
                let failure = GitErrorClassifier.classify(exitCode: code, stderr: detail)
                if failure.kind == .indexLocked { throw .indexLocked(path: gitDirectory + "/index.lock") }
                throw .failed(failure)
            }
            let refs = PushPorcelainParser.parse(output.stdoutText)
            if refs.isEmpty, output.exitCode != 0 {
                throw .failed(GitErrorClassifier.classify(exitCode: output.exitCode, stderr: output.stderrText))
            }
            let remoteLines =
                sink.remoteLines.isEmpty
                ? output.stderrText.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("remote:") }.map {
                    Redaction.redact($0.dropFirst(7).trimmingCharacters(in: .whitespaces))
                } : sink.remoteLines
            return PushOutcome(
                refs: refs, remoteLines: remoteLines, rejection: PushPorcelainParser.rejection(refs), cancelled: false)
        }
    }

    /// `git check-ref-format refs/heads/<name>`: the name can be spliced into a refspec safely (no `:`, spaces,
    /// `..`, leading `-`).
    nonisolated func requireValidBranchRef(_ name: String) async throws(GitCoreError) {
        try Self.requireSafeName(name, what: "branch")
        let output = try await gitEngine.run(
            GitCommand(
                ["check-ref-format", "refs/heads/\(name)"], in: workingDirectory, kind: .read,
                acceptedExitCodes: [0, 1, 128]))
        guard output.exitCode == 0 else {
            throw .failed(ClassifiedFailure(kind: .invalidName, summary: "“\(name)” isn't a valid branch name."))
        }
    }

    static func readRef(engine: GitEngine, in directory: String, _ ref: String) async throws(GitCoreError) -> String? {
        let output = try await engine.run(
            GitCommand(["rev-parse", "-q", "--verify", ref], in: directory, kind: .read, acceptedExitCodes: [0, 1]))
        let value = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.exitCode == 0 && !value.isEmpty ? value : nil
    }

    /// The remote-tracking value a force-with-lease would expect (`refs/remotes/<remote>/<branch>`).
    public nonisolated func remoteTrackingOID(remote: String, branch: String) async throws(GitCoreError) -> String? {
        try await Self.readRef(engine: gitEngine, in: workingDirectory, "refs/remotes/\(remote)/\(branch)")
    }

    /// Commits on `ref` that `base` lacks (`git log base..ref`), newest first, at most `limit`.
    public nonisolated func commits(in ref: String, notIn base: String?, limit: Int = 50) async throws(GitCoreError)
        -> [CommitSummary]
    {
        var arguments = ["log", "--format=%H%x00%s", "-n", "\(limit)", ref]
        if let base { arguments += ["--not", base] }
        arguments.append("--")
        let output = String(decoding: try await runRead(arguments, limit: 4 * 1024 * 1024), as: UTF8.self)
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return CommitSummary(oid: String(parts[0]), subject: String(parts[1]))
        }
    }
}
