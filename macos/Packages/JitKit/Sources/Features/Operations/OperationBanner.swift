import DesignSystem
import GitCore
import Services
import SwiftUI

/// The repository operation banner (design §3.3): a floating tinted glass bar under the command bar while a
/// merge / rebase / cherry-pick / revert / am / bisect is in progress — whoever started it. Its buttons share
/// one glass container. Continue is disabled while unmerged paths remain.
struct OperationBanner: View {
    let controller: OperationsController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = controller.session.operationState
        if state != .clean {
            HStack(spacing: Space.s5) {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.token(.statusWarning))
                    .accessibilityHidden(true)
                Text(title(state))
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.s4)
                if state.isDrivable {
                    GlassControlGroup(spacing: Space.s3) {
                        if state.conflicted > 0 {
                            Button("Resolve Next") { controller.openNextConflict() }
                                .primaryGlassButton()
                        }
                        Button("Continue") { controller.continueOperation() }
                            .secondaryGlassButton()
                            .disabled(state.conflicted > 0)
                            .help(
                                state.conflicted > 0 ? "Resolve the conflicted files first." : "Continue the operation")
                        if state.canSkip {
                            Button("Skip Commit…") { controller.skip() }
                                .secondaryGlassButton()
                        }
                        Button("Abort…") { controller.abort() }
                            .secondaryGlassButton()
                    }
                } else {
                    Button("Open in Terminal") {
                        RepositoryActions.openInTerminal(controller.session.info?.topLevel ?? controller.session.path)
                    }
                    .secondaryGlassButton()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s3)
            .tintedGlassBar(in: Capsule(), tint: .statusWarning)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Operation in progress: \(title(state))")
            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        }
    }

    private func title(_ state: RepoOperationState) -> String {
        let branch = controller.currentBranch ?? "HEAD"
        func conflicts(_ count: Int) -> String {
            count == 0 ? "" : " · \(count) conflicted \(count == 1 ? "file" : "files")"
        }
        switch state {
        case .clean: return ""
        case .merging(let source, let count):
            return "Merging \(source.isEmpty ? "changes" : source) into \(branch)\(conflicts(count))"
        case .rebasing(let head, _, let step, let total, let stopped, let count):
            // The subject goes last so a narrow bar truncates it, never the step or conflict count.
            let commit = stopped.map { " · \($0.shortOID) \($0.subject)" } ?? ""
            return "Rebasing \(head) · commit \(step) of \(total)\(conflicts(count))\(commit)"
        case .cherryPicking(let commit, _, let count):
            return
                "Cherry-picking \(commit?.shortOID ?? "commits")\(conflicts(count))\(commit.map { " · \($0.subject)" } ?? "")"
        case .reverting(let commit, _, let count):
            return
                "Reverting \(commit?.shortOID ?? "commits")\(conflicts(count))\(commit.map { " · \($0.subject)" } ?? "")"
        case .sequencer(let count):
            return "Cherry-pick or revert in progress\(conflicts(count))"
        case .applyingMailbox:
            return "A git am session is in progress. Finish it in Terminal."
        case .bisecting:
            return "A git bisect session is in progress. Finish it in Terminal."
        }
    }
}
