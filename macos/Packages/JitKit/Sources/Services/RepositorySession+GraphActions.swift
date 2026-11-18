import Foundation
import GitCore

extension RepositorySession {
    public func createTag(
        _ name: String, at commit: String, message: String?, context: ExecContext,
        expected: RepoStateToken?
    ) async -> Result<Void, PresentableError> {
        await perform(
            "Create tag \(name)", refresh: [.refs], summarize: { _ in OperationSummary("Created tag \(name).") }
        ) {
            handle, _ throws(GitCoreError) in
            try await handle.createTag(name, at: commit, message: message, context: context, expected: expected)
        }
    }

    public func pushTag(_ name: String, remote: String, context: ExecContext) async -> Result<Void, PresentableError> {
        await perform("Push tag \(name)", summarize: { _ in OperationSummary("Pushed \(name) to \(remote).") }) {
            handle, _ throws(GitCoreError) in try await handle.pushTag(name, remote: remote, context: context)
        }
    }

    public func pullBranch(
        _ name: String, remote: String? = nil, remoteBranch: String? = nil, context: ExecContext,
        expected: RepoStateToken?
    ) async -> Result<Void, PresentableError> {
        await perform("Pull \(name)", summarize: { _ in OperationSummary("Updated \(name).") }) {
            handle, _ throws(GitCoreError) in
            try await handle.pullBranch(
                name, remote: remote, remoteBranch: remoteBranch, context: context, expected: expected)
        }
    }

    public func fastForwardBranch(_ name: String, to commit: String, expected: RepoStateToken?) async -> Result<
        Void, PresentableError
    > {
        await perform("Fast-forward \(name)", summarize: { _ in OperationSummary("Fast-forwarded \(name).") }) {
            handle, _ throws(GitCoreError) in try await handle.fastForwardBranch(name, to: commit, expected: expected)
        }
    }

    public func createWorktree(at path: String, commit: String, expected: RepoStateToken?) async -> Result<
        Void, PresentableError
    > {
        await perform("Create worktree", summarize: { _ in OperationSummary("Created worktree at \(path).") }) {
            handle, _ throws(GitCoreError) in
            try await handle.createWorktree(at: path, commit: commit, expected: expected)
        }
    }

    public func reset(_ preview: ResetPreview, stashFirst: Bool, token: ConfirmationToken, context: ExecContext) async
        -> Result<ResetOutcome, PresentableError>
    {
        await perform(
            "Reset \(preview.mode.rawValue)",
            summarize: { outcome in
                var message =
                    "Reset to \(outcome.commit.prefix(12)). Previous HEAD: \(outcome.previousHead). Recover committed history from Reflog."
                if let stash = outcome.stashOID {
                    message += " Saved changes: \(stash). Restore from Stashes on the recovered branch."
                }
                return OperationSummary(message)
            }
        ) { handle, _ throws(GitCoreError) in
            try await handle.reset(preview, stashFirst: stashFirst, token: token, context: context)
        }
    }

}

extension RepositorySession {
    public func deleteLocalAndRemoteBranch(
        _ branch: String, remote: String, remoteBranch: String, remoteTip: String,
        token: ConfirmationToken, context: ExecContext, expected: RepoStateToken
    ) async -> Result<Void, PresentableError> {
        await perform(
            "Delete \(branch) and \(remote)/\(remoteBranch)",
            summarize: { _ in OperationSummary("Deleted local and remote branches.") }
        ) {
            handle, _ throws(GitCoreError) in
            try await handle.deleteLocalAndRemoteBranch(
                branch, remote: remote, remoteBranch: remoteBranch, remoteTip: remoteTip,
                token: token, context: context, expected: expected)
        }
    }
}
