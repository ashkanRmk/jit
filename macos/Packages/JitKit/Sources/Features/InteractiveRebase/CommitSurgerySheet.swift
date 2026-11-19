import DesignSystem
import GitCore
import SwiftUI

struct CommitSurgerySheet: View {
    let controller: OperationsController
    @State private var plan: CommitSurgeryPlan
    @State private var reviewing: Bool

    init(controller: OperationsController, plan: CommitSurgeryPlan) {
        self.controller = controller
        _plan = State(initialValue: plan)
        _reviewing = State(initialValue: plan.action == .drop)
    }

    var body: some View {
        Group {
            if reviewing {
                let request = plan.confirmation(context: controller.contextLine)
                ConfirmationSheet(
                    request: request, cancel: cancelReview,
                    confirm: {
                        controller.runCommitSurgery(plan, token: request.confirm())
                    }, extra: AnyView(reviewDetails), isConfirmDisabled: !canRun)
            } else {
                SheetScaffold(title: "Edit Commit Message", subtitle: controller.contextLine) {
                    target
                    PlainCodeEditor(text: $plan.message, accessibilityLabel: "Commit message")
                        .frame(height: CommitMessageMetrics.editorHeight)

                    if plan.publishedCount > 0 {
                        Label(
                            "This rewrites published history. A later push requires force-with-lease.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .typeStyle(.caption).foregroundStyle(.token(.statusWarning))
                    }
                    ForEach(plan.validationIssues, id: \.self) { issue in
                        Text(issue).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                    }
                } buttons: {
                    Button("Cancel", action: controller.cancelSheet).keyboardShortcut(.cancelAction)
                    Button("Review Message…") { reviewing = true }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canRun)
                }
            }
        }
        .accessibilityIdentifier("commit-surgery-sheet")
    }

    private var canRun: Bool {
        controller.historyEditUnavailableReason == nil && controller.hasProfile && plan.validationIssues.isEmpty
            && (plan.action == .drop || plan.message != plan.originalMessage)
    }

    private var reviewDetails: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            target
            if plan.action == .editMessage {
                Text("New message").typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                ScrollView {
                    Text(DisplayText.sanitize(plan.message, keepNewlines: true))
                        .typeStyle(.monoCaption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: CommitMessageMetrics.previewHeight)
            }
        }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("\(plan.commit.shortOID) · \(DisplayText.sanitize(plan.commit.subject))")
                .typeStyle(.callout).lineLimit(3)
            Text("Author: \(DisplayText.sanitize(plan.author))")
                .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                .lineLimit(2).truncationMode(.middle)
            Text("\(plan.affectedCount) \(plan.affectedCount == 1 ? "commit" : "commits") affected")
                .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
            IdentityLine(controller: controller)
        }
    }

    private func cancelReview() {
        if plan.action == .drop { controller.cancelSheet() } else { reviewing = false }
    }
}
