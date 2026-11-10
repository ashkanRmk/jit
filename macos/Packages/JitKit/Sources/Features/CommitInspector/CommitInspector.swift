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

    private(set) var mode: Mode = .nothing
    private(set) var details: CommitDetails?
    private(set) var files: [ChangedFile] = []
    /// Shown only after 120 ms of loading (design §3.4).
    private(set) var showsSpinner = false
    private(set) var error: String?
    var compareMode: CompareMode = .sinceMergeBase {
        didSet { if oldValue != compareMode { reload() } }
    }
    var showsTree = false
    /// Folders opened in the tree view (all closed at first); forgotten when another commit is shown.
    private(set) var expandedFolders: Set<String> = []

    func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
    }
    var format: ObjectFormat = .sha1
    var refs: RefSnapshot?

    @ObservationIgnored var handle: RepositoryHandle? {
        didSet { workingDirectory?.handle = handle }
    }
    /// The working-directory panel (P3.1), shown while the WIP row is selected.
    @ObservationIgnored var workingDirectory: WorkingDirectoryModel?
    /// The diff viewer below the file list (P3.6).
    @ObservationIgnored var diff: DiffViewModel?
    @ObservationIgnored var diffController: DiffViewController?
    @ObservationIgnored var openBlame: (String, ObjectID?) -> Void = { _, _ in }
    /// The file whose diff is open (commit / compare lists).
    private(set) var openedFilePath: String?

    /// Opens the diff of `file` for what the inspector shows.
    func openDiff(_ file: ChangedFile) {
        let target: DiffTarget
        switch mode {
        case .commit(let oid): target = .commit(oid, path: file.path)
        case .compare(let a, let b):
            target = .commits(from: a, to: b, path: file.path, sinceMergeBase: compareMode == .sinceMergeBase)
        case .compareWithWorkingDirectory(let oid): target = .commitToWorktree(oid, path: file.path)
        case .nothing, .workingDirectory: return
        }
        openedFilePath = file.path
        diff?.open(target)
    }

    /// The diff was closed from the centre pane (Esc, its close button): the file row drops its highlight.
    func closeDiff() {
        openedFilePath = nil
        if mode == .workingDirectory { workingDirectory?.selection = [] }
        diff?.close()
    }

    @ObservationIgnored var selectCommit: (ObjectID) -> Void = { _ in }
    /// Author pictures (`AvatarStore`); `nil` in previews and tests.
    @ObservationIgnored var avatars: AvatarStore?
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
        openedFilePath = nil
        expandedFolders = []
        diff?.close()
        reload()
    }

    func swapComparison() {
        guard case .compare(let a, let b) = mode else { return }
        mode = .compare(b, a)
        openedFilePath = nil
        expandedFolders = []
        diff?.close()
        reload()
    }

    private func reload() {
        // Selecting something else cancels the previous request, which kills its Git process (ADR-0005).
        task?.cancel()
        spinnerTask?.cancel()
        details = nil
        files = []
        error = nil
        showsSpinner = false
        // The panel follows status itself; the inspector only switches it on and off.
        if mode == .workingDirectory {
            workingDirectory?.activate()
            return
        }
        workingDirectory?.deactivate()
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
                    return
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
        #if DEBUG
            // `-JitInspectorOpenFile <n>` (screenshots): opens the diff of the n-th changed file once.
            if !debugOpenedFile, UserDefaults.standard.object(forKey: "JitInspectorOpenFile") != nil {
                debugOpenedFile = true
                let index = UserDefaults.standard.integer(forKey: "JitInspectorOpenFile")
                if files.indices.contains(index) { openDiff(files[index]) }
            }
        #endif
    }

    #if DEBUG
        @ObservationIgnored private var debugOpenedFile = false
    #endif
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
                // The panel does not scroll (0.0.3): the message keeps its height, the file list takes the rest
                // and scrolls inside its own container.
                VStack(alignment: .leading, spacing: Space.s5) {
                    if let details = model.details {
                        CommitHeader(details: details, model: model)
                        FilesSection(model: model, isMerge: details.parents.count > 1).panelSection()
                    } else {
                        Group {
                            if let error = model.error {
                                InlineError(text: error)
                            } else {
                                Text(oid.hex(model.format, length: 7))
                                    .typeStyle(.monoBody)
                                    .foregroundStyle(.token(.textTertiary))
                            }
                        }
                        .panelSection()
                        Spacer(minLength: 0)
                    }
                }
                .padding(Space.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .workingDirectory:
                if let workingDirectory = model.workingDirectory {
                    WorkingDirectoryView(model: workingDirectory)
                }
            case .compare(let a, let b):
                VStack(alignment: .leading, spacing: Space.s5) {
                    CompareHeader(model: model, from: a, to: b).panelSection()
                    FilesSection(model: model, isMerge: false).panelSection()
                }
                .padding(Space.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .compareWithWorkingDirectory(let oid):
                VStack(alignment: .leading, spacing: Space.s5) {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text("Comparing \(oid.hex(model.format, length: 7)) → working directory")
                            .typeStyle(.headline)
                            .foregroundStyle(.token(.textPrimary))
                        Text("Tracked files only — untracked files are not included.")
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textTertiary))
                    }
                    .panelSection()
                    FilesSection(model: model, isMerge: false).panelSection()
                }
                .padding(Space.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // One container per section: the message, the people, the commit's facts.
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(DisplayText.sanitize(details.subject))
                    .typeStyle(.title)
                    .foregroundStyle(.token(.textPrimary))
                    .textSelection(.enabled)
                    .lineLimit(InspectorMetrics.subjectLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(DisplayText.sanitize(details.subject))
                if !details.body.isEmpty {
                    // A static height: a long description scrolls here instead of pushing the files away.
                    ScrollView {
                        Text(DisplayText.sanitize(MessageReflow.reflow(details.body), keepNewlines: true))
                            .typeStyle(.body)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: InspectorMetrics.messageBodyHeight)
                }
            }
            .panelSection()
            VStack(alignment: .leading, spacing: Space.s5) {
                PersonLine(
                    role: hasCommitter ? "Author" : nil, name: details.authorName, email: details.authorEmail,
                    date: Self.date(details.authorTime),
                    dateHelp: Self.iso(details.authorTime) + " (" + details.authorTimeZone + ")", avatars: model.avatars
                )
                if hasCommitter {
                    PersonLine(
                        role: "Committer", name: details.committerName, email: details.committerEmail,
                        date: details.committerTime != details.authorTime ? Self.date(details.committerTime) : nil,
                        dateHelp: Self.iso(details.committerTime), avatars: model.avatars)
                } else if details.committerTime != details.authorTime {
                    Text("Committed \(Self.date(details.committerTime))")
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                }
            }
            .panelSection()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s5, verticalSpacing: Space.s4) {
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
            .panelSection()
        }
    }

    private var hasCommitter: Bool {
        details.committerName != details.authorName || details.committerEmail != details.authorEmail
    }

    private var refsHere: [String] {
        (model.refs?.refs ?? []).filter { $0.commit == details.oid }.map { DisplayText.sanitize($0.shortName) }
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

/// A person with their picture (Gravatar when there is one, initials otherwise), name, email and date.
private struct PersonLine: View {
    let role: String?
    let name: String
    let email: String
    let date: String?
    let dateHelp: String
    let avatars: AvatarStore?

    var body: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            AvatarView(name: name, email: email, store: avatars, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                    Text(DisplayText.sanitize(name))
                        .typeStyle(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(1)
                    if let role {
                        Text(role)
                            .typeStyle(.caption)
                            .foregroundStyle(.token(.textTertiary))
                    }
                }
                Text(DisplayText.sanitize(email))
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date {
                    Text(date)
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textSecondary))
                        .help(dateHelp)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An author's picture in a circle: the Gravatar picture when one is known, initials on the author's
/// colour otherwise (the same colour and initials as the graph node).
struct AvatarView: View {
    let name: String
    let email: String
    let store: AvatarStore?
    var size: CGFloat = 28

    var body: some View {
        // Reading the revision makes the view refresh when a picture arrives.
        let _ = store?.revision
        Group {
            if let image = store?.image(for: email) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                let color = Self.color(email: email)
                ZStack {
                    color.opacity(0.22)
                    Text(AvatarStyle.initials(for: name))
                        .font(Font(GraphTypography.nodeInitials(diameter: size)))
                        .foregroundStyle(color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline))
        .accessibilityHidden(true)
    }

    @MainActor static func color(email: String) -> Color {
        var hash = StableHash()
        hash.combine(email.lowercased())
        return LaneColor.allCases[AvatarStyle.colorSlot(forHash: hash.value)].color
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.showsTree {
                            ForEach(tree) { row in
                                if let index = row.fileIndex, model.files.indices.contains(index) {
                                    FileRow(file: model.files[index], model: model, nameOnly: true)
                                        .padding(.leading, CGFloat(row.depth) * Space.s6)
                                } else if let path = row.folderPath {
                                    FolderRow(row: row) { model.toggleFolder(path) }
                                        .padding(.leading, CGFloat(row.depth) * Space.s6)
                                }
                            }
                        } else {
                            ForEach(model.files, id: \.self) { file in
                                FileRow(file: file, model: model, nameOnly: false)
                            }
                        }
                    }
                }
            }
        }
        // The container fills what the panel has left; the rows scroll inside it.
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(minHeight: InspectorMetrics.filesMinHeight, alignment: .top)
    }

    private var header: String {
        let additions = model.files.reduce(0) { $0 + ($1.additions ?? 0) }
        let deletions = model.files.reduce(0) { $0 + ($1.deletions ?? 0) }
        let count = model.files.count
        return "\(count) \(count == 1 ? "file" : "files")  +\(additions) −\(deletions)"
    }

    private var tree: [FileTree.Row] {
        FileTree.rows(paths: model.files.map(\.path), expanded: model.expandedFolders)
    }
}

/// Fixed sizes of the commit inspector's containers.
enum InspectorMetrics {
    static let subjectLines = 3
    /// The description's own scroll area.
    static let messageBodyHeight: CGFloat = 96
    static let filesMinHeight: CGFloat = 120
}

/// The changed files as a folder tree (the inspector's Tree view): folders first, closed until opened,
/// chains of folders that hold nothing but one folder merged into one row (`src/app/views`).
enum FileTree {
    struct Row: Equatable, Identifiable {
        let id: String
        let depth: Int
        let name: String
        /// Set for a folder row: the folder's full path (the key in the expanded set).
        var folderPath: String?
        /// Set for a file row: the file's index in the input.
        var fileIndex: Int?
        /// Files anywhere under a folder.
        var fileCount = 0
        var isExpanded = false
    }

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [(name: String, index: Int)] = []
        var count = 0
    }

    /// The visible rows for `paths` (in their given order) with the folders in `expanded` open.
    static func rows(paths: [String], expanded: Set<String>) -> [Row] {
        let root = Node()
        for (index, path) in paths.enumerated() {
            var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let name = parts.popLast() else { continue }
            var node = root
            node.count += 1
            for part in parts {
                let next = node.folders[part] ?? Node()
                node.folders[part] = next
                next.count += 1
                node = next
            }
            node.files.append((name, index))
        }
        var result: [Row] = []
        func emit(_ node: Node, prefix: String, depth: Int) {
            for key in node.folders.keys.sorted() {
                guard var folder = node.folders[key] else { continue }
                var name = key
                // `a/` holding only `b/` shows as one row `a/b`.
                while folder.files.isEmpty, folder.folders.count == 1, let only = folder.folders.first {
                    name += "/" + only.key
                    folder = only.value
                }
                let path = prefix + name
                let isExpanded = expanded.contains(path)
                result.append(
                    Row(
                        id: "d:" + path, depth: depth, name: name, folderPath: path, fileCount: folder.count,
                        isExpanded: isExpanded))
                if isExpanded { emit(folder, prefix: path + "/", depth: depth + 1) }
            }
            for file in node.files {
                result.append(Row(id: "f:\(file.index)", depth: depth, name: file.name, fileIndex: file.index))
            }
        }
        emit(root, prefix: "", depth: 0)
        return result
    }
}

/// A folder of the tree view: a plus button (minus when open), the folder's name and how many files it holds.
private struct FolderRow: View {
    let row: FileTree.Row
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.s3) {
            Button(action: toggle) {
                Image(systemName: row.isExpanded ? "minus.square" : "plus.square")
                    .symbolSize(IconSize.sm)
                    .foregroundStyle(.token(.textSecondary))
                    .frame(width: IconSize.md, height: IconSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
            Image(systemName: "folder")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            Text(DisplayText.sanitize(row.name))
                .typeStyle(.monoBody)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.s3)
            Text("\(row.fileCount)")
                .typeStyle(.caption)
                .monospacedDigit()
                .foregroundStyle(.token(.textTertiary))
        }
        .padding(.vertical, Space.s3)
        .padding(.horizontal, Space.s3)
        .background(RowBackground(isHovered ? .hover : .rest))
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(row.name), \(row.fileCount) \(row.fileCount == 1 ? "file" : "files")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
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
                .typeStyle(.monoBody)
                .foregroundStyle(statusColor)
                .frame(width: 12)
                .accessibilityLabel(statusName)
            FilePathText(
                prefix: file.oldPath.map { DisplayText.sanitize($0) + " → " },
                directory: nameOnly ? "" : (DisplayText.sanitize(file.path) as NSString).deletingLastPathComponent,
                name: (DisplayText.sanitize(file.path) as NSString).lastPathComponent
            )
            .font(TypeToken.monoBody.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
            StatBar(additions: file.additions, deletions: file.deletions)
        }
        .padding(.vertical, Space.s3)
        .padding(.horizontal, Space.s3)
        .background(RowBackground(model.openedFilePath == file.path ? .selected : isHovered ? .hover : .rest))
        .contentShape(Rectangle())
        .onTapGesture { model.openDiff(file) }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the diff")
        .contextMenu {
            Button("Show File History") { model.showFileHistory(file.path, false) }
            Button("Show Folder History") {
                model.showFileHistory((file.path as NSString).deletingLastPathComponent, true)
            }
            .disabled((file.path as NSString).deletingLastPathComponent.isEmpty)
            Button("Copy Path") { Pasteboard.copy(file.path) }
            if case .commit(let oid) = model.mode, file.status != .deleted {
                Button("Blame at This Commit") { model.openBlame(file.path, oid) }
            }
        }
        .accessibilityElement(children: .combine)
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

/// A file path on one line that never cuts the file name: when it does not fit, the folders before the name
/// shorten in the middle (`src/…/views/`) and the name stays whole. The name itself shortens only when it
/// alone is wider than the row.
struct FilePathText: View {
    var prefix: String?
    let directory: String
    let name: String

    var body: some View {
        let leading = (prefix ?? "") + (directory.isEmpty ? "" : directory + "/")
        FilePathLayout {
            Text(leading)
                .foregroundStyle(.token(.textTertiary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, alignment: .leading)
                .clipped()
            Text(name)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Lays out `[folders, name]` on one line: the name takes the width it needs first; the folders get what is
/// left, and disappear when that is too little to show anything useful.
struct FilePathLayout: Layout {
    /// Below this the folders would be an ellipsis and a letter: show the name alone.
    static let minimumFolders: CGFloat = 36

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let folders = subviews[0].sizeThatFits(.unspecified)
        let name = subviews[1].sizeThatFits(.unspecified)
        let ideal = folders.width + name.width
        return CGSize(width: min(ideal, proposal.width ?? ideal), height: max(folders.height, name.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let widths = Self.widths(
            available: bounds.width, folders: subviews[0].sizeThatFits(.unspecified).width,
            name: subviews[1].sizeThatFits(.unspecified).width)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: widths.folders, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + widths.folders, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: widths.name, height: bounds.height))
    }

    static func widths(available: CGFloat, folders: CGFloat, name: CGFloat) -> (folders: CGFloat, name: CGFloat) {
        let nameWidth = min(name, available)
        var foldersWidth = min(folders, available - nameWidth)
        if foldersWidth < min(folders, minimumFolders) { foldersWidth = 0 }
        return (foldersWidth, nameWidth)
    }
}

/// Added and removed line counts; "binary" for binary files. (The 8-segment bar went in 0.0.3: the room goes
/// to the file name.)
private struct StatBar: View {
    let additions: Int?
    let deletions: Int?

    var body: some View {
        if let additions, let deletions {
            HStack(spacing: Space.s3) {
                Text("+\(additions)").foregroundStyle(.token(.diffAddMark))
                Text("−\(deletions)").foregroundStyle(.token(.diffDeleteMark))
            }
            .typeStyle(.monoCaption)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(additions) additions, \(deletions) deletions")
        } else {
            Text("binary")
                .typeStyle(.caption)
                .foregroundStyle(.token(.textTertiary))
        }
    }
}

/// Commit bodies are usually hard-wrapped at ~72 columns; re-wrapping them in a narrower inspector gives
/// ragged lines. Joins lines inside plain paragraphs; keeps blank lines, list items (`-`, `*`, `1.`),
/// indented/code lines and trailers (`Signed-off-by:`) on their own lines. Display only.
enum MessageReflow {
    static func reflow(_ body: String) -> String {
        var output: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { output.append(current) }
            current = ""
        }
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                output.append("")
            } else if keepsOwnLine(line) {
                flush()
                current = line
            } else if current.isEmpty {
                current = line
            } else {
                current += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return output.joined(separator: "\n")
    }

    static func keepsOwnLine(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        if first == " " || first == "\t" { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("> ") { return true }
        if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty {
            return true
        }
        // Trailers: "Key-Word: value".
        if let colon = trimmed.firstIndex(of: ":"), trimmed[..<colon].allSatisfy({ $0.isLetter || $0 == "-" }),
            trimmed[..<colon].contains("-")
        {
            return true
        }
        return false
    }
}
