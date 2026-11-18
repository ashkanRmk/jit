import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// An opaque workbench mode. SwiftUI's native List recycles rows and handles arrow-key selection.
struct ReflogView: View {
    @Bindable var model: ReflogModel
    let operations: OperationsController
    var showInGraph: (ReflogRow) -> Void
    var compareWithCurrent: (ObjectID) -> Void
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            if let error = model.error {
                HStack(spacing: Space.s3) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).typeStyle(.callout)
                    Spacer(minLength: 0)
                    Button("Refresh") { model.reload() }
                }
                .foregroundStyle(.token(.statusWarning))
                .padding(Space.s4)
            }
            if model.isScanning { scanProgress }
            if model.rows.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    ForEach(model.rows) { row in
                        rowView(row).tag(row.id)
                            .contextMenu { actions(for: row).disabled(model.session.isBusy) }
                    }
                }
                .focused($listFocused)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(model.mode.rawValue)
                .accessibilityIdentifier("reflog.entries")
            }
            Divider()
            footer
        }
        .background(ColorToken.surfaceCanvas.color)
        .onExitCommand { model.close() }
        .onChange(of: model.isOpen) { _, open in listFocused = open }
        .onAppear { listFocused = model.isOpen }
        .onChange(of: model.ref) {
            model.mode = .reflog; model.reload()
        }
        .onChange(of: model.mode) {
            model.selection = nil; model.clearError()
        }
        .onChange(of: model.session.isBusy) { wasBusy, busy in
            if wasBusy && !busy && !model.isScanning && model.mode == .reflog { model.reload() }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.token(.textSecondary))
            Text("Reflog").typeStyle(.headline)
            Spacer(minLength: Space.s2)
            Button("Close", systemImage: "xmark") { model.close() }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("Close Reflog (Esc)")
                .accessibilityIdentifier("reflog.close")
        }
        .padding(Space.s5)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Picker("Reference", selection: $model.ref) {
                    Text("HEAD").tag("HEAD")
                    ForEach(model.localRefs, id: \.self) { ref in
                        Text(DisplayText.sanitize(String(ref.dropFirst("refs/heads/".count)))).tag(ref)
                    }
                }
                .frame(maxWidth: ReflogMetrics.refPickerWidth)
                .accessibilityIdentifier("reflog.reference")
                Spacer(minLength: 0)
                Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
                    .labelStyle(.iconOnly).help("Refresh reflog")
                    .disabled(model.isLoading || model.isScanning)
            }
            HStack(spacing: Space.s3) {
                Picker("View", selection: $model.mode) {
                    ForEach(ReflogModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Reflog view")
                Spacer(minLength: 0)
                Button("Find Lost Commits…", systemImage: "magnifyingglass") { model.findLostCommits() }
                    .disabled(model.session.isBusy)
                    .help("Search Git's object store. Runs only when requested and can be cancelled.")
            }
            if let point = model.lastRecoverableOperation {
                Menu("Recover Before \(DisplayText.sanitize(point.operation))…") {
                    Button("Create Branch at Previous State…") { operations.recoverBranch(at: point.oldOID) }
                    Menu("Reset Current Branch to Previous State") { resetActions(at: point.oldOID) }
                }
                .disabled(model.session.isBusy)
                .help("Previous committed state \(point.oldOID.prefix(7)). Discarded file edits cannot be recovered.")
            }
            if let error = model.session.recoveryJournalError {
                Text(error).typeStyle(.caption).foregroundStyle(.token(.statusWarning))
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.s5).padding(.bottom, Space.s4)
    }

    private var scanProgress: some View {
        HStack(spacing: Space.s3) {
            ProgressView().controlSize(.small)
            Text(model.session.operations.current?.progress?.summary ?? "Searching Git's object store…")
                .typeStyle(.callout).lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel", action: model.cancelScan)
        }.padding(Space.s4)
    }

    private var emptyState: some View {
        VStack(spacing: Space.s4) {
            if model.isSlow { ProgressView().controlSize(.small) }
            Image(systemName: model.mode == .lost ? "magnifyingglass" : "clock.arrow.circlepath")
                .symbolSize(IconSize.lg).foregroundStyle(.token(.textTertiary))
            Text(emptyTitle).typeStyle(.headline)
            Text(emptyExplanation).typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center).frame(maxWidth: PanelMetrics.contentColumnMax)
        }
        .padding(Space.s7).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if model.isLoading { return model.isSlow ? "Reading reflog…" : "" }
        if model.isScanning { return "Looking for lost commits" }
        if model.mode == .recovery { return "No recovery points" }
        return model.mode == .reflog
            ? "No reflog entries" : model.hasScanned ? "No lost commits found" : "Find lost commits"
    }

    private var emptyExplanation: String {
        if model.isLoading || model.isScanning { return "" }
        if model.mode == .recovery {
            return
                "Previous committed states from operations run by Jit appear here. Git may expire their objects; discarded uncommitted edits cannot be recovered here."
        }
        if model.mode == .reflog {
            return
                "This reference may be new, its log may have expired, or reflog recording may be disabled. Find Lost Commits can search objects still stored by Git."
        }
        return
            "Search for commits no longer reachable from HEAD or any reference, including dropped stashes. Objects already removed by Git cannot be recovered."
    }

    private func rowView(_ row: ReflogRow) -> some View {
        HStack(alignment: .top, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(row.action).typeStyle(.caption)
                    .foregroundStyle(
                        row.id == model.selection ? ReflogStyle.selectedText : ColorToken.textSecondary.color)
                if row.isUnreachable {
                    Text("Unreachable").typeStyle(.caption).lineLimit(1)
                        .foregroundStyle(
                            row.id == model.selection ? ReflogStyle.selectedText : ColorToken.statusWarning.color)
                }
            }.frame(width: ReflogMetrics.actionWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(DisplayText.sanitize(row.message)).typeStyle(.body).lineLimit(2)
                HStack(spacing: Space.s3) {
                    Text(row.oid.hex(model.format, length: 7)).typeStyle(.monoCaption)
                    if model.mode == .reflog { Text(row.id).typeStyle(.caption).lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 0)
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(row.timestamp)),
                        format: .dateTime.month(.abbreviated).day().hour().minute()
                    )
                    .typeStyle(.caption)
                }.foregroundStyle(row.id == model.selection ? ReflogStyle.selectedText : ColorToken.textTertiary.color)
            }
        }
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reflog.entry.\(row.id)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if model.truncated && model.mode == .lost || model.pageLimitReached && model.mode == .reflog {
                Text(
                    "Showing the first \(ReflogModel.entryLimit) entries. Choose a reference or refresh to narrow the list."
                )
                .typeStyle(.caption).foregroundStyle(.token(.textSecondary))
            }
            HStack(spacing: Space.s3) {
                if let row = model.selected {
                    Button("Create Branch…") { operations.recoverBranch(at: row.oid.hex(model.format)) }
                        .accessibilityIdentifier("reflog.createBranch")
                    Button("Show in Graph") { showInGraph(row) }
                    Menu("More") { actions(for: row) }
                } else {
                    Text("Select an entry to inspect or recover its commit.").typeStyle(.caption)
                        .foregroundStyle(.token(.textSecondary))
                }
                Spacer(minLength: 0)
                if model.mode == .reflog, model.canLoadMore {
                    Button("Load More", action: model.loadMore)
                }
            }.disabled(model.session.isBusy)
        }.controlSize(.small).padding(Space.s4)
    }

    @ViewBuilder private func actions(for row: ReflogRow) -> some View {
        Button("Create Branch Here…") { operations.recoverBranch(at: row.oid.hex(model.format)) }
        Button("Cherry-pick…") { operations.cherryPick([row.oid.hex(model.format)]) }
            .disabled(model.session.operationState != .clean)
        Button("Compare with Current") { compareWithCurrent(row.oid) }
            .disabled(model.session.status?.branch.oid == nil)
        Menu("Reset Current Branch Here") { resetActions(at: row.oid.hex(model.format)) }
            .disabled(model.session.operationState != .clean)
        Divider()
        Button("Copy SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.oid.hex(model.format), forType: .string)
        }
    }

    @ViewBuilder private func resetActions(at commit: String) -> some View {
        Button("Soft — Keep Index and Files…") { operations.confirmReset(to: commit, mode: "soft") }
        Button("Mixed — Keep Files…") { operations.confirmReset(to: commit, mode: "mixed") }
        Button("Keep — Preserve Local Changes…") { operations.confirmReset(to: commit, mode: "keep") }
        Button("Hard — Discard Tracked Changes…") { operations.confirmReset(to: commit, mode: "hard") }
    }
}
