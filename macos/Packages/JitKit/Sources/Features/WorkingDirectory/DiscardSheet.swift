import DesignSystem
import GitCore
import SwiftUI

/// Discard confirmation (design §3.2): says exactly what changes, what is lost and how to get it back.
/// Cancel is the default button (Return, Esc); Discard is destructive, never default, no shortcut.
struct DiscardSheet: View {
    let request: WorkingDirectoryModel.DiscardRequest
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            HStack(alignment: .top, spacing: Space.s5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolSize(IconSize.lg)
                    .foregroundStyle(.token(.statusWarning))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(title)
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(request.repository)\(request.branch.map { " · \($0)" } ?? "")")
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                }
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                ForEach(explanation, id: \.self) { line in
                    Label {
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill").symbolSize(4)
                    }
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                }
            }
            if request.files.count == 1, let preview = request.preview {
                PreviewBox(preview: preview)
            } else if request.files.count > 1 {
                FileListBox(files: request.files)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: confirm) {
                    Text("Discard").foregroundStyle(.token(.statusDanger))
                }
                .help("Discard the working-tree changes")
            }
            .controlSize(.large)
        }
        .padding(Space.s8)
        .frame(width: 480)
        .onExitCommand(perform: cancel)
    }

    private var title: String {
        if request.files.count == 1, let file = request.files.first {
            return file.change == .untracked
                ? "Move “\(DisplayText.sanitize(file.name))” to the Trash?"
                : "Discard changes to “\(DisplayText.sanitize(file.path))”?"
        }
        return "Discard changes to \(request.files.count) files?"
    }

    private var explanation: [String] {
        var lines: [String] = []
        if request.trackedCount > 0 {
            lines.append("Only the working tree changes. Staged changes are kept.")
            if request.files.count == 1, let preview = request.preview, request.files[0].change != .deleted {
                if preview.isBinary {
                    lines.append("The binary file returns to its staged version.")
                } else {
                    var parts: [String] = []
                    let lost = preview.removedCount
                    let back = preview.restoredCount
                    if lost > 0 { parts.append("\(lost) new \(lost == 1 ? "line is" : "lines are") lost") }
                    if back > 0 { parts.append("\(back) deleted \(back == 1 ? "line comes" : "lines come") back") }
                    if !parts.isEmpty { lines.append(parts.joined(separator: "; ") + ".") }
                }
            } else if request.files.count == 1 {
                lines.append("The deleted file comes back; nothing is lost.")
            }
            lines.append("A copy is kept in Jit’s recovery folder for 7 days (Repository ▸ Recently Discarded).")
        }
        if request.untrackedCount > 0 {
            lines.append(
                request.untrackedCount == 1 && request.files.count == 1
                    ? "The untracked \(request.files[0].isDirectory ? "folder" : "file") is moved to the Trash."
                    : "\(request.untrackedCount) untracked \(request.untrackedCount == 1 ? "item is" : "items are") moved to the Trash."
            )
        }
        return lines
    }
}

private struct PreviewBox: View {
    let preview: DiscardPreview

    var body: some View {
        if !preview.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: Space.s3) {
                        Text(line.kind == .removed ? "−" : "+")
                            .foregroundStyle(.token(line.kind == .removed ? .diffDeleteMark : .diffAddMark))
                            .frame(width: 10)
                        Text(DisplayText.sanitize(line.text))
                            .foregroundStyle(.token(.textPrimary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .typeStyle(.monoCaption)
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, 1)
                    .background((line.kind == .removed ? ColorToken.diffDeleteBackground : .diffAddBackground).color)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(line.kind == .removed ? "Removed" : "Restored"): \(line.text)")
                }
                if preview.isTruncated {
                    Text("…")
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textTertiary))
                        .padding(.horizontal, Space.s4)
                }
            }
            .padding(.vertical, Space.s3)
            .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview of the discarded lines")
        }
    }
}

private struct FileListBox: View {
    let files: [WDFile]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(files.prefix(8)) { file in
                Text(DisplayText.sanitize(file.path))
                    .typeStyle(.monoCaption)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if files.count > 8 {
                Text("and \(files.count - 8) more")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorToken.surfaceSunken.color, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}
