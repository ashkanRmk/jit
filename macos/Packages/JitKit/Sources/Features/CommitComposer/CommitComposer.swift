import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// The commit composer (design §3.6): message fields with drafts per repository, amend with its warnings,
/// identity from the active profile captured at Commit, hook output, and the reasons Commit is disabled.
@MainActor @Observable
final class CommitComposerModel {
    let session: RepositorySession
    let profiles: ProfileStore
    @ObservationIgnored let drafts: CommitDrafts

    var summary = "" { didSet { if summary != oldValue { draftChanged() } } }
    var details = "" { didSet { if details != oldValue { draftChanged() } } }
    var amend = false { didSet { if amend != oldValue { amendChanged() } } }
    var resetAuthor = false
    private(set) var context = CommitContext()
    private(set) var isCommitting = false
    /// The check glyph after a successful commit (600 ms, then settles).
    private(set) var justCommitted = false
    private(set) var error: String?
    /// Git's and the hooks' output of the last commit attempt.
    private(set) var output: String?

    @ObservationIgnored private var savedDraft = CommitDrafts.Draft()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadedFor: String?
    /// After a commit: select it in the graph.
    @ObservationIgnored var onCommitted: (String) -> Void = { _ in }

    init(session: RepositorySession, profiles: ProfileStore, drafts: CommitDrafts) {
        self.session = session
        self.profiles = profiles
        self.drafts = drafts
    }

    var repositoryKey: String { session.info?.topLevel ?? session.path }

    /// Called when the working-directory panel shows: restores the draft once, refreshes HEAD facts.
    func activate() {
        if loadedFor != repositoryKey {
            loadedFor = repositoryKey
            let draft = drafts.draft(for: repositoryKey)
            summary = draft.summary
            details = draft.description
        }
        refreshContext()
    }

    private func refreshContext() {
        Task { [weak self] in
            guard let self else { return }
            self.context = await self.session.commitContext()
        }
    }

    private func draftChanged() {
        guard !amend else { return }
        saveTask?.cancel()
        let draft = CommitDrafts.Draft(summary: summary, description: details)
        let key = repositoryKey
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.drafts.save(draft, for: key)
        }
    }

    private func amendChanged() {
        if amend {
            savedDraft = CommitDrafts.Draft(summary: summary, description: details)
            let message = context.headMessage ?? ""
            let parts = message.components(separatedBy: "\n\n")
            summary = parts.first ?? ""
            details = parts.dropFirst().joined(separator: "\n\n")
        } else {
            resetAuthor = false
            summary = savedDraft.summary
            details = savedDraft.description
        }
    }

    // MARK: State

    var profile: GitProfile? { profiles.activeProfile }
    var stagedCount: Int { session.status?.summary?.staged ?? 0 }
    var hasConflicts: Bool { (session.status?.summary?.conflicted ?? 0) > 0 }

    /// "Committing as … " note when the repository's own `user.email` differs.
    var configNote: String? {
        guard let profile, let configured = context.configuredEmail,
            configured.caseInsensitiveCompare(profile.author.email) != .orderedSame
        else { return nil }
        return "Repository config says \(configured) — Jit will use the active profile."
    }

    var showsResetAuthor: Bool {
        guard amend, let author = context.headAuthor, let profile else { return false }
        return author.email.caseInsensitiveCompare(profile.author.email) != .orderedSame
            || author.name != profile.author.name
    }

    /// Why Commit is disabled, or `nil` when it can run.
    var disabledReason: String? {
        if isCommitting || session.isBusy { return "Another operation is running." }
        if profile == nil { return "Choose a profile to commit." }
        if hasConflicts { return "Resolve the conflicts first." }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a summary." }
        if stagedCount == 0 && !amend { return "Stage the changes to commit first." }
        return nil
    }

    var commitTitle: String {
        if amend { return "Amend Commit" }
        return stagedCount == 1 ? "Commit 1 File" : "Commit \(stagedCount) Files"
    }

    var message: String {
        let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
    }

    // MARK: Commit

    /// Captures the identity now (a profile switch while Git runs changes nothing) and commits.
    func commit(noVerify: Bool = false) {
        guard disabledReason == nil, let profile else { return }
        let snapshot = ProfileSnapshot(profile)
        let request = CommitRequest(
            message: message, amend: amend, resetAuthor: amend && resetAuthor, noVerify: noVerify,
            identity: IdentitySnapshot(author: snapshot.author, committer: snapshot.committer))
        isCommitting = true
        error = nil
        output = nil
        let session = self.session
        Task { [weak self] in
            do throws(GitCoreError) {
                let outcome = try await session.commit(request)
                guard let self else { return }
                self.isCommitting = false
                self.output =
                    outcome.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : outcome.output
                self.saveTask?.cancel()
                self.amend = false
                self.summary = ""
                self.details = ""
                self.savedDraft = CommitDrafts.Draft()
                self.drafts.save(CommitDrafts.Draft(), for: self.repositoryKey)
                self.justCommitted = true
                self.onCommitted(outcome.commitID)
                self.refreshContext()
                try? await Task.sleep(for: .milliseconds(600))
                self.justCommitted = false
            } catch {
                guard let self else { return }
                self.isCommitting = false
                self.error = error.summary
                self.output = error.detail
            }
        }
    }
}

/// Pinned at the bottom of the working-directory panel (design §3.6): fields on opaque surfaces, the
/// identity line and Commit button in a glass action bar.
struct CommitComposerView: View {
    @Bindable var model: CommitComposerModel
    @State private var showsOutput = false
    @State private var confirmsNoVerify = false
    @FocusState private var summaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fields
                .padding(Space.s5)
                .background(ColorToken.surfacePanel.color)
            actionBar
        }
        .onAppear { model.activate() }
        .alert("Commit without running hooks?", isPresented: $confirmsNoVerify) {
            Button("Cancel", role: .cancel) {}
            Button("Commit Without Hooks") { model.commit(noVerify: true) }
        } message: {
            Text(
                "The repository’s pre-commit and commit-msg hooks (checks, formatters) will be skipped for this commit only."
            )
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Summary", text: $model.summary)
                    .textFieldStyle(.roundedBorder)
                    .focused($summaryFocused)
                    .accessibilityLabel("Commit summary")
                if model.summary.count > 50 {
                    Text("\(model.summary.count)")
                        .typeStyle(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.token(model.summary.count > 72 ? .statusWarning : .textTertiary))
                        .help(model.summary.count > 72 ? "Summaries longer than 72 characters are often cut off" : "")
                        .accessibilityLabel("\(model.summary.count) characters")
                }
            }
            TextField("Description", text: $model.details, axis: .vertical)
                .lineLimit(2...8)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Commit description")
            Toggle("Amend last commit", isOn: $model.amend)
                .toggleStyle(.checkbox)
                .disabled(model.context.headMessage == nil)
                .help(model.context.headMessage == nil ? "There is no commit to amend yet" : "Edit the last commit")
            if model.amend && model.context.headIsInUpstream {
                Label(
                    "This commit is already on the upstream branch. Amending rewrites it; pushing will then require a force push.",
                    systemImage: "exclamationmark.triangle"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.statusWarning))
                .fixedSize(horizontal: false, vertical: true)
            }
            if model.showsResetAuthor, let profile = model.profile {
                Toggle("Reset author to \(profile.author.name)", isOn: $model.resetAuthor)
                    .toggleStyle(.checkbox)
                    .typeStyle(.callout)
            }
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.statusDanger))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let output = model.output {
                DisclosureGroup("Hook output", isExpanded: $showsOutput) {
                    ScrollView {
                        Text(DisplayText.sanitize(output, keepNewlines: true))
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.token(.textSecondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .typeStyle(.caption)
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if let profile = model.profile {
                HStack(spacing: Space.s3) {
                    Circle()
                        .fill(ProfileColor.at(profile.colorIndex).color)
                        .frame(width: IconSize.md, height: IconSize.md)
                        .overlay(Text(profile.initials).typeStyle(.micro).foregroundStyle(ProfileColor.initialsColor))
                        .accessibilityHidden(true)
                    Text(
                        "Committing as \(Text(profile.author.name).bold()) <\(profile.author.email)> · \(profile.displayName)"
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture { NSApp.sendAction(Selector(("showProfileSwitcher:")), to: nil, from: nil) }
                .help("Change profile")
                if let note = model.configNote {
                    Text(note)
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.textTertiary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button("Choose a profile to commit") {
                    NSApp.sendAction(Selector(("showProfileSwitcher:")), to: nil, from: nil)
                }
                .buttonStyle(.link)
            }
            HStack(spacing: Space.s3) {
                Spacer()
                Menu {
                    Button("Commit Without Running Hooks…") { confirmsNoVerify = true }
                        .disabled(model.disabledReason != nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .secondaryGlassButton()
                .fixedSize()
                .accessibilityLabel("More commit options")
                Button {
                    model.commit()
                } label: {
                    HStack(spacing: Space.s3) {
                        if model.isCommitting {
                            ProgressView().controlSize(.small)
                        } else if model.justCommitted {
                            Image(systemName: "checkmark")
                        }
                        Text(model.commitTitle)
                    }
                }
                .primaryGlassButton()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.disabledReason != nil)
                .help(model.disabledReason ?? "\(model.commitTitle) (⌘↩)")
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle().fill(.clear).jitGlass(in: Rectangle(), interactive: false)
        }
    }
}
