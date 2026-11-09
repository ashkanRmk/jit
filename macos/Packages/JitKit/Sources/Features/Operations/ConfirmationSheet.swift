import DesignSystem
import GitCore
import Services
import SwiftUI

/// The shared destructive confirmation (design §3.2): a standard window-modal sheet (system glass). The title
/// names action and object; then context, what changes, what may be lost and how to recover. Cancel is the
/// default (Return / Esc); the destructive button repeats the verb, has no shortcut, and for high-risk actions
/// enables only after 600 ms (no type-to-confirm).
struct ConfirmationSheet: View {
    let request: ConfirmationRequest
    let cancel: () -> Void
    let confirm: () -> Void
    var extra: AnyView?
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            HStack(alignment: .top, spacing: Space.s5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolSize(IconSize.lg)
                    .foregroundStyle(.token(.statusWarning))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(request.title)
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.context)
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textTertiary))
                }
            }
            Text(request.changes)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if !request.losses.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(Array(request.losses.enumerated()), id: \.offset) { index, line in
                        Text(DisplayText.sanitize(line))
                            .typeStyle(index == 0 ? .callout : .monoCaption)
                            .foregroundStyle(.token(index == 0 ? .textPrimary : .textSecondary))
                            .lineLimit(index == 0 ? 3 : 1)
                            .truncationMode(.tail)
                    }
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            }
            if let extra { extra }
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(request.recoverability)
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let value = request.recoveryValue {
                    Text(value.prefix(12))
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textPrimary))
                        .textSelection(.enabled)
                    Button("Copy") { Pasteboard.copy(value) }
                        .controlSize(.small)
                        .help("Copy the full SHA")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: confirm) {
                    Text(request.verb).foregroundStyle(.token(.statusDanger))
                }
                .disabled(request.isHighRisk && !armed)
                .help(request.isHighRisk && !armed ? "Take a moment to read what will happen." : request.verb)
            }
            .controlSize(.large)
        }
        .padding(Space.s8)
        .frame(width: 500)
        .onExitCommand(perform: cancel)
        .task {
            guard request.isHighRisk else { return }
            try? await Task.sleep(for: .milliseconds(600))
            armed = true
        }
    }
}

/// An explained error with recovery actions; Unknown errors show sanitized technical detail (design §4.11).
struct ErrorSheet: View {
    let error: PresentableError
    let perform: (RecoveryAction) -> Void
    let dismiss: () -> Void
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack(alignment: .top, spacing: Space.s5) {
                Image(
                    systemName: error.kind == .sshHostKeyChanged
                        ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.octagon.fill"
                )
                .symbolSize(IconSize.lg)
                .foregroundStyle(.token(.statusDanger))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(error.title)
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .fixedSize(horizontal: false, vertical: true)
                    if !error.explanation.isEmpty {
                        Text(error.explanation)
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !error.paths.isEmpty { PathList(paths: error.paths) }
            if !error.remoteLines.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("The server said:").typeStyle(.caption).foregroundStyle(.token(.textTertiary))
                    ForEach(Array(error.remoteLines.prefix(12).enumerated()), id: \.offset) { _, line in
                        Text(DisplayText.sanitize(line)).typeStyle(.monoCaption).foregroundStyle(.token(.textPrimary))
                    }
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            }
            if let detail = error.technicalDetail, !detail.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showsDetail) {
                    ScrollView {
                        Text(DisplayText.sanitize(detail, keepNewlines: true))
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(Space.s4)
                    .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .typeStyle(.callout)
            }
            HStack {
                Spacer()
                ForEach(error.actions, id: \.self) { action in
                    Button(Self.title(action)) { perform(action) }
                }
                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(Space.s8)
        .frame(width: 520)
        .onExitCommand(perform: dismiss)
    }

    static func title(_ action: RecoveryAction) -> String {
        switch action {
        case .retry: "Try Again"
        case .refresh: "Refresh"
        case .resolveConflicts: "Resolve Conflicts"
        case .abortOperation: "Abort…"
        case .chooseProfile: "Choose Profile…"
        case .stashAndRetry: "Show Changes"
        case .showWorkingDirectory: "Show Working Directory"
        case .openInTerminal: "Open in Terminal"
        case .revealInFinder: "Reveal in Finder"
        case .pullFastForward: "Pull"
        case .pullRebase: "Pull with Rebase"
        case .forcePushWithLease: "Force Push with Lease…"
        case .unsetUpstream: "Unset Upstream"
        case .publishBranch: "Publish Branch…"
        case .createBranch: "Create Branch Here…"
        }
    }
}

struct PathList: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(paths.prefix(10), id: \.self) { path in
                Text(DisplayText.sanitize(path))
                    .typeStyle(.monoCaption)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if paths.count > 10 {
                Text("and \(paths.count - 10) more")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}
