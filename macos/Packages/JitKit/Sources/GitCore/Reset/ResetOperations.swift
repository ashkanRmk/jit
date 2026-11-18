import Foundation

extension RepositoryHandle {
    /// One writer covers validation, optional stash, reset and the recovery journal snapshot.
    public func reset(
        _ preview: ResetPreview, stashFirst: Bool = false, token: ConfirmationToken,
        context: ExecContext = .anonymous
    ) async throws(GitCoreError) -> ResetOutcome {
        try token.verify(preview.confirmationAction(stashFirst: stashFirst))
        guard !stashFirst || preview.mode == .hard else {
            throw .refused(summary: "Stash-first is only available for hard reset.")
        }
        let root = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        return try await performExclusive(
            "Reset \(preview.mode.rawValue)", invalidating: Set(InvalidationKind.allCases)
        ) {
            () throws(GitCoreError) -> ResetOutcome in
            let (current, _) = try await self.resetSnapshot(mode: preview.mode)
            guard current == preview.snapshot else {
                throw .staleSnapshot(
                    summary: "The repository changed. Refresh the reset preview before confirming again.")
            }
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            if preview.mode == .hard || preview.mode == .keep {
                guard try await self.resetObstructions(target: preview.target, index: current.index).isEmpty else {
                    throw .refused(
                        summary:
                            "Untracked, ignored or directory paths obstruct this reset. Move them aside, then refresh the preview."
                    )
                }
            }
            let savesChanges = stashFirst && preview.needsStash
            guard !savesChanges || preview.unsupportedStashPaths.isEmpty else {
                throw .refused(
                    summary:
                        "Stash-first cannot safely save dirty submodules, nested repositories or special files. Save those changes separately."
                )
            }
            let identity = savesChanges ? try context.requireIdentity() : nil
            if Task.isCancelled { throw .cancelled }
            // Once stashing starts, cancellation cannot interrupt the stash/reset chain halfway through.
            return try await Self.uncancellable { () throws(GitCoreError) -> ResetOutcome in
                var stashOID: String?
                do throws(GitCoreError) {
                    if let identity {
                        try await Self.pushStash(
                            StashPushRequest(
                                message: "Jit: before hard reset to \(preview.target.prefix(12))",
                                includeUntracked: true),
                            identity: identity, engine: engine, topLevel: root, gitDirectory: gitDirectory)
                        stashOID = try await Self.readRef(engine: engine, in: root, "refs/stash")
                        guard let saved = stashOID, saved != current.references["refs/stash"] else {
                            throw .staleSnapshot(
                                summary: "The recovery stash changed or disappeared. Reset was not started.")
                        }
                        let (after, changes) = try await self.resetSnapshot(mode: preview.mode)
                        guard after.state.head == current.state.head, after.state.headRef == current.state.headRef,
                            after.references["refs/stash"] == saved,
                            after.references.filter({ $0.key != "refs/stash" })
                                == current.references.filter({ $0.key != "refs/stash" }),
                            changes.isEmpty
                        else {
                            throw .staleSnapshot(
                                summary: "The repository changed while stashing. Reset was not started.")
                        }
                        guard try await self.resetObstructions(target: preview.target, index: after.index).isEmpty
                        else {
                            throw .refused(summary: "A local path now obstructs reset. Reset was not started.")
                        }
                    }
                    _ = try await Self.runClassified(
                        GitCommand(
                            ["reset", "--\(preview.mode.rawValue)", "--no-recurse-submodules", preview.target, "--"],
                            in: root, kind: .write),
                        engine: engine, gitDirectory: gitDirectory)
                } catch {
                    // Even stash push can fail after creating its ref. Never pop it automatically.
                    if savesChanges && stashOID == nil {
                        let saved = try? await Self.readRef(engine: engine, in: root, "refs/stash")
                        if saved != current.references["refs/stash"] { stashOID = saved }
                    }
                    if let stashOID {
                        throw .refused(
                            summary:
                                "\(error.summary) Saved changes remain in stash \(stashOID). Use Stashes to restore them; reset did not complete."
                        )
                    }
                    throw error
                }
                return ResetOutcome(commit: preview.target, previousHead: preview.previousHead, stashOID: stashOID)
            }
        }
    }
}
