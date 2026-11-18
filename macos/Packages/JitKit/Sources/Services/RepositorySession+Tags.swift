import GitCore

extension RepositorySession {
    public func deleteTag(_ tag: TagDetails, token: ConfirmationToken, expected: RepoStateToken?) async -> Result<
        TagDetails, PresentableError
    > {
        await perform(
            "Delete tag \(tag.name)", refresh: [.refs],
            summarize: { removed in
                OperationSummary(
                    "Deleted local tag \(removed.name). Saved tag object: \(removed.objectOID). Target: \(removed.targetOID). The remote was not changed."
                )
            }
        ) { handle, _ throws(GitCoreError) in try await handle.deleteTag(tag, token: token, expected: expected) }
    }

    public func deleteRemoteTag(_ preview: RemoteTagDeletionPreview, token: ConfirmationToken, context: ExecContext)
        async -> Result<Void, PresentableError>
    {
        await perform(
            "Delete tag \(preview.name) from \(preview.remote)", refresh: [.refs],
            summarize: { _ in
                OperationSummary(
                    "Deleted \(preview.name) from \(preview.remote). The local tag was kept. Previous remote object: \(preview.objectOID)."
                )
            }
        ) { handle, _ throws(GitCoreError) in try await handle.deleteRemoteTag(preview, token: token, context: context)
        }
    }
}
