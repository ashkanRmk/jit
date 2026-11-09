import DesignSystem
import GitCore
import Services
import SwiftUI

/// The toolbar's activity item content (design §3.1): a standard toolbar item (system glass). Running: a ring
/// (determinate when Git reports a percentage) and a one-line label; just finished: a one-shot checkmark;
/// otherwise a quiet clock glyph. Nothing animates while idle.
struct ActivityToolbarView: View {
    let model: AppModel
    let toggle: () -> Void
    @State private var flash = false
    @State private var lastFinished = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var center: OperationCenter? { model.activeTab?.session?.operations }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.s3) {
                if let center, let running = center.current {
                    if let fraction = running.progress?.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(label(running))
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textSecondary))
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                } else if flash, let last = center?.lastFinished {
                    Image(systemName: icon(last.state))
                        .foregroundStyle(.token(color(last.state)))
                        .transition(.opacity)
                } else {
                    Image(systemName: failedRecently ? "exclamationmark.circle" : "clock.arrow.circlepath")
                        .foregroundStyle(.token(failedRecently ? .statusDanger : .textSecondary))
                }
            }
            .padding(.horizontal, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Activity (⌥⌘A)")
        .accessibilityLabel("Activity")
        .accessibilityValue(accessibilityValue)
        .onChange(of: center?.finishedCount ?? 0) { _, count in
            guard count != lastFinished else { return }
            lastFinished = count
            // One-shot checkmark: feedback-in, 900 ms hold, feedback-out — no repeating animation.
            withAnimation(reduceMotion ? nil : MotionToken.feedbackIn.animation) { flash = true }
            Task {
                try? await Task.sleep(for: .milliseconds(1080))
                withAnimation(reduceMotion ? nil : MotionToken.feedbackOut.animation) { flash = false }
            }
            if let last = center?.lastFinished, case .failed(let error) = last.state {
                AccessibilityNotification.Announcement("\(last.title) failed: \(error.title)").post()
            }
        }
    }

    private var failedRecently: Bool {
        if case .failed = center?.lastFinished?.state { return true }
        return false
    }

    private func label(_ record: OperationRecord) -> String {
        if let waiting = record.waitingFor { return "Waiting for “\(waiting)”…" }
        if let progress = record.progress {
            return "\(record.title) — \(progress.percent.map { "\($0)%" } ?? progress.phase)"
        }
        return record.title
    }

    private var accessibilityValue: String {
        guard let center else { return "No operations" }
        if let running = center.current {
            return running.progress?.percent.map { "\(running.title), \($0) percent" } ?? "\(running.title), running"
        }
        return center.lastFinished.map { "\($0.title): \(ActivityRow.outcome($0.state))" } ?? "No operations"
    }

    private func icon(_ state: OperationRecord.State) -> String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .running: "clock"
        }
    }

    private func color(_ state: OperationRecord.State) -> ColorToken {
        switch state {
        case .succeeded: .statusSuccess
        case .failed: .statusDanger
        case .needsAttention: .statusWarning
        default: .textSecondary
        }
    }
}

/// The activity popover: current and last 20 operations of the repository (in memory only).
struct ActivityPopover: View {
    let center: OperationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Activity").typeStyle(.headline)
                Spacer()
                if center.records.contains(where: { $0.state.isFinished }) {
                    Button("Clear") { center.clearHistory() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if center.records.isEmpty {
                Text("No operations yet in this session.")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ForEach(center.records) { record in
                            ActivityRow(record: record) { center.cancel(record.id) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(Space.s6)
        .frame(width: 380)
    }
}

struct ActivityRow: View {
    let record: OperationRecord
    let cancel: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: symbol)
                    .foregroundStyle(.token(tint))
                    .frame(width: IconSize.md)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(record.title)
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textPrimary))
                    Text(subtitle)
                        .typeStyle(.caption)
                        .foregroundStyle(.token(isFailure ? .statusDanger : .textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s3)
                if record.state == .running, record.cancellation != .notCancellable {
                    Button("Cancel", action: cancel)
                        .controlSize(.small)
                        .help(
                            record.cancellation == .cancellableWithWarning
                                ? "The remote may already have been updated; Jit checks and reports." : "Cancel")
                } else if let duration = record.duration {
                    Text(Self.format(duration))
                        .typeStyle(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.token(.textTertiary))
                }
            }
            if case .running = record.state, let fraction = record.progress?.fraction {
                ProgressView(value: fraction).controlSize(.small)
            }
            if case .failed(let error) = record.state {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        if !error.explanation.isEmpty {
                            Text(error.explanation).typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                        }
                        if let detail = error.technicalDetail {
                            Text(DisplayText.sanitize(detail, keepNewlines: true))
                                .typeStyle(.monoCaption)
                                .foregroundStyle(.token(.textSecondary))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Details").typeStyle(.caption)
                }
            }
        }
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        if case .failed = record.state { return true }
        return false
    }

    private var subtitle: String {
        if let waiting = record.waitingFor, record.state == .running { return "Waiting for “\(waiting)”…" }
        if record.state == .running { return record.progress?.summary ?? "Running…" }
        return Self.outcome(record.state)
    }

    static func outcome(_ state: OperationRecord.State) -> String {
        switch state {
        case .running: "Running…"
        case .succeeded(let message): message
        case .failed(let error): error.title
        case .cancelled(let message): message
        case .needsAttention(let message): message
        }
    }

    private var symbol: String {
        switch record.state {
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "minus.circle"
        case .needsAttention: "exclamationmark.triangle"
        }
    }

    private var tint: ColorToken {
        switch record.state {
        case .running: .accentBase
        case .succeeded: .statusSuccess
        case .failed: .statusDanger
        case .cancelled: .textTertiary
        case .needsAttention: .statusWarning
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "<1 s" : seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}
