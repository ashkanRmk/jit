import DesignSystem
import GitCore
import Services
import SwiftUI

/// A focused workbench surface. Content remains opaque; the system confirmation is a separate sheet.
struct RebaseEditorView: View {
    @Bindable var model: RebaseEditorModel
    let controller: OperationsController
    var focusList: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.plan.publishedCount > 0 {
                Label(
                    "\(model.plan.publishedCount) commits are on remote-tracking branches. Others may have them. Rewriting requires a force push.",
                    systemImage: "exclamationmark.triangle"
                )
                .typeStyle(.callout)
                .foregroundStyle(.token(.statusWarning))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s5)
            }
            if !model.plan.reorderConflictPaths.isEmpty {
                Label(
                    "Reordered commits touch the same files: "
                        + model.plan.reorderConflictPaths.prefix(3).map { DisplayText.sanitize($0) }.joined(
                            separator: ", ")
                        + ". Conflicts may occur.", systemImage: "exclamationmark.triangle"
                )
                .typeStyle(.caption).foregroundStyle(.token(.statusWarning))
                .frame(maxWidth: .infinity, alignment: .leading).padding(Space.s5)
            }
            HSplitView {
                editor.frame(minWidth: 320)
                preview.frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
            }
            Divider()
            footer
        }
        .background(ColorToken.surfaceCanvas.color)
        .foregroundStyle(.token(.textPrimary))
        .accessibilityIdentifier("interactive-rebase-editor")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Label("Interactive Rebase", systemImage: "arrow.triangle.branch")
                    .typeStyle(.title)
                Spacer()
                Button {
                    model.moveSelection(by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Move selected commit earlier (⌥⌘↑)")
                .accessibilityLabel("Move selected commit earlier")
                .disabled(model.selectedIndex.map { $0 == 0 } ?? true)
                Button {
                    model.moveSelection(by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .help("Move selected commit later (⌥⌘↓)")
                .accessibilityLabel("Move selected commit later")
                .disabled(model.selectedIndex.map { $0 == model.plan.steps.count - 1 } ?? true)
            }
            Text(
                "\(model.plan.expected.branch ?? "HEAD") · after \(model.plan.base.prefix(7)) → onto \(model.plan.onto.prefix(7))"
            )
            .typeStyle(.monoCaption).foregroundStyle(.token(.textSecondary))
            Text("Oldest first. Drag to reorder, or use ⌥⌘↑ / ⌥⌘↓. Actions: p r e s f d.")
                .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
        }
        .padding(Space.s6)
    }

    private var editor: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.plan.steps.enumerated()), id: \.element.oid) { index, step in
                        row(step, at: index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.s4)
                            .contentShape(Rectangle())
                            .background(model.selection == step.oid ? ColorToken.accentMuted.color : Color.clear)
                            .overlay(alignment: .top) {
                                if model.dropTarget == step.oid {
                                    Rectangle().fill(ColorToken.accentTint.color).frame(height: 2)
                                }
                            }
                            .accessibilityAddTraits(model.selection == step.oid ? .isSelected : [])
                            .id(step.oid)
                        Divider()
                    }
                }
            }
            .onChange(of: model.selection) { _, oid in
                if let oid { proxy.scrollTo(oid) }
            }
            .onChange(of: model.plan.steps.map(\.oid)) { _, _ in
                if let oid = model.selection { proxy.scrollTo(oid) }
            }
        }
    }

    private func row(_ step: RebaseStep, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s4) {
                RebaseDragHandle(model: model, oid: step.oid, position: index + 1, focusList: focusList)
                    .frame(width: IconSize.md, height: IconSize.lg)
                Text("\(index + 1)").typeStyle(.monoCaption).foregroundStyle(.token(.textTertiary))
                Picker(
                    "Action",
                    selection: Binding(get: { model.plan.steps[index].action }, set: { model.setAction($0, at: index) })
                ) {
                    ForEach(RebaseAction.allCases, id: \.self) { action in Text(action.title).tag(action) }
                }
                .labelsHidden().frame(width: 100)
                .accessibilityLabel("Action for commit \(index + 1), \(model.commit(for: step)?.subject ?? step.oid)")
                HStack(spacing: Space.s4) {
                    Text(String(step.oid.prefix(7))).typeStyle(.monoCaption).foregroundStyle(.token(.textSecondary))
                    Text(DisplayText.sanitize(model.commit(for: step)?.subject ?? ""))
                        .typeStyle(.body).strikethrough(step.action == .drop).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selection = step.oid; focusList()
                }
            }
            HStack {
                Text(DisplayText.sanitize(model.commit(for: step)?.author ?? ""))
                Spacer()
                Text(model.commit(for: step)?.diffstat ?? "").lineLimit(1)
            }
            .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
            .contentShape(Rectangle())
            .onTapGesture {
                model.selection = step.oid; focusList()
            }
            if step.action == .reword || step.action == .squash {
                Text(step.action == .squash ? "Combined commit message" : "New commit message")
                    .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                TextEditor(text: $model.plan.steps[index].message)
                    .typeStyle(.monoCaption).frame(minHeight: 80, maxHeight: 140)
                    .autocorrectionDisabled()
                    .accessibilityLabel("\(step.action.title) message for \(step.oid.prefix(7))")
            }
            if step.action == .edit {
                Text("Git will pause here. Amend in Working Directory, then Continue.")
                    .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
            }
        }
        .padding(.vertical, Space.s3)
        .opacity(step.action == .drop ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Commit \(index + 1) of \(model.plan.steps.count), \(step.action.title), \(model.commit(for: step)?.subject ?? "")"
        )
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text("Resulting History").typeStyle(.headline)
                Text("\(model.plan.commits.count) → \(model.plan.resultCount) commits")
                    .typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                Label("Base · \(model.plan.onto.prefix(7))", systemImage: "circle")
                    .typeStyle(.monoCaption).foregroundStyle(.token(.textSecondary))
                ForEach(model.plan.resultCommits) { result in
                    HStack(alignment: .top, spacing: Space.s3) {
                        VStack(spacing: 0) {
                            Rectangle().fill(ColorToken.textTertiary.color).frame(width: 1, height: Space.s4)
                            Image(systemName: "circle.fill")
                                .foregroundStyle(.token(.accentTint))
                        }
                        VStack(alignment: .leading, spacing: Space.s2) {
                            Text(DisplayText.sanitize(String(result.message.split(separator: "\n").first ?? "")))
                                .typeStyle(.caption).lineLimit(3)
                            Text(
                                result.sourceOIDs.count > 1
                                    ? "Combines \(result.sourceOIDs.count) commits"
                                    : (result.stopsForEdit ? "Pauses for editing" : "Replay")
                            )
                            .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                        }
                    }
                }
                Divider()
                Text(
                    "New commit IDs are assigned when Git runs. Reordering can cause conflicts; the resolver opens if needed."
                )
                .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
                Text(
                    "Other branch pointers stay unchanged. Initially empty commits are kept; newly empty commits pause."
                )
                .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s5)
        }
        .background(ColorToken.surfaceSunken.color)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ForEach(model.plan.validationIssues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle")
                    .typeStyle(.caption).foregroundStyle(.token(.statusDanger))
            }
            if !trackedTreeIsClean {
                Text("Commit or stash your changes before running rebase.")
                    .typeStyle(.caption).foregroundStyle(.token(.statusWarning))
            }
            HStack {
                IdentityLine(controller: controller)
                Spacer()
                Button("Cancel") { controller.interactiveRebase = nil }
                Button("Review Rewrite…") { controller.reviewInteractiveRebase(model) }
                    .help("Review rewrite (⌘↩)")
                    .disabled(
                        !model.plan.validationIssues.isEmpty || !controller.hasProfile || !trackedTreeIsClean
                            || controller.session.isBusy)
            }
        }
        .padding(Space.s5)
    }

    private var trackedTreeIsClean: Bool {
        controller.session.status?.summary.map { $0.staged + $0.unstaged + $0.conflicted == 0 } ?? true
    }
}

struct InteractiveRebaseStartSheet: View {
    let controller: OperationsController
    @State private var base = "HEAD~1"
    @State private var onto = ""

    var body: some View {
        SheetScaffold(title: "Interactive Rebase", subtitle: controller.contextLine, width: 500) {
            Text("Replay commits after a base, oldest first. The base commit itself stays unchanged.")
                .typeStyle(.callout).foregroundStyle(.token(.textSecondary))
            TextField("Base commit or ref (excluded)", text: $base).textFieldStyle(.roundedBorder)
            TextField("Onto commit or ref (optional; defaults to base)", text: $onto).textFieldStyle(.roundedBorder)
            Text(
                "Use the graph’s ‘Interactive Rebase from Here…’ action to include a selected commit. Linear ranges up to 500 commits are supported."
            )
            .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
        } buttons: {
            Button("Cancel", action: controller.cancelSheet).keyboardShortcut(.cancelAction)
            Button("Prepare Plan") {
                controller.cancelSheet()
                controller.prepareInteractiveRebase(after: base, onto: onto.isEmpty ? nil : onto)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
