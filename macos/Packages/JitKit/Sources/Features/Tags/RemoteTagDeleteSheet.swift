import DesignSystem
import GitCore
import SwiftUI

struct RemoteTagDeleteSheet: View {
    let controller: OperationsController
    let name: String
    let remote: String
    @State private var preview: RemoteTagDeletionPreview?
    @State private var error: String?
    @State private var generation = 0

    static func request(_ preview: RemoteTagDeletionPreview, context: String) -> ConfirmationRequest {
        var losses = ["Deletion is refused if the remote tag changed after this preview."]
        if let local = preview.localObjectOID {
            if local != preview.objectOID {
                losses.append("The remote tag points to a different object than the local tag.")
            }
        } else {
            losses.append("There is no local tag to use for recovery.")
        }
        return ConfirmationRequest(
            action: preview.confirmationAction, title: "Delete tag \(preview.name) from \(preview.remote)?",
            context: context,
            changes:
                "Delete this tag at \(DisplayText.sanitize(preview.maskedDestination)) for everyone who uses it. The local tag is kept.",
            losses: losses,
            recoverability: "Restore only if this tag object is still available in a local copy:",
            recoveryValue: preview.objectOID, verb: "Delete Remote Tag", isHighRisk: true)
    }

    var body: some View {
        Group {
            if let preview {
                let request = Self.request(preview, context: controller.contextLine)
                ConfirmationSheet(
                    request: request, cancel: controller.cancelSheet,
                    confirm: {
                        guard !controller.session.isBusy else { return }
                        let token = request.confirm(); let context = controller.execContext
                        controller.cancelSheet()
                        Task {
                            if case .failure(let error) = await controller.session.deleteRemoteTag(
                                preview, token: token, context: context)
                            {
                                controller.present(error)
                            }
                        }
                    }, isConfirmDisabled: controller.session.isBusy)
            } else {
                SheetScaffold(title: "Delete Remote Tag", subtitle: "\(remote) · \(name)") {
                    if let error {
                        Text(error).typeStyle(.callout).foregroundStyle(.token(.statusDanger))
                    } else {
                        ProgressView("Reading the tag at the push destination…")
                    }
                } buttons: {
                    Button("Cancel", action: controller.cancelSheet).keyboardShortcut(.defaultAction)
                    if error != nil { Button("Refresh Preview") { generation += 1 } }
                }
            }
        }
        .task(id: generation) {
            error = nil; preview = nil
            guard let repository = controller.session.repository else { return }
            do throws(GitCoreError) {
                let value = try await repository.remoteTagDeletionPreview(
                    named: name, remote: remote, context: controller.execContext)
                guard !Task.isCancelled else { return }
                preview = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.summary
            }
        }
        .onExitCommand(perform: controller.cancelSheet)
    }
}
