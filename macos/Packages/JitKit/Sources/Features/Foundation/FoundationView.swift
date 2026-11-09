import DesignSystem
import GitCore
import SwiftUI
import UniformTypeIdentifiers

/// The Phase 0 window: opaque content under the system glass toolbar, showing what `GitCore`
/// discovered about a folder.
public struct FoundationView: View {
    @Bindable var model: FoundationModel
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: FoundationModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Space.s8) {
                content
            }
            .frame(maxWidth: PanelMetrics.contentColumnMax)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Space.s9)
            .padding(.vertical, Space.s10)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(ColorToken.surfaceCanvas.color.ignoresSafeArea())
        .overlay { if isDropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open…", systemImage: "folder") { model.presentOpenPanel() }
                    .help("Open a repository (⌘O)")
            }
        }
        .navigationTitle(title)
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): model.open(url)
            case let .failure(error): model.importFailed(error)
            }
        }
        .animation(MotionToken.panel.animation, value: model.state)
    }

    private var title: String {
        if case let .loaded(info, _) = model.state { return info.displayName }
        return "Jit"
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .empty:
            EmptyStateView { model.presentOpenPanel() }
                .transition(RevealTransition.transition(reduceMotion: reduceMotion))
        case let .loading(_, showsIndicator):
            LoadingView(isVisible: showsIndicator)
        case let .loaded(info, git):
            VStack(spacing: Space.s6) {
                RepositoryCard(info: info, git: git)
                Button("Open Another…") { model.presentOpenPanel() }
                    .secondaryGlassButton()
                    .controlSize(.large)
            }
            .transition(RevealTransition.transition(reduceMotion: reduceMotion))
        case let .failed(url, error):
            ErrorStateView(url: url, error: error) { model.presentOpenPanel() }
                .transition(RevealTransition.transition(reduceMotion: reduceMotion))
        }
    }
}

// MARK: - States

private struct EmptyStateView: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: Space.s5) {
            Image(systemName: "folder.badge.gearshape")
                .symbolSize(IconSize.hero, weight: .light)
                .foregroundStyle(.token(.textTertiary))
                .padding(.bottom, Space.s2)
                .accessibilityHidden(true)
            Text("Open a Repository")
                .typeStyle(.title)
                .foregroundStyle(.token(.textPrimary))
            Text("Choose a folder that contains a Git repository, or drag one onto this window.")
                .typeStyle(.body)
                .foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Repository…", action: open)
                .primaryGlassButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Space.s4)
        }
    }
}

private struct LoadingView: View {
    let isVisible: Bool

    var body: some View {
        VStack(spacing: Space.s4) {
            ProgressView().controlSize(.small)
            Text("Reading repository…")
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
    }
}

private struct RepositoryCard: View {
    let info: RepositoryInfo
    let git: GitExecutable

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(kindLabel)
                    .typeStyle(.micro)
                    .foregroundStyle(.token(.textTertiary))
                Text(info.displayName)
                    .typeStyle(.display)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(info.topLevel ?? info.gitDirectory)
                    .typeStyle(.monoCaption)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(info.topLevel ?? info.gitDirectory)
            }

            Rectangle().fill(ColorToken.borderSubtle.color).frame(height: Border.hairline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s6, verticalSpacing: Space.s4) {
                headRows
                InfoRow(label: "Git directory", value: info.gitDirectory, monospaced: true)
                if info.kind == .linkedWorktree {
                    InfoRow(label: "Main repository", value: info.commonDirectory, monospaced: true)
                }
                InfoRow(label: "Git", value: "\(git.version.displayString) · \(git.source.rawValue)")
                InfoRow(label: "Executable", value: git.path, monospaced: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository \(info.displayName)")
    }

    private var kindLabel: String {
        switch info.kind {
        case .regular: "Repository"
        case .bare: "Bare repository"
        case .linkedWorktree: "Linked worktree"
        }
    }

    @ViewBuilder private var headRows: some View {
        switch info.head {
        case let .branch(name, commit):
            InfoRow(label: "Branch", value: name)
            InfoRow(label: "Commit", value: commit, monospaced: true)
        case let .detached(commit):
            InfoRow(label: "HEAD", value: "Detached")
            InfoRow(label: "Commit", value: commit, monospaced: true)
        case let .unborn(branch):
            InfoRow(label: "Branch", value: branch)
            InfoRow(label: "Commit", value: "No commits yet")
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow {
            Text(label)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textTertiary))
                .gridColumnAlignment(.trailing)
            Text(value)
                .typeStyle(monospaced ? .monoCaption : .body)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ErrorStateView: View {
    let url: URL?
    let error: GitCoreError
    let chooseAnother: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolSize(IconSize.md)
                    .foregroundStyle(.token(.statusDanger))
                    .accessibilityHidden(true)
                Text(error.summary)
                    .typeStyle(.title)
                    .foregroundStyle(.token(.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url {
                Text(url.path)
                    .typeStyle(.monoCaption)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let guidance {
                Text(guidance)
                    .typeStyle(.body)
                    .foregroundStyle(.token(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = error.detail {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    Text(detail)
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textSecondary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s4)
                        .background(
                            ColorToken.surfaceSunken.color,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .typeStyle(.callout)
            }
            Button("Choose Another Folder…", action: chooseAnother)
                .primaryGlassButton()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .onAppear {
            AccessibilityNotification.Announcement(error.summary).post()
        }
    }

    private var guidance: String? {
        switch error {
        case .gitNotFound:
            "Install the Xcode Command Line Tools (run “xcode-select --install” in Terminal) or Git from Homebrew, then try again."
        case let .gitTooOld(found, required):
            "This Mac has Git \(found). Install Git \(required) or newer — for example from Homebrew — then try again."
        case .unsafeRepository:
            "Git protects you from repositories owned by other users. If you trust this folder, you can allow it with “git config --global --add safe.directory <path>”. Jit never changes this setting for you."
        case .permissionDenied:
            "Check the folder's permissions in Finder (Get Info → Sharing & Permissions)."
        case .notARepository:
            "Pick the folder that contains your project's .git folder, or any folder inside it."
        default:
            nil
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Selection.edge, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Selection.fill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .padding(Space.s5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
