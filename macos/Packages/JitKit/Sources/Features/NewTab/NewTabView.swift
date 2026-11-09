import DesignSystem
import Services
import SwiftUI

struct NewTabActions {
    var open: () -> Void
    var openPath: (String) -> Void
    var locate: (String) -> Void
    var reveal: (String) -> Void
}

/// The new-tab page (design §3.2): opaque content under the glass toolbar. One primary glass action,
/// an opaque recents list, and nothing that doesn't work yet (no Clone or provider browsing).
struct NewTabView: View {
    let model: AppModel
    let actions: NewTabActions

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s9) {
                VStack(spacing: Space.s5) {
                    Text("Jit")
                        .typeStyle(.title)
                        .foregroundStyle(.token(.textTertiary))
                        .accessibilityHidden(true)
                    Button("Open Repository…", action: actions.open)
                        .primaryGlassButton()
                        .controlSize(.extraLarge)
                        .help("Open a repository (⌘O)")
                    Text("Choose a folder with a Git repository, or drag one onto this window.")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.textSecondary))
                        .multilineTextAlignment(.center)
                }
                RecentsSection(recents: model.recents, actions: actions)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Space.s9)
            .padding(.top, Space.s10 * 2)
            .padding(.bottom, Space.s10)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(ColorToken.surfaceCanvas.color.ignoresSafeArea())
        .task { await model.recents.refreshMissing() }
    }
}

private struct RecentsSection: View {
    let recents: RecentsStore
    let actions: NewTabActions
    @State private var selection: String?
    @Environment(\.undoManager) private var undoManager

    static let visibleCount = 12
    static let rowHeight: CGFloat = 52

    var body: some View {
        let entries = Array(recents.entries.prefix(Self.visibleCount))
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Recent")
                .typeStyle(.micro)
                .foregroundStyle(.token(.textTertiary))
                .padding(.leading, Space.s4)
            if entries.isEmpty {
                Text("Repositories you open will appear here.")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.leading, Space.s4)
            } else {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        RecentRow(
                            entry: entry, isMissing: recents.missingPaths.contains(entry.path),
                            reveal: { actions.reveal(entry.path) },
                            remove: { remove(entry.path) },
                            locate: { actions.locate(entry.path) }
                        )
                        .tag(entry.path)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(entries.count) * Self.rowHeight + Space.s4)
                .contextMenu(forSelectionType: String.self) { paths in
                    if let path = paths.first {
                        Button("Open") { open(path) }
                        Button("Reveal in Finder") { actions.reveal(path) }
                        Divider()
                        Button("Remove from Recents") { remove(path) }
                    }
                } primaryAction: { paths in
                    paths.first.map(open)
                }
                .onDeleteCommand { selection.map(remove) }
                .accessibilityLabel("Recent repositories")
                .contentCard(padding: Space.s3)
            }
        }
    }

    private func open(_ path: String) {
        if recents.missingPaths.contains(path) {
            actions.locate(path)
        } else {
            actions.openPath(path)
        }
    }

    /// ⌫ removes; ⌘Z puts it back at the same position.
    private func remove(_ path: String) {
        guard let removed = recents.remove(path: path) else { return }
        undoManager?.registerUndo(withTarget: recents) { store in
            MainActor.assumeIsolated { store.restore(removed.entry, at: removed.index) }
        }
        undoManager?.setActionName("Remove from Recents")
    }
}

private struct RecentRow: View {
    let entry: RecentsStore.Entry
    let isMissing: Bool
    let reveal: () -> Void
    let remove: () -> Void
    let locate: () -> Void
    @State private var isHovered = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        // Formatted once per render — never a live-updating (timer-driven) relative date.
        let opened = Self.relative.localizedString(for: entry.lastOpened, relativeTo: Date())
        HStack(spacing: Space.s5) {
            Image(systemName: isMissing ? "questionmark.folder" : "folder")
                .symbolSize(IconSize.md)
                .foregroundStyle(.token(isMissing ? .textDisabled : .textTertiary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s4) {
                    Text(entry.name)
                        .typeStyle(.headline)
                        .foregroundStyle(.token(isMissing ? .textDisabled : .textPrimary))
                    if let branch = entry.lastBranch, !isMissing {
                        Text(branch)
                            .typeStyle(.callout)
                            .foregroundStyle(.token(.textSecondary))
                            .lineLimit(1)
                    }
                }
                Text(isMissing ? "Not found — \(entry.path)" : entry.path)
                    .typeStyle(.monoCaption)
                    .foregroundStyle(.token(isMissing ? .textDisabled : .textTertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.s4)
            if isMissing {
                Button("Locate…", action: locate).controlSize(.small)
                Button("Remove", action: remove).controlSize(.small)
            } else if isHovered {
                Button("Reveal in Finder", systemImage: "magnifyingglass", action: reveal)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                Button("Remove from Recents", systemImage: "xmark.circle", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove from Recents (⌫)")
            } else {
                Text(opened)
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textTertiary))
            }
        }
        .frame(height: RecentsSection.rowHeight - Space.s3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isMissing ? "\(entry.name), not found, \(entry.path)" : "\(entry.name), \(entry.path), opened \(opened)")
    }
}
