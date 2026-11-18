import AppKit
import GitCore
import Services

extension OperationsController {
    func newTagAtHead() {
        guard !session.isBusy else { return }
        Task {
            guard let state = await session.captureState(), let head = state.head else { return }
            newTag(at: head, label: currentBranch ?? "HEAD")
        }
    }

    func manageTag(_ ref: GitRef) {
        guard ref.kind == .tag else { return }
        sheet = .tagDetails(ref)
    }

    func pushTag(_ tag: TagDetails, remote: String, expected: RepoStateToken) {
        guard !session.isBusy else { return }
        let context = execContext
        Task {
            if case .failure(let error) = await session.pushTag(
                tag.name, remote: remote, object: tag.objectOID, expected: expected, context: context)
            {
                present(error)
            }
        }
    }

    func deleteLocalTag(_ ref: GitRef) {
        guard !session.isBusy, let repository = session.repository else { return }
        Task {
            do throws(GitCoreError) {
                let tag = try await repository.tagDetails(
                    named: ref.shortName, object: ref.object.hex(refs?.format ?? .sha1))
                let expected = try await repository.captureState()
                confirmLocalTagDeletion(tag, expected: expected)
            } catch { present(PresentableError.make(error)) }
        }
    }

    func confirmLocalTagDeletion(_ tag: TagDetails, expected: RepoStateToken) {
        guard !session.isBusy else { return }
        let request = ConfirmationRequest(
            action: tag.deletionAction, title: "Delete local tag \(tag.name)?",
            context: contextLine,
            changes: "Remove this local tag. Its remote copies and working files are kept.",
            recoverability:
                "The exact tag object is recorded in Recovery Points. Restore it with Git before objects are pruned:",
            recoveryValue: tag.objectOID, verb: "Delete Local Tag")
        confirm(request) { [weak self] token in
            guard let self else { return }
            Task {
                if case .failure(let error) = await self.session.deleteTag(
                    tag, token: token, expected: expected)
                {
                    self.present(error)
                }
            }
        }
    }

}
