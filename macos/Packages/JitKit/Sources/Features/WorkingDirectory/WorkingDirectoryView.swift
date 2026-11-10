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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let composer = model.composer { CommitComposerView(model: composer) }
        }
        .background { shortcuts }
        .sheet(
            item: Binding(get: { model.discardRequest }, set: { if $0 == nil { model.cancelDiscard() } })
        ) { request in
            DiscardSheet(request: request, cancel: model.cancelDiscard, confirm: model.confirmDiscard)
        }
    }

    // MARK: Header

    /// "N file changes on <branch>" with Discard All on its left; then sort, Path / Tree and the filter.
    private var header: some View {
        let count = model.session.status?.summary?.changedFiles ?? model.list.unstaged.count + model.list.staged.count
        let discardable = WorkingDirectoryModel.discardable(model.list.unstaged).count
        return VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                Button {
                    model.requestDiscardAll()
                } label: {
                    Image(systemName: "trash").symbolSize(IconSize.sm, weight: .medium)
                }
                .outlineButton(.danger)
                .disabled(discardable == 0)
                .help("Discard all unstaged changes…")
                .accessibilityLabel("Discard all unstaged changes")
                Spacer(minLength: Space.s2)
                Text("\(count) file \(count == 1 ? "change" : "changes") on")
                    .typeStyle(.body)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                Text(branchTitle)
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s1)
                    .background(
                        ColorToken.accentMuted.color, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                Spacer(minLength: Space.s2)
                if model.session.isBusy {
                    ProgressView().controlSize(.small).help("Working…")
                } else {
                    // Balances the trash button so the title stays centred.
                    Color.clear.frame(width: IconSize.lg + Space.s3, height: 1)
                }
            }
            HStack(spacing: Space.s4) {
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
                .fixedSize()
                .help("Sort by \(model.sort.title)")
                .accessibilityLabel("Sort by \(model.sort.title)")
                Picker("View", selection: $model.showsTree) {
                    Label("Path", systemImage: "list.bullet").labelStyle(.titleAndIcon).tag(false)
                    Label("Tree", systemImage: "list.bullet.indent").labelStyle(.titleAndIcon).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Paths in one list, or a folder tree")
                TextField("Filter", text: $model.filter, prompt: Text("Filter files"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($filterFocused)
                    .help("Filter files (⌥⌘F)")
                    .onExitCommand {
                        model.filter = ""
                        filterFocused = false
                    }
            }
            if let banner = model.banner {
                ErrorBanner(text: banner, canRetry: model.canRetry, retry: model.retry, dismiss: model.dismissBanner)
            }
        }
        .padding(.horizontal, Space.s5)
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
        // Each section is one container (0.0.2): its header row, its files, then a gap before the next.
        List(selection: $model.selection) {
            ForEach(WDSection.displayOrder, id: \.self) { section in
                if section != .conflicts || !model.list.conflicts.isEmpty {
                    let items = model.items(section)
                    let targeted = model.dropTarget == section
                    SectionHeader(section: section, model: model)
                        .dropTarget(section, model: model)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        .listRowInsets(Self.rowInsets)
                        .listRowBackground(SectionCardBackground(position: .top, isTargeted: targeted))
                    if items.isEmpty {
                        EmptySectionRow(section: section, filtered: !model.filter.isEmpty)
                            .dropTarget(section, model: model)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                            .listRowInsets(Self.rowInsets)
                            .listRowBackground(SectionCardBackground(position: .bottom, isTargeted: targeted))
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .frame(minHeight: 24)
                            .tag(item.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(Self.rowInsets)
                            .listRowBackground(
                                SectionCardBackground(
                                    position: index == items.count - 1 ? .bottom : .middle, isTargeted: targeted,
                                    isSelected: model.selection.contains(item.id)))
                    }
                    Color.clear
                        .frame(height: Space.s3)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityHidden(true)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Space.s3)
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

    /// Row content sits inside its section's container.
    private static let rowInsets = EdgeInsets(top: 0, leading: Space.s6, bottom: 0, trailing: Space.s6)

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
}

/// The slice of a section's container behind one list row: the top row rounds the top corners, the last
/// row the bottom ones, and the border runs around the whole section.
private struct SectionCardBackground: View {
    enum Position { case top, middle, bottom }

    let position: Position
    var isTargeted = false
    var isSelected = false

    var body: some View {
        let radius = Radius.md
        let top = position == .top ? radius : 0
        let bottom = position == .bottom ? radius : 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top,
            style: .continuous)
        ZStack {
            shape.fill(isTargeted ? ColorToken.accentMuted.color : ColorToken.surfaceRaised.color)
            if isSelected { Selection.fill }
            // The full outline, pushed past the edges this row does not own; the clip removes the rest.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline)
                .padding(.top, position == .top ? 0 : -2 * radius)
                .padding(.bottom, position == .bottom ? 0 : -2 * radius)
        }
        .clipShape(shape)
        // The list's row backgrounds run edge to edge; the container keeps a margin to the panel's sides.
        .padding(.horizontal, Space.s4)
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
            Text("\(section.title)\(section == .conflicts ? "" : " Files") (\(count))")
                .typeStyle(.headline)
                .monospacedDigit()
                .foregroundStyle(.token(.textPrimary))
            Spacer()
            switch section {
            case .staged:
                Button("Unstage All Changes") { model.unstageAll() }
                    .outlineButton(.danger)
                    .disabled(count == 0)
                    .help("Unstage every staged file")
            case .unstaged:
                Button("Stage All Changes") { model.stageAll() }
                    .outlineButton(.success)
                    .disabled(count == 0)
                    .help("Stage every unstaged file")
            case .conflicts:
                EmptyView()
            }
        }
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
            // Same look as a committed file: the whole path, folders shortened in their middle, the name whole.
            FilePathText(
                prefix: file.originalPath.map { DisplayText.sanitize(($0 as NSString).lastPathComponent) + " → " },
                directory: depth == 0 && !model.showsTree ? DisplayText.sanitize(file.directory) : "",
                name: DisplayText.sanitize(file.name)
            )
            .font(TypeToken.body.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(file.badges, id: \.self) { Badge(badge: $0) }
            // One trailing slot: the line counts at rest, the action while hovered or selected. Both are laid
            // out all the time, so the row never shifts and the button never leaves the container.
            let showsAction = file.canStageOrUnstage && (isHovered || model.selection.contains(file.id))
            ZStack(alignment: .trailing) {
                if let stats = model.stats[file.id] {
                    StatsText(stats: stats).opacity(showsAction ? 0 : 1)
                }
                if file.canStageOrUnstage {
                    Button(file.section == .staged ? "Unstage File" : "Stage File") {
                        file.section == .staged ? model.unstage([file]) : model.stage([file])
                    }
                    .outlineButton(file.section == .staged ? .danger : .success)
                    .opacity(showsAction ? 1 : 0)
                    .allowsHitTesting(showsAction)
                    .accessibilityHidden(!showsAction)
                }
            }
            .fixedSize()
            .animation(reduceMotion ? nil : MotionToken.hover.animation, value: showsAction)
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

/// How the file changed, as a glyph; a half-filled circle marks a partially staged file.
private struct StatusGlyph: View {
    let file: WDFile

    var body: some View {
        HStack(spacing: Space.s1) {
            FileChangeIcon(glyph)
            Image(systemName: "circle.lefthalf.filled")
                .symbolSize(IconSize.sm - 4)
                .foregroundStyle(.token(glyph.token))
                .opacity(file.isPartial ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private var glyph: FileChangeGlyph {
        switch file.change {
        case .added, .untracked: .added
        case .modified, .typeChanged: .modified
        case .deleted: .deleted
        case .conflicted: .conflicted
        case .renamed, .copied: .renamed
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
        let discardable = WorkingDirectoryModel.discardable(files)
        if !discardable.isEmpty {
            Button(discardable.count == 1 ? "Discard Changes…" : "Discard Changes to \(discardable.count) Files…") {
                model.requestDiscard(discardable)
            }
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
            if file.change != .deleted {
                Button("Blame") { model.openBlame(file.path) }
            }
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
