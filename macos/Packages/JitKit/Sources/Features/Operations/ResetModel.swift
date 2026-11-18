import GitCore
import Observation

@MainActor @Observable
final class ResetModel {
    private(set) var preview: ResetPreview?
    private(set) var error: String?
    var stashFirst = true

    func load(repository: RepositoryHandle, commit: String, mode: ResetMode) async {
        preview = nil; error = nil
        do throws(GitCoreError) {
            let value = try await repository.resetPreview(to: commit, mode: mode)
            guard !Task.isCancelled else { return }
            preview = value
            stashFirst = value.needsStash
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.summary
        }
    }

    static func request(_ preview: ResetPreview, stashFirst: Bool, context: String) -> ConfirmationRequest {
        let count = preview.removedCount
        var losses = [
            "\(count) \(count == 1 ? "commit leaves" : "commits leave") this branch. \(preview.unreachableCount) \(preview.unreachableCount == 1 ? "commit would" : "commits would") be unreachable without a recovery stash."
        ]
        losses += preview.unreachableCommits.map { "\($0.shortOID) \($0.subject)" }
        let saving = stashFirst && preview.needsStash
        return ConfirmationRequest(
            action: preview.confirmationAction(stashFirst: saving),
            title: "\(preview.mode.title) reset \(preview.branch ?? "HEAD")?",
            context: "\(context) · to \(preview.target.prefix(12))",
            changes: preview.mode.explanation, losses: losses,
            recoverability: saving
                ? "Previous HEAD is saved in Reflog. Local changes, including untracked files, will be saved in Stashes; restore them on the recovered branch."
                : preview.mode == .hard
                    ? "Previous HEAD is saved in Reflog. Discarded local changes cannot be recovered by Git."
                    : "Recover committed history by creating a branch from the previous HEAD in Reflog.",
            recoveryValue: preview.previousHead,
            verb: saving ? "Stash and Hard Reset" : "\(preview.mode.title) Reset", isHighRisk: preview.mode == .hard)
    }

    static func isBlocked(_ preview: ResetPreview, stashFirst: Bool, hasProfile: Bool) -> Bool {
        !preview.obstructingPaths.isEmpty
            || stashFirst && preview.needsStash && (!hasProfile || !preview.unsupportedStashPaths.isEmpty)
    }
}
