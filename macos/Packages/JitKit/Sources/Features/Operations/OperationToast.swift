import DesignSystem
import Services
import SwiftUI

struct OperationToast: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var failed = false
    var operationID: UUID? = nil
    var details: (() -> Void)?
}

extension OperationsController {
    func showToast(title: String, message: String, failed: Bool = false, error: PresentableError? = nil) {
        model.toast = OperationToast(
            title: title, message: message, failed: failed,
            operationID: session.operations.lastFinished?.id,
            details: error.map { error in { [weak self] in self?.sheet = .error(error) } })
    }
}

/// Window-wide feedback. Errors stay until dismissed; successes expire with a cancellable one-shot task.
struct OperationToasts: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var observedTabID: UUID?
    @State private var seenFinished = Set<UUID>()
    private var center: OperationCenter? { model.activeTab?.session?.operations }

    var body: some View {
        Group {
            if let toast = model.toast {
                HStack(alignment: .top, spacing: 0) {
                    Image(systemName: toast.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .symbolSize(IconSize.lg, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: Space.s10)
                        .frame(maxHeight: .infinity)
                        .background((toast.failed ? ColorToken.statusDanger : ColorToken.statusSuccess).color)
                    VStack(alignment: .leading, spacing: Space.s3) {
                        HStack(alignment: .top, spacing: Space.s4) {
                            Text(toast.title).typeStyle(.headline)
                            Spacer(minLength: 0)
                            Button {
                                model.toast = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss notification")
                            .accessibilityLabel("Dismiss notification")
                        }
                        Text(toast.message).typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                            .lineLimit(10)
                            .fixedSize(horizontal: false, vertical: true)
                        if let details = toast.details {
                            Button("Details and Recovery…") {
                                model.toast = nil
                                details()
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420)
                .background(ColorToken.surfaceRaised.color)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md).stroke(
                        ColorToken.borderSubtle.color, lineWidth: Border.hairline)
                )
                .id(toast.id)
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                .task(id: toast.id) {
                    guard !toast.failed else { return }
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, model.toast?.id == toast.id else { return }
                    model.toast = nil
                }
            }
        }
        .animation(reduceMotion ? nil : MotionToken.feedbackIn.animation, value: model.toast?.id)
        .onAppear { observeTab() }
        .onChange(of: model.activeTabID) { observeTab() }
        .onChange(of: center?.finishedCount) { _, _ in
            guard model.activeTabID == observedTabID, let record = center?.lastFinished,
                seenFinished.insert(record.id).inserted
            else { return }
            switch record.state {
            case .succeeded(let message):
                model.toast = OperationToast(
                    title: record.title + " — Succeeded", message: message, operationID: record.id)
                AccessibilityNotification.Announcement(record.title + ". " + message).post()
            case .failed(let error):
                if model.toast?.operationID != record.id {
                    model.toast = OperationToast(
                        title: record.title + " — Failed",
                        message: error.technicalDetail.flatMap { $0.isEmpty ? nil : $0 } ?? error.explanation,
                        failed: true, operationID: record.id)
                }
            case .needsAttention(let message):
                model.toast = OperationToast(
                    title: record.title + " — Needs Attention", message: message, failed: true, operationID: record.id)
            default: break
            }
        }
    }

    private func observeTab() {
        observedTabID = model.activeTabID
        seenFinished = Set(center?.records.filter { $0.state.isFinished }.map(\.id) ?? [])
    }

}
