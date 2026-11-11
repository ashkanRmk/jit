import AppKit
import DesignSystem
import Services
import SwiftUI

/// The toolbar's bell (ADR-0051): a standard toolbar item at the trailing end. A badge shows while a newer
/// release is known; a click opens the change log. Nothing animates.
struct UpdateBellView: View {
    let updates: UpdateService
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Group {
                if updates.hasUpdate {
                    Image(systemName: "bell.badge")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.token(.accentBase), .token(.textSecondary))
                } else {
                    Image(systemName: "bell").foregroundStyle(.token(.textSecondary))
                }
            }
            .padding(.horizontal, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("What's New")
        .accessibilityValue(help)
    }

    private var help: String {
        switch updates.phase {
        case .available(let release): "Jit \(release.version) is available"
        case .downloading(let release): "Downloading Jit \(release.version)"
        case .ready(let release): "Jit \(release.version) installs when you quit"
        case .idle, .checking, .upToDate, .failed: "What's New and updates"
        }
    }
}

/// The change log (ADR-0051): what each release changed, the state of the updater, and its one switch.
struct UpdatesSheet: View {
    let updates: UpdateService
    @Bindable var preferences: PreferencesStore
    let openPage: (URL) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s4) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("What's New").typeStyle(.title)
                    Text(installedLine).typeStyle(.callout).foregroundStyle(.token(.textSecondary))
                }
                status
            }
            .padding(Space.s6)
            Divider()
            changeLog
            Divider()
            HStack(spacing: Space.s4) {
                Toggle("Update automatically", isOn: $preferences.updatesAutomatically)
                    .help(
                        "Checks GitHub at most once a day, downloads a newer release and installs it when you quit Jit"
                    )
                Spacer()
                Button("Check for Updates") { Task { await updates.check() } }
                    .disabled(updates.isBusy || updates.fetcher == nil || isReady)
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(Space.s6)
        }
        .frame(width: 580, height: 600)
    }

    private var isReady: Bool {
        if case .ready = updates.phase { return true }
        return false
    }

    private var installedLine: String {
        guard let version = updates.currentVersion else { return "Development build" }
        return "Jit \(version) is installed"
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch updates.phase {
        case .idle:
            statusRow(symbol: "clock", tint: .textSecondary, text: lastCheckedLine)
        case .checking:
            statusRow(progress: true, text: "Checking for updates…")
        case .upToDate:
            statusRow(symbol: "checkmark.circle", tint: .statusSuccess, text: "This is the newest version.")
        case .available(let release):
            statusRow(symbol: "arrow.down.circle", tint: .accentBase, text: "Jit \(release.version) is available.") {
                if release.isInstallable, updates.installer != nil {
                    Button("Install and Restart") {
                        Task { await updates.install(release, relaunchWhenReady: true) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Release Page") { openPage(release.pageURL) }
                }
            }
        case .downloading(let release):
            statusRow(progress: true, text: "Downloading and checking Jit \(release.version)…")
        case .ready(let release):
            statusRow(
                symbol: "checkmark.circle", tint: .statusSuccess,
                text: "Jit \(release.version) is ready. It is installed when you quit Jit."
            ) {
                Button("Restart Now") { updates.relaunchToUpdate() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            statusRow(symbol: "exclamationmark.triangle", tint: .statusWarning, text: message) {
                Button("Open Release Page") { openPage(updates.newerRelease?.pageURL ?? updates.releasesPageURL) }
            }
        }
    }

    private var lastCheckedLine: String {
        guard let date = updates.lastChecked else {
            return "Jit hasn't looked for updates yet. Nothing is requested until you check."
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private func statusRow(
        symbol: String? = nil, tint: ColorToken = .textSecondary, progress: Bool = false, text: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: Space.s4) {
            if progress {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(.token(tint))
            }
            Text(text)
                .typeStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Change log

    @ViewBuilder private var changeLog: some View {
        if updates.releases.isEmpty {
            VStack(spacing: Space.s3) {
                Image(systemName: "doc.text").foregroundStyle(.token(.textTertiary))
                Text("No release notes yet").typeStyle(.headline)
                Text("Check for Updates loads the change log from Jit's releases on GitHub.")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
                    .multilineTextAlignment(.center)
            }
            .padding(Space.s8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ColorToken.surfaceCanvas.color)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s6) {
                    ForEach(updates.releases) { release in
                        ReleaseNotesView(
                            release: release, isCurrent: updates.isCurrent(release), isNewer: updates.isNewer(release))
                        if release.id != updates.releases.last?.id { Divider() }
                    }
                }
                .padding(Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ColorToken.surfaceCanvas.color)
        }
    }
}

/// One release in the change log: title, date, a New / Installed mark and its notes.
struct ReleaseNotesView: View {
    let release: AppRelease
    let isCurrent: Bool
    let isNewer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                Text(release.title).typeStyle(.title).accessibilityAddTraits(.isHeader)
                if isNewer {
                    mark("New", .accentBase)
                } else if isCurrent {
                    mark("Installed", .textSecondary)
                }
                Spacer()
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                }
            }
            let blocks = ReleaseNotes.blocks(from: release.notes)
            if blocks.isEmpty {
                Text("No notes for this release.").typeStyle(.body).foregroundStyle(.token(.textSecondary))
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, _):
                    Text(Self.inline(text))
                        .typeStyle(.headline)
                        .padding(.top, Space.s2)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    Text(Self.inline(text)).typeStyle(.body).fixedSize(horizontal: false, vertical: true)
                case .bullet(let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                        Text(verbatim: "•").typeStyle(.body).foregroundStyle(.token(.textTertiary))
                        Text(Self.inline(text)).typeStyle(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, Space.s4 + CGFloat(indent) * Space.s6)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func mark(_ text: String, _ tint: ColorToken) -> some View {
        Text(text)
            .typeStyle(.caption)
            .foregroundStyle(.token(tint))
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .overlay(Capsule().strokeBorder(.token(tint), lineWidth: Border.hairline))
    }

    /// Bold, code and links inside a line; anything Markdown can't read is shown as written.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
