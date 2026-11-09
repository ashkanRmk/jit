import AppKit
import DesignSystem
import SwiftUI

/// ⌘K palette content (design §3.1): one Liquid Glass container (Reduce Transparency → opaque elevated
/// surface via `jitGlass`), a search field, and results with system label colors. No glass per row.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static let width: CGFloat = 620
    static let listMaxHeight: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            field
            if showsList {
                Divider()
                list
            }
        }
        .frame(width: Self.width)
        .jitGlass(in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous), interactive: false)
        .overlay {
            // Increase Contrast / Reduce Transparency: the elevated surface keeps a visible edge.
            if contrast == .increased || reduceTransparency {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(ColorToken.borderStrong.color, lineWidth: Border.emphasis)
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var showsList: Bool {
        !model.rows.isEmpty || !model.query.isEmpty || model.isIndexingFiles || model.fileIndexError != nil
    }

    private var field: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "magnifyingglass")
                .symbolSize(IconSize.lg)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search commands, branches, files, repositories", text: $model.query)
                .textFieldStyle(.plain)
                .typeStyle(.title)
                .focused($fieldFocused)
                .accessibilityLabel("Command palette search")
                .onKeyPress(.upArrow) {
                    model.move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.move(1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.close()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    model.execute(secondary: press.modifiers.contains(.command))
                    return .handled
                }
            if model.query.isEmpty {
                Text("> commands  @ refs  / files  # repos  : commit")
                    .typeStyle(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s5)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.isIndexingFiles {
                        statusRow("Indexing files…", symbol: "hourglass")
                    }
                    if let error = model.fileIndexError {
                        statusRow("Files unavailable — \(error)", symbol: "exclamationmark.circle")
                    }
                    if model.rows.isEmpty, !model.query.isEmpty, !model.isIndexingFiles {
                        statusRow(
                            "No matches for “\(model.query)”. Try a prefix: > commands, @ branches, / files.",
                            symbol: "questionmark.circle")
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if showsHeader(at: index) {
                            Text(row.entry.source.title)
                                .typeStyle(.micro)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.s6)
                                .padding(.top, index == 0 ? Space.s4 : Space.s5)
                                .padding(.bottom, Space.s2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        PaletteRowView(row: row, isSelected: index == model.selected)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.select(index); model.execute()
                            }
                    }
                    if model.fileIndexTruncated, PaletteRanker.scope(of: model.query).0 == .file {
                        statusRow("Showing the first 100,000 tracked files.", symbol: "info.circle")
                    }
                }
                .padding(.bottom, Space.s4)
            }
            .frame(maxHeight: Self.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Results")
            .onChange(of: model.selected) { _, selected in
                // Instant: the highlight moves without animation (design §3.1).
                if model.rows.indices.contains(selected) { proxy.scrollTo(model.rows[selected].id) }
            }
        }
    }

    /// Section headers only when results mix sources.
    private func showsHeader(at index: Int) -> Bool {
        let rows = model.rows
        guard Set(rows.map(\.entry.source)).count > 1 else { return false }
        return index == 0 || rows[index - 1].entry.source != rows[index].entry.source
    }

    private func statusRow(_ text: String, symbol: String) -> some View {
        HStack(spacing: Space.s4) {
            Image(systemName: symbol).symbolSize(IconSize.md).foregroundStyle(.secondary)
            Text(text).typeStyle(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.s6)
        .padding(.vertical, Space.s4)
        .accessibilityElement(children: .combine)
    }
}

/// A result row: icon, title with matched characters in a heavier weight, muted secondary line, shortcut glyphs.
private struct PaletteRowView: View {
    let row: PaletteRow
    let isSelected: Bool

    var body: some View {
        let entry = row.entry
        HStack(spacing: Space.s5) {
            Image(systemName: entry.symbol)
                .symbolSize(IconSize.md)
                .foregroundStyle(entry.isEnabled ? .secondary : .tertiary)
                .frame(width: IconSize.lg)
            VStack(alignment: .leading, spacing: Space.s1) {
                title(entry)
                    .typeStyle(.body)
                    .foregroundStyle(entry.isEnabled ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.disabledReason ?? entry.subtitle)
                    .typeStyle(.caption)
                    .foregroundStyle(entry.isEnabled ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.s4)
            if isSelected, entry.isEnabled, let secondary = entry.secondaryTitle {
                Text("⌘↩ \(secondary)")
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.shortcut.isEmpty {
                Text(entry.shortcut)
                    .typeStyle(.monoCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s1)
                    .background(ColorToken.stateHover.color, in: RoundedRectangle(cornerRadius: Radius.xs))
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Selection.fill)
            }
        }
        .padding(.horizontal, Space.s3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Matched characters in semibold (emphasis by weight, not color alone).
    private func title(_ entry: PaletteEntry) -> Text {
        guard !row.matched.isEmpty else { return Text(entry.title) }
        var result = AttributedString()
        var offset = 0
        for character in entry.title {
            var piece = AttributedString(String(character))
            let width = character.utf16.count
            if row.matched.contains(offset) { piece.font = TypeToken.headline.font }
            result += piece
            offset += width
        }
        return Text(result)
    }
}
