import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// The working-directory panel (design §3.1): glass header (branch, counts, view, filter, sort) over
/// opaque sections — Conflicts, Staged, Unstaged. A native `List` (virtualized, keyboard selection,
/// type-select) so thousands of rows stay cheap.
struct WorkingDirectoryView: View {
    @Bindable var model: WorkingDirectoryModel
    @FocusState private var filterFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.list.isClean, !model.isLoading {
                CleanState(subject: model.lastCommitSubject)
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorToken.surfacePanel.color.ignoresSafeArea())
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .background { shortcuts }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                Image(systemName: "arrow.triangle.branch")
                    .symbolSize(IconSize.sm)
                    .foregroundStyle(.token(.textSecondary))
                    .accessibilityHidden(true)
                Text(branchTitle)
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s4)
                if model.session.isBusy {
                    ProgressView().controlSize(.small).help("Working…")
                }
            }
            Text(WDCounts.line(model.session.status?.summary))
                .typeStyle(.callout)
                .monospacedDigit()
                .foregroundStyle(.token(.textSecondary))
            HStack(spacing: Space.s4) {
                TextField("Filter", text: $model.filter, prompt: Text("Filter files"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($filterFocused)
                    .help("Filter files (⌥⌘F)")
                    .onExitCommand {
                        model.filter = ""
                        filterFocused = false
                    }
                Picker("View", selection: $model.showsTree) {
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                    Image(systemName: "list.bullet.indent").tag(true).accessibilityLabel("Tree")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("List or tree")
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(WDSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .help("Sort by \(model.sort.title)")
                .accessibilityLabel("Sort by \(model.sort.title)")
            }
            if let banner = model.banner {
                ErrorBanner(text: banner, canRetry: model.canRetry, retry: model.retry, dismiss: model.dismissBanner)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.top, Space.s5)
        .padding(.bottom, Space.s4)
        .overlay(alignment: .bottom) {
            if model.showsProgress {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .accessibilityLabel("Refreshing")
            }
        }
    }

    private var branchTitle: String {
        guard let branch = model.session.status?.branch else { return "Working directory" }
        if let head = branch.head { return head }
        return "HEAD " + String((branch.oid ?? "").prefix(7))
    }

    /// Panel-scoped shortcuts that have no menu item yet (Phase 6 menu audit adds them).
    private var shortcuts: some View {
        Group {
            Button("Filter Files") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Open in Editor") { model.openInEditor(model.files(for: model.selection)) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Sections

    private var fileList: some View {
        List(selection: $model.selection) {
            ForEach(WDSection.allCases, id: \.self) { section in
                if section != .conflicts || !model.list.conflicts.isEmpty {
                    Section {
                        let items = model.items(section)
                        if items.isEmpty {
                            EmptySectionRow(section: section, filtered: !model.filter.isEmpty)
                                .dropTarget(section, model: model)
                                .listRowBackground(dropBackground(section))
                                .selectionDisabled()
                                .listRowSeparator(.hidden)
                        }
                        ForEach(items) { item in
                            row(item)
                                .tag(item.id)
                                .listRowSeparator(.hidden)
                                .listRowBackground(dropBackground(section))
                        }
                    } header: {
                        SectionHeader(section: section, model: model)
                            .dropTarget(section, model: model)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
        .animation(reduceMotion ? nil : MotionToken.select.animation, value: model.list)
        .contextMenu(forSelectionType: String.self) { ids in
            ContextMenu(model: model, files: model.files(for: ids))
        }
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            model.toggleSelection()
            return .handled
        }
        .accessibilityLabel("Changed files")
    }

    @ViewBuilder
    private func row(_ item: WDItem) -> some View {
        switch item {
        case .file(let file, let depth):
            FileRow(file: file, depth: depth, model: model)
                .draggable(model.beginDrag(file))
                .dropTarget(file.section, model: model)
        case .folder(let folder):
            FolderRow(folder: folder, model: model)
                .dropTarget(folder.section, model: model)
        }
    }

    private func dropBackground(_ section: WDSection) -> Color? {
        model.dropTarget == section ? ColorToken.accentMuted.color : nil
    }
}

extension View {
    /// Rows, empty rows and headers of a section accept a drag from the other section.
    fileprivate func dropTarget(_ section: WDSection, model: WorkingDirectoryModel) -> some View {
        dropDestination(for: String.self) { payloads, _ in
            model.drop(payloads, into: section)
        } isTargeted: { targeted in
            if targeted {
                model.dropTarget = section
            } else if model.dropTarget == section {
                model.dropTarget = nil
            }
        }
    }
}

private struct SectionHeader: View {
    let section: WDSection
    let model: WorkingDirectoryModel

    var body: some View {
        let count = model.list.files(section).count
        HStack(spacing: Space.s3) {
            if section == .conflicts {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.token(.statusDanger))
                    .accessibilityHidden(true)
            }
            Text(section.title)
                .typeStyle(.headline)
                .foregroundStyle(.token(.textPrimary))
            Text("\(count)")
                .typeStyle(.callout)
                .monospacedDigit()
                .foregroundStyle(.token(.textSecondary))
            Spacer()
            switch section {
            case .staged:
                Button("Unstage All") { model.unstageAll() }
                    .disabled(count == 0)
                    .help("Unstage every staged file")
            case .unstaged:
                Button("Stage All") { model.stageAll() }
                    .disabled(count == 0)
                    .help("Stage every unstaged file")
            case .conflicts:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(count) \(count == 1 ? "file" : "files")")
        .help(section == .conflicts ? "Resolve the conflict first (conflict resolution arrives in the next phase)" : "")
    }
}

private struct EmptySectionRow: View {
    let section: WDSection
    let filtered: Bool

    var body: some View {
        Text(text)
            .typeStyle(.callout)
            .foregroundStyle(.token(.textTertiary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.s2)
    }

    private var text: String {
        if filtered { return "No matching files" }
        return section == .staged ? "Nothing staged — drag files here to stage them" : "No unstaged changes"
    }
}

/// One file (design §3.1 File row).
private struct FileRow: View {
    let file: WDFile
    let depth: Int
    let model: WorkingDirectoryModel
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.s3) {
            StatusGlyph(file: file)
            Image(systemName: FileIcon.symbol(for: file))
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.textSecondary))
                .frame(width: IconSize.md)
                .accessibilityHidden(true)
            pathText
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            ForEach(file.badges, id: \.self) { Badge(badge: $0) }
            Spacer(minLength: Space.s3)
            if let stats = model.stats[file.id] {
                StatsText(stats: stats)
            }
            if file.canStageOrUnstage {
                Button(file.section == .staged ? "Unstage" : "Stage") {
                    file.section == .staged ? model.unstage([file]) : model.stage([file])
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(isHovered ? 1 : 0)
                .animation(reduceMotion ? nil : MotionToken.hover.animation, value: isHovered)
                .accessibilityHidden(!isHovered)
            }
        }
        .padding(.leading, CGFloat(depth) * Space.s6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onAppear { model.rowAppeared(file) }
        .onDisappear { model.rowDisappeared(file) }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: file.section == .staged ? "Unstage" : "Stage") {
            file.section == .staged ? model.unstage([file]) : model.stage([file])
        }
    }

    private var pathText: Text {
        let name = Text(DisplayText.sanitize(file.name)).font(TypeToken.body.font)
            .foregroundStyle(.token(.textPrimary))
        let original = file.originalPath.map {
            Text(DisplayText.sanitize(($0 as NSString).lastPathComponent) + " → ").font(TypeToken.body.font)
                .foregroundStyle(.token(.textTertiary))
        }
        let directory =
            depth == 0 && !file.directory.isEmpty && !model.showsTree
            ? Text("  " + DisplayText.sanitize(file.directory)).font(TypeToken.caption.font)
                .foregroundStyle(.token(.textTertiary)) : nil
        return Text("\(original ?? Text(""))\(name)\(directory ?? Text(""))")
    }

    private var help: String {
        if file.section == .conflicts {
            return
                "\(file.conflict?.title ?? "Conflict") — resolve the conflict first (conflict resolution arrives in the next phase)"
        }
        var text = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        if file.isPartial {
            text += "\nPartially staged: also listed under \(file.section == .staged ? "Unstaged" : "Staged")"
        }
        if let submodule = file.submodule {
            var parts: [String] = []
            if submodule.commitChanged { parts.append("new commits") }
            if submodule.hasTrackedChanges { parts.append("modified content") }
            if submodule.hasUntrackedChanges { parts.append("untracked content") }
            text += "\nSubmodule" + (parts.isEmpty ? "" : " — " + parts.joined(separator: ", "))
        }
        return text
    }

    private var accessibilityLabel: String {
        var parts = [file.path, file.change.spoken]
        if let stats = model.stats[file.id], let additions = stats.additions, let deletions = stats.deletions {
            parts.append("\(additions) \(additions == 1 ? "addition" : "additions")")
            parts.append("\(deletions) \(deletions == 1 ? "deletion" : "deletions")")
        }
        switch file.section {
        case .staged: parts.append(file.isPartial ? "partially staged" : "staged")
        case .unstaged: parts.append(file.isPartial ? "partially staged, unstaged part" : "unstaged")
        case .conflicts: parts.append(file.conflict?.title ?? "conflict")
        }
        return parts.joined(separator: ", ")
    }
}

/// Status letter, coloured by kind; a half-filled circle marks a partially staged file.
private struct StatusGlyph: View {
    let file: WDFile

    var body: some View {
        HStack(spacing: Space.s1) {
            Text(file.change.letter)
                .typeStyle(.monoCaption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .frame(width: 10)
            Image(systemName: "circle.lefthalf.filled")
                .symbolSize(IconSize.sm - 4)
                .foregroundStyle(color)
                .opacity(file.isPartial ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch file.change {
        case .added, .untracked: .token(.statusSuccess)
        case .modified, .typeChanged: .token(.statusWarning)
        case .deleted, .conflicted: .token(.statusDanger)
        case .renamed, .copied: .token(.statusInfo)
        }
    }
}

private struct Badge: View {
    let badge: WDBadge

    var body: some View {
        Group {
            switch badge {
            case .executable(let on):
                Text(on ? "+x" : "−x").typeStyle(.monoCaption)
            case .symlink:
                Image(systemName: "arrow.turn.up.right").symbolSize(IconSize.sm - 2)
            case .submodule:
                Image(systemName: "shippingbox").symbolSize(IconSize.sm - 2)
            }
        }
        .foregroundStyle(.token(.textSecondary))
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        switch badge {
        case .executable(let on): on ? "Made executable" : "No longer executable"
        case .symlink: "Symbolic link"
        case .submodule: "Submodule — stage or unstage the whole submodule"
        }
    }
}

private struct StatsText: View {
    let stats: LineStats

    var body: some View {
        Group {
            if let additions = stats.additions, let deletions = stats.deletions {
                HStack(spacing: Space.s2) {
                    Text("+\(additions)").foregroundStyle(.token(.diffAddMark))
                    Text("−\(deletions)").foregroundStyle(.token(.diffDeleteMark))
                }
                .typeStyle(.monoCaption)
                .monospacedDigit()
            } else {
                Text("binary")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FolderRow: View {
    let folder: WDFolder
    let model: WorkingDirectoryModel

    var body: some View {
        HStack(spacing: Space.s3) {
            Button {
                model.toggleFolder(folder)
            } label: {
                Image(systemName: "chevron.right")
                    .symbolSize(IconSize.sm - 3, weight: .semibold)
                    .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                    .foregroundStyle(.token(.textSecondary))
                    .frame(width: IconSize.md, height: IconSize.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folder.isExpanded ? "Collapse" : "Expand")
            Image(systemName: "folder")
                .symbolSize(IconSize.sm)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            Text(DisplayText.sanitize(folder.name))
                .typeStyle(.body)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.s3)
            Text("\(folder.files.count)")
                .typeStyle(.caption)
                .monospacedDigit()
                .foregroundStyle(.token(.textTertiary))
        }
        .padding(.leading, CGFloat(folder.depth) * Space.s6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Folder \(folder.path), \(folder.files.count) \(folder.files.count == 1 ? "file" : "files")"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.toggleFolder(folder) }
    }
}

private struct ContextMenu: View {
    let model: WorkingDirectoryModel
    let files: [WDFile]

    var body: some View {
        let unstaged = files.filter { $0.section == .unstaged }
        let staged = files.filter { $0.section == .staged }
        if !unstaged.isEmpty {
            Button(unstaged.count == 1 ? "Stage" : "Stage \(unstaged.count) Files") { model.stage(unstaged) }
        }
        if !staged.isEmpty {
            Button(staged.count == 1 ? "Unstage" : "Unstage \(staged.count) Files") { model.unstage(staged) }
        }
        if !unstaged.isEmpty || !staged.isEmpty { Divider() }
        Button("Open in Editor") { model.openInEditor(files) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(files.isEmpty)
        Button("Reveal in Finder") { model.revealInFinder(files) }
            .disabled(files.isEmpty)
        Divider()
        Button("Copy Path") { model.copyPaths(files, relative: false) }
            .disabled(files.isEmpty)
        Button("Copy Relative Path") { model.copyPaths(files, relative: true) }
            .disabled(files.isEmpty)
        if files.count == 1, let file = files.first, file.change != .untracked, !file.isDirectory {
            Divider()
            Button("Show File History") { model.openFileHistory(file.path) }
        }
    }
}

/// Calm empty state (design §3.1 Clean).
private struct CleanState: View {
    let subject: String?

    var body: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "checkmark.circle")
                .symbolSize(IconSize.hero, weight: .light)
                .foregroundStyle(.token(.textTertiary))
                .accessibilityHidden(true)
            Text("Working tree clean")
                .typeStyle(.title)
                .foregroundStyle(.token(.textPrimary))
            if let subject {
                Text("Last commit: \(DisplayText.sanitize(subject))")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textTertiary))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ErrorBanner: View {
    let text: String
    let canRetry: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.token(.statusDanger))
                .accessibilityHidden(true)
            Text(text)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s3)
            if canRetry { Button("Retry", action: retry) }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(Space.s4)
        .background(ColorToken.surfaceRaised.color, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .stroke(ColorToken.statusDanger.color.opacity(0.5), lineWidth: Border.hairline)
        )
        .accessibilityElement(children: .contain)
    }
}

/// SF Symbol for a file, by extension (design §3.1 file-type icon).
enum FileIcon {
    static func symbol(for file: WDFile) -> String {
        if file.submodule != nil { return "shippingbox" }
        if file.isDirectory { return "folder" }
        switch (file.path as NSString).pathExtension.lowercased() {
        case "swift", "c", "h", "m", "mm", "cpp", "hpp", "rs", "go", "py", "rb", "js", "ts", "tsx", "jsx", "java",
            "kt", "cs", "sh", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml", "ini", "cfg", "conf":
            return "curlybraces"
        case "md", "markdown", "txt", "rtf":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "svg", "webp", "pdf":
            return "photo"
        default:
            return "doc"
        }
    }
}
