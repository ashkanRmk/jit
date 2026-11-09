import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// What the inspector shows (design §3.4): one commit, the working directory, or a comparison.
@MainActor @Observable
final class InspectorModel {
    enum Mode: Equatable {
        case nothing
        case commit(ObjectID)
        case workingDirectory
        case compare(ObjectID, ObjectID)
        case compareWithWorkingDirectory(ObjectID)
    }

    struct WIPEntry: Identifiable, Hashable {
        let id: Int
        let code: String
        let path: String
    }

    private(set) var mode: Mode = .nothing
    private(set) var details: CommitDetails?
    private(set) var files: [ChangedFile] = []
    /// Shown only after 120 ms of loading (design §3.4).
    private(set) var showsSpinner = false
    private(set) var error: String?
    private(set) var wipEntries: [WIPEntry] = []
    private(set) var wipTotal = 0
    var compareMode: CompareMode = .sinceMergeBase {
        didSet { if oldValue != compareMode { reload() } }
    }
    var showsTree = false
    var format: ObjectFormat = .sha1
    var refs: RefSnapshot?

    @ObservationIgnored var handle: RepositoryHandle?
    @ObservationIgnored var selectCommit: (ObjectID) -> Void = { _ in }
    @ObservationIgnored var showFileHistory: (String, Bool) -> Void = { _, _ in }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?

    func show(selection: [ObjectID], wip: Bool) {
        let next: Mode
        switch (selection.count, wip) {
        case (0, false): next = .nothing
        case (0, true): next = .workingDirectory
        case (1, false): next = .commit(selection[0])
        case (_, true): next = .compareWithWorkingDirectory(selection[0])
        default: next = .compare(selection[0], selection[1])
        }
        guard next != mode else { return }
        mode = next
        reload()
    }

    func swapComparison() {
        guard case .compare(let a, let b) = mode else { return }
        mode = .compare(b, a)
        reload()
    }

    func refreshWorkingDirectory() {
        if mode == .workingDirectory { reload() }
    }

    private func reload() {
        // Selecting something else cancels the previous request, which kills its Git process (ADR-0005).
        task?.cancel()
        spinnerTask?.cancel()
        details = nil
        files = []
        error = nil
        showsSpinner = false
        guard let handle, mode != .nothing else { return }
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.showsSpinner = true
        }
        let mode = self.mode
        let compareMode = self.compareMode
        task = Task { [weak self] in
            do throws(GitCoreError) {
                switch mode {
                case .nothing:
                    return
                case .commit(let oid):
                    let details = try await handle.commitDetails(oid)
                    guard let self, !Task.isCancelled else { return }
                    self.details = details
                    self.files = details.files
                case .compare(let a, let b):
                    let files = try await handle.compare(a, b, mode: compareMode)
                    guard let self, !Task.isCancelled else { return }
                    self.files = files
                case .compareWithWorkingDirectory(let oid):
                    let files = try await handle.compareWithWorkingTree(oid)
                    guard let self, !Task.isCancelled else { return }
                    self.files = files
                case .workingDirectory:
                    let snapshot = await handle.lastSnapshot()
                    guard let self, !Task.isCancelled else { return }
                    self.loadWIP(snapshot)
                }
                self?.finish()
            } catch .cancelled {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.summary
                self.finish()
            }
        }
    }

    private func finish() {
        spinnerTask?.cancel()
        showsSpinner = false
    }

    private func loadWIP(_ snapshot: StatusSnapshot?) {
        guard let entries = snapshot?.entries else {
            wipEntries = []
            wipTotal = 0
            return
        }
        var result: [WIPEntry] = []
        let limit = min(entries.count, 1000)
        for index in 0..<entries.count where result.count < limit {
            let kind = entries.kind(at: index)
            if kind == .ignored { continue }
            let codes = entries.statusCodes(at: index)
            let code: String
            switch kind {
            case .untracked: code = "?"
            case .unmerged: code = "U"
            default: code = String(codes.index == "." ? codes.worktree : codes.index)
            }
            result.append(WIPEntry(id: index, code: code, path: entries.path(at: index)))
        }
        wipEntries = result
        wipTotal = (0..<entries.count).reduce(0) { $0 + (entries.kind(at: $1) == .ignored ? 0 : 1) }
    }
}

/// Inspector content (opaque `surface.panel`, design §3.4).
struct CommitInspectorView: View {
    let model: InspectorModel

    var body: some View {
        Group {
            switch model.mode {
            case .nothing:
                Placeholder(text: "Select a commit")
            case .commit(let oid):
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s7) {
                        if let details = model.details {
                            CommitHeader(details: details, model: model)
                        } else if let error = model.error {
                            InlineError(text: error)
                        } else {
                            Text(oid.hex(model.format, length: 7))
                                .typeStyle(.monoBody)
                                .foregroundStyle(.token(.textTertiary))
                        }
                        if model.details != nil {
                            FilesSection(model: model, isMerge: (model.details?.parents.count ?? 0) > 1)
                        }
                    }
                    .padding(Space.s7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .workingDirectory:
                ScrollView {
                    WorkingDirectorySummary(model: model)
                        .padding(Space.s7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .compare(let a, let b):
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s6) {
                        CompareHeader(model: model, from: a, to: b)
                        FilesSection(model: model, isMerge: false)
                    }
                    .padding(Space.s7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .compareWithWorkingDirectory(let oid):
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s6) {
                        Text("Comparing \(oid.hex(model.format, length: 7)) → working directory")
                            .typeStyle(.headline)
                            .foregroundStyle(.token(.textPrimary))
                        Text("Tracked files only — untracked files are not included.")
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textTertiary))
                        FilesSection(model: model, isMerge: false)
                    }
                    .padding(Space.s7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfacePanel.color.ignoresSafeArea())
    }
}

private struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .typeStyle(.callout)
            .foregroundStyle(.token(.textTertiary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InlineError: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .typeStyle(.callout)
            .foregroundStyle(.token(.statusDanger))
    }
}

private struct CommitHeader: View {
    let details: CommitDetails
    let model: InspectorModel
    @State private var hoversSHA = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(DisplayText.sanitize(details.subject))
                    .typeStyle(.title)
                    .foregroundStyle(.token(.textPrimary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !details.body.isEmpty {
                    Text(details.body)
                        .typeStyle(.body)
                        .foregroundStyle(.token(.textSecondary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s5, verticalSpacing: Space.s4) {
                GridRow {
                    MetaLabel("Author")
                    PersonLine(name: details.authorName, email: details.authorEmail)
                }
                if details.committerName != details.authorName || details.committerEmail != details.authorEmail {
                    GridRow {
                        MetaLabel("Committer")
                        PersonLine(name: details.committerName, email: details.committerEmail)
                    }
                }
                GridRow {
                    MetaLabel(details.committerTime == details.authorTime ? "Date" : "Authored")
                    Text(Self.date(details.authorTime))
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                        .help(Self.iso(details.authorTime) + " (" + details.authorTimeZone + ")")
                }
                if details.committerTime != details.authorTime {
                    GridRow {
                        MetaLabel("Committed")
                        Text(Self.date(details.committerTime))
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                    }
                }
                GridRow {
                    MetaLabel("SHA")
                    HStack(spacing: Space.s3) {
                        Text(details.oid.hex(model.format))
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            Pasteboard.copy(details.oid.hex(model.format))
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .opacity(hoversSHA ? 1 : 0)
                        .accessibilityLabel("Copy SHA")
                        .help("Copy SHA")
                    }
                    .onHover { hoversSHA = $0 }
                }
                if !details.parents.isEmpty {
                    GridRow {
                        MetaLabel(details.parents.count == 1 ? "Parent" : "Parents")
                        HStack(spacing: Space.s4) {
                            ForEach(details.parents, id: \.self) { parent in
                                Button(parent.hex(model.format, length: 7)) { model.selectCommit(parent) }
                                    .buttonStyle(.link)
                                    .typeStyle(.monoCaption)
                                    .help("Select parent \(parent.hex(model.format, length: 7))")
                            }
                        }
                    }
                }
                let labels = refsHere
                if !labels.isEmpty {
                    GridRow {
                        MetaLabel("Refs")
                        Text(labels.joined(separator: ", "))
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var refsHere: [String] {
        (model.refs?.refs ?? []).filter { $0.commit == details.oid }.map(\.shortName)
    }

    static func date(_ time: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .shortened)
    }

    static func iso(_ time: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(time)).formatted(.iso8601)
    }
}

private struct MetaLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .typeStyle(.caption)
            .foregroundStyle(.token(.textTertiary))
            .gridColumnAlignment(.trailing)
    }
}

private struct PersonLine: View {
    let name: String
    let email: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textPrimary))
            Text(email)
                .typeStyle(.caption)
                .foregroundStyle(.token(.textTertiary))
                .textSelection(.enabled)
        }
    }
}

private struct CompareHeader: View {
    let model: InspectorModel
    let from: ObjectID
    let to: ObjectID

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s4) {
                Text("Comparing")
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                Text("\(from.hex(model.format, length: 7)) → \(to.hex(model.format, length: 7))")
                    .typeStyle(.monoBody)
                    .foregroundStyle(.token(.textSecondary))
                Button {
                    model.swapComparison()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap")
                .accessibilityLabel("Swap comparison")
            }
            Picker("", selection: Bindable(model).compareMode) {
                Text("Changes on B since common ancestor").tag(CompareMode.sinceMergeBase)
                Text("Direct difference").tag(CompareMode.direct)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

private struct FilesSection: View {
    let model: InspectorModel
    let isMerge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s4) {
                Text(header)
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                    .monospacedDigit()
                if model.showsSpinner { ProgressView().controlSize(.small) }
                Spacer()
                Picker("", selection: Bindable(model).showsTree) {
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("Flat list")
                    Image(systemName: "list.bullet.indent").tag(true).accessibilityLabel("Tree")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if isMerge {
                Picker("", selection: .constant(0)) {
                    Text("First parent").tag(0)
                    Text("Combined").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(true)
                .help("Combined diff is planned")
            }
            if let error = model.error {
                InlineError(text: error)
            } else if model.files.isEmpty, !model.showsSpinner {
                Text("No file changes")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textTertiary))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.showsTree {
                        ForEach(groups, id: \.directory) { group in
                            Text(group.directory.isEmpty ? "/" : group.directory + "/")
                                .typeStyle(.monoCaption)
                                .foregroundStyle(.token(.textTertiary))
                                .padding(.top, Space.s4)
                            ForEach(group.files, id: \.self) { file in
                                FileRow(file: file, model: model, nameOnly: true)
                            }
                        }
                    } else {
                        ForEach(model.files, id: \.self) { file in FileRow(file: file, model: model, nameOnly: false) }
                    }
                }
            }
        }
    }

    private var header: String {
        let additions = model.files.reduce(0) { $0 + ($1.additions ?? 0) }
        let deletions = model.files.reduce(0) { $0 + ($1.deletions ?? 0) }
        let count = model.files.count
        return "\(count) \(count == 1 ? "file" : "files")  +\(additions) −\(deletions)"
    }

    private var groups: [(directory: String, files: [ChangedFile])] {
        let grouped = Dictionary(grouping: model.files) { ($0.path as NSString).deletingLastPathComponent }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
}

/// One changed file: status glyph, path (directory dimmed, middle-truncated), +/- mini bar. Selectable
/// for "Show File History"; no diff action until Phase 3.
private struct FileRow: View {
    let file: ChangedFile
    let model: InspectorModel
    let nameOnly: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.s4) {
            Text(file.status.letter)
                .typeStyle(.monoCaption)
                .foregroundStyle(statusColor)
                .frame(width: 12)
                .accessibilityLabel(statusName)
            pathText
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
            StatBar(additions: file.additions, deletions: file.deletions)
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s3)
        .background(RowBackground(isHovered ? .hover : .rest))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Show File History") { model.showFileHistory(file.path, false) }
            Button("Show Folder History") {
                model.showFileHistory((file.path as NSString).deletingLastPathComponent, true)
            }
            .disabled((file.path as NSString).deletingLastPathComponent.isEmpty)
            Button("Copy Path") { Pasteboard.copy(file.path) }
        }
        .accessibilityElement(children: .combine)
    }

    private var pathText: Text {
        let name = (file.path as NSString).lastPathComponent
        let directory = (file.path as NSString).deletingLastPathComponent
        var result = Text("")
        if let old = file.oldPath {
            result = Text(old + " → ").foregroundStyle(.token(.textTertiary))
        }
        if !nameOnly, !directory.isEmpty {
            result = result + Text(directory + "/").foregroundStyle(.token(.textTertiary))
        }
        return (result + Text(name).foregroundStyle(.token(.textPrimary))).font(TypeToken.monoCaption.font)
    }

    private var statusColor: Color {
        switch file.status {
        case .added: .token(.diffAddMark)
        case .deleted: .token(.diffDeleteMark)
        case .renamed, .copied: .token(.statusInfo)
        case .unmerged: .token(.statusWarning)
        default: .token(.textSecondary)
        }
    }

    private var statusName: String {
        switch file.status {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .unmerged: "Unmerged"
        case .unknown: "Changed"
        }
    }
}

/// 8-segment +/- bar with numbers; "binary" for binary files.
private struct StatBar: View {
    let additions: Int?
    let deletions: Int?

    var body: some View {
        if let additions, let deletions {
            HStack(spacing: Space.s3) {
                Text("+\(additions)").foregroundStyle(.token(.diffAddMark))
                Text("−\(deletions)").foregroundStyle(.token(.diffDeleteMark))
                HStack(spacing: 1) {
                    ForEach(0..<8, id: \.self) { index in
                        Rectangle()
                            .fill(color(index))
                            .frame(width: 3, height: 8)
                    }
                }
                .accessibilityHidden(true)
            }
            .typeStyle(.monoCaption)
            .monospacedDigit()
            .accessibilityLabel("\(additions) additions, \(deletions) deletions")
        } else {
            Text("binary")
                .typeStyle(.caption)
                .foregroundStyle(.token(.textTertiary))
        }
    }

    private func color(_ index: Int) -> Color {
        let total = (additions ?? 0) + (deletions ?? 0)
        guard total > 0 else { return ColorToken.borderSubtle.color }
        let filled = min(8, max(1, Int((Double(total) / 10).rounded(.up))))
        let green = Int((Double(additions ?? 0) / Double(total) * Double(filled)).rounded())
        if index < green { return ColorToken.diffAddMark.color }
        if index < filled { return ColorToken.diffDeleteMark.color }
        return ColorToken.borderSubtle.color
    }
}

/// The WIP row's inspector: changed paths with status letters (the working-directory panel is Phase 3).
private struct WorkingDirectorySummary: View {
    let model: InspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Uncommitted changes")
                .typeStyle(.title)
                .foregroundStyle(.token(.textPrimary))
            Text("\(model.wipTotal) changed \(model.wipTotal == 1 ? "path" : "paths")")
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
            LazyVStack(alignment: .leading, spacing: Space.s2) {
                ForEach(model.wipEntries) { entry in
                    HStack(spacing: Space.s4) {
                        Text(entry.code)
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.token(.textSecondary))
                            .frame(width: 12)
                        Text(entry.path)
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.token(.textPrimary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if model.wipTotal > model.wipEntries.count {
                Text("and \(model.wipTotal - model.wipEntries.count) more")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
            }
        }
    }
}
