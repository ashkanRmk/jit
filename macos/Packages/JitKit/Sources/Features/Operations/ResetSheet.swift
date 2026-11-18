import DesignSystem
import GitCore
import SwiftUI

struct ResetSheet: View {
    let controller: OperationsController
    let commit: String
    let mode: ResetMode
    @State private var model = ResetModel()
    @State private var generation = 0

    var body: some View {
        Group {
            if let preview = model.preview {
                let request = ResetModel.request(preview, stashFirst: model.stashFirst, context: controller.contextLine)
                ConfirmationSheet(
                    request: request, cancel: controller.cancelSheet,
                    confirm: { execute(preview, request: request) },
                    extra: AnyView(
                        ResetPreviewDetails(
                            preview: preview, stashFirst: $model.stashFirst,
                            identity: controller.identityLine, chooseProfile: controller.chooseProfile)),
                    isConfirmDisabled: controller.session.isBusy
                        || ResetModel.isBlocked(
                            preview, stashFirst: model.stashFirst, hasProfile: controller.hasProfile)
                )
            } else {
                SheetScaffold(title: "\(mode.title) Reset Preview", subtitle: String(commit.prefix(12))) {
                    if let error = model.error {
                        Text(error).typeStyle(.callout).foregroundStyle(.token(.statusDanger))
                    } else {
                        ProgressView("Reading files and history…")
                    }
                } buttons: {
                    Button("Cancel", action: controller.cancelSheet).keyboardShortcut(.defaultAction)
                    if model.error != nil { Button("Refresh Preview") { generation += 1 } }
                }
            }
        }
        .task(id: generation) {
            guard let repository = controller.session.repository else { return }
            await model.load(repository: repository, commit: commit, mode: mode)
        }
        .onExitCommand(perform: controller.cancelSheet)
    }

    private func execute(_ preview: ResetPreview, request: ConfirmationRequest) {
        guard !controller.session.isBusy,
            !ResetModel.isBlocked(preview, stashFirst: model.stashFirst, hasProfile: controller.hasProfile)
        else { return }
        let saving = model.stashFirst && preview.needsStash
        let context = controller.execContext
        let token = request.confirm()
        controller.cancelSheet()
        Task {
            if case .failure(let error) = await controller.session.reset(
                preview, stashFirst: saving, token: token, context: context)
            {
                controller.present(error, retry: { controller.confirmReset(to: commit, mode: mode.rawValue) })
            }
        }
    }
}

struct ResetPreviewDetails: View {
    let preview: ResetPreview
    @Binding var stashFirst: Bool
    let identity: String?
    var chooseProfile: () -> Void = {}
    @State private var contentHeight: CGFloat = Space.s6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                if preview.publishedCount > 0 {
                    warning(
                        "\(preview.publishedCount) removed commits are in remote-tracking history. A later push may require force-with-lease."
                    )
                }
                if preview.mode == .hard {
                    if preview.localChanges.contains(where: \.isSubmodule) {
                        warning(
                            "Submodule working files stay unchanged. Save those changes separately before using stash-first."
                        )
                    }
                    Text(
                        "\(preview.discardedPaths.count) tracked \(preview.discardedPaths.count == 1 ? "path" : "paths") with local changes"
                    )
                    .typeStyle(.callout).foregroundStyle(.token(.textPrimary))
                    if !preview.discardedPaths.isEmpty { PathList(paths: preview.discardedPaths) }
                    if preview.needsStash {
                        Toggle("Stash local changes first (includes untracked files)", isOn: $stashFirst)
                            .typeStyle(.callout)
                        if stashFirst {
                            Text(
                                "\(preview.localChanges.count) changed paths will be saved. If stash fails, reset will not run."
                            )
                            .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                            if let identity {
                                Text(identity).typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                            } else {
                                warning("Choose a profile to create the recovery stash.")
                                Button("Choose Profile…", action: chooseProfile)
                            }
                            if !preview.unsupportedStashPaths.isEmpty {
                                warning(
                                    "Save dirty submodules, nested repositories and special files separately before using stash-first."
                                )
                            }
                        } else {
                            warning(
                                "Tracked local changes will be permanently discarded. Untracked files remain unless they obstruct reset; obstructing paths are refused."
                            )
                        }
                    }
                }
                if !preview.obstructingPaths.isEmpty {
                    warning("Reset is blocked by local paths. Move these aside, then reopen the preview.")
                    PathList(paths: preview.obstructingPaths)
                }
                if preview.mode == .keep {
                    Text(
                        "Git refuses if local changes overlap files changed by the reset. Submodules are not reset recursively."
                    )
                    .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
        }
        .frame(height: min(contentHeight, 300))
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .typeStyle(.caption).foregroundStyle(.token(.statusWarning))
            .fixedSize(horizontal: false, vertical: true)
    }
}
