import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Over the graph: the repository's error, or the first-load placeholder; nothing (and no hit
/// testing) once the repository is open.
struct SessionStateOverlay: View {
    let session: RepositorySession
    let tab: TabModel
    let actions: WorkbenchActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let error = session.error {
                ScrollView {
                    RepositoryErrorView(error: error, path: session.path, actions: actions)
                        .frame(maxWidth: PanelMetrics.contentColumnMax)
                        .padding(Space.s9)
                        .frame(maxWidth: .infinity)
                }
                .background(ColorToken.surfaceCanvas.color.ignoresSafeArea())
                .transition(RevealTransition.transition(reduceMotion: reduceMotion))
            } else if session.info == nil || session.status == nil {
                DelayedLoadingPlaceholder(title: tab.title, isLoading: session.lifecycle == .loading)
                    .background(ColorToken.surfaceCanvas.color.ignoresSafeArea())
            } else {
                Color.clear.allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : MotionToken.panel.animation, value: session.error != nil)
    }
}

struct OperationChip: View {
    let title: String

    static func title(for operation: OperationState) -> String? {
        switch operation {
        case .none: nil
        case .merging: "Merging"
        case .rebasing(let step?, let total?): "Rebasing \(step)/\(total)"
        case .rebasing: "Rebasing"
        case .cherryPicking: "Cherry-picking"
        case .reverting: "Reverting"
        case .bisecting: "Bisecting"
        case .applyingMailbox: "Applying patches"
        }
    }

    var body: some View {
        Text(title)
            .typeStyle(.caption)
            .foregroundStyle(.token(.statusWarning))
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s1)
            .background(ColorToken.statusWarning.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(ColorToken.statusWarning.color.opacity(0.4), lineWidth: Border.hairline))
            .accessibilityLabel("Operation in progress: \(title)")
    }
}

/// A static, faint placeholder that appears only if loading takes longer than 150 ms (no shimmer).
/// Only while a load is actually running does it show a (system) progress indicator; a tab waiting for the
/// window to come to the front shows static text, so nothing animates while Jit is idle.
struct DelayedLoadingPlaceholder: View {
    let title: String
    let isLoading: Bool
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: Space.s4) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(isLoading ? "Reading \(title)…" : "\(title) loads when Jit is in front.")
                .typeStyle(.callout)
                .foregroundStyle(.token(.textTertiary))
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: OverlayMetrics.loadingPlaceholderDelay)
            if !Task.isCancelled { isVisible = true }
        }
    }
}

/// Error state with recovery actions: Locate…, Remove Tab, Retry.
struct RepositoryErrorView: View {
    let error: GitCoreError
    let path: String
    let actions: WorkbenchActions
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
            Text(path)
                .typeStyle(.monoCaption)
                .foregroundStyle(.token(.textSecondary))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let guidance = ErrorGuidance.text(for: error) {
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
            HStack(spacing: Space.s4) {
                Button("Retry", action: actions.retry)
                    .keyboardShortcut(.defaultAction)
                if error.isGitRuntimeProblem {
                    Button("Git Settings…") {
                        NSApp.sendAction(Selector(("showSettingsGit:")), to: nil, from: nil)
                    }
                } else {
                    Button("Locate…", action: actions.locate)
                }
                Button("Remove Tab", role: .destructive, action: actions.removeTab)
            }
            .controlSize(.large)
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .onAppear { AccessibilityNotification.Announcement(error.summary).post() }
    }
}

extension GitCoreError {
    /// Jit has no usable Git (the fix is in Settings ▸ Git, not in the repository).
    var isGitRuntimeProblem: Bool {
        switch self {
        case .gitNotFound, .gitTooOld: true
        default: false
        }
    }
}

/// Plain-language recovery guidance per error.
enum ErrorGuidance {
    static func text(for error: GitCoreError) -> String? {
        switch error {
        case .gitNotFound:
            "The Git that comes with Jit couldn't be used. Open Settings ▸ Git to choose another Git or install the Command Line Tools, then try again."
        case let .gitTooOld(found, required):
            "The selected Git is version \(found). Open Settings ▸ Git to choose Git \(required) or newer, or switch back to the Git that comes with Jit."
        case .unsafeRepository:
            "Git protects you from repositories owned by other users. If you trust this folder, you can allow it with “git config --global --add safe.directory <path>”. Jit never changes this setting for you."
        case .permissionDenied:
            "Check the folder's permissions in Finder (Get Info → Sharing & Permissions)."
        case .notARepository:
            "Pick the folder that contains your project's .git folder, or any folder inside it."
        case .pathNotFound:
            "The folder may have been moved, renamed, deleted, or its disk ejected. Use Locate… to point Jit at its new location."
        default:
            nil
        }
    }
}
