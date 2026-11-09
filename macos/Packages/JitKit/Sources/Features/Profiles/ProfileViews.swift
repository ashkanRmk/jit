import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Colored circle with initials.
struct ProfileAvatar: View {
    let profile: GitProfile
    var size: CGFloat = ProfileMetrics.avatar

    var body: some View {
        ZStack {
            Circle().fill(ProfileColor.at(profile.colorIndex).color)
            Text(profile.initials)
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.5)
                .foregroundStyle(ProfileColor.initialsColor)
                .padding(Space.s1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Toolbar profile capsule content. The toolbar item supplies the glass (system platter); with no
/// active profile the item is warning-tinted by the window controller.
struct ProfileCapsuleView: View {
    let store: ProfileStore
    let chrome: ChromeState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                if let profile = store.activeProfile {
                    ProfileAvatar(profile: profile)
                    if chrome.showsProfileName {
                        Text(profile.displayName)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                    }
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                    Text("No Profile")
                }
            }
            .padding(.horizontal, Space.s3)
            .contentShape(Capsule())
            .animation(.easeInOut(duration: MotionToken.select.duration), value: store.activeProfileID)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        guard let profile = store.activeProfile else { return "No Git profile — commits need an identity" }
        return "\(profile.author.name) <\(profile.author.email)>"
    }

    private var accessibilityText: String {
        guard let profile = store.activeProfile else { return "No profile. Choose a Git profile" }
        return "Profile \(profile.displayName), \(profile.author.email). Switch profile"
    }
}

/// The profile switcher popover (system popover glass, no custom chrome).
struct ProfileSwitcherView: View {
    let store: ProfileStore
    let newProfile: (_ prefillFromGitConfig: Bool) -> Void
    let manageProfiles: () -> Void
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if store.profiles.isEmpty {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text("Commits need an identity")
                        .typeStyle(.headline)
                    Text(
                        "Create a profile with the name and email Git should record. Jit never changes your global Git configuration."
                    )
                    .typeStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Create Profile…") { newProfile(false) }
                        .keyboardShortcut(.defaultAction)
                    Button("Fill from Git config") { newProfile(true) }
                }
            } else {
                if store.profiles.count > 6 {
                    TextField("Search Profiles", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(spacing: Space.s1) {
                    ForEach(filtered) { profile in
                        ProfileRowButton(
                            profile: profile, isActive: profile.id == store.activeProfileID
                        ) {
                            store.setActive(profile.id)
                            dismiss()
                        }
                    }
                }
                if store.activeProfile == nil {
                    Label("No profile is active. Choose one for commits.", systemImage: "exclamationmark.triangle")
                        .typeStyle(.caption)
                        .foregroundStyle(.token(.statusWarning))
                }
                Divider()
                HStack {
                    Button("New Profile…") { newProfile(false) }
                    Spacer()
                    Button("Manage Profiles…", action: manageProfiles)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(Space.s6)
        .frame(width: 320)
    }

    private var filtered: [GitProfile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.profiles }
        return store.profiles.filter {
            $0.displayName.lowercased().contains(needle) || $0.author.name.lowercased().contains(needle)
                || $0.author.email.lowercased().contains(needle)
        }
    }
}

private struct ProfileRowButton: View {
    let profile: GitProfile
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                ProfileAvatar(profile: profile, size: ProfileMetrics.largeAvatar)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(profile.displayName)
                        .typeStyle(.headline)
                        .foregroundStyle(.primary)
                    Text("\(profile.author.name) <\(profile.author.email)>")
                        .typeStyle(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s4)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(isHovered ? ColorToken.stateHover.color : .clear, in: RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(profile.displayName), \(profile.author.email), \(isActive ? "active" : "inactive")")
    }
}

/// Create/edit sheet (system sheet glass, opaque form content).
struct ProfileEditorView: View {
    let store: ProfileStore
    let engine: GitEngine
    let editing: GitProfile?
    let prefillFromGitConfig: Bool
    let finish: () -> Void

    @State private var displayName = ""
    @State private var colorIndex = 0
    @State private var authorName = ""
    @State private var authorEmail = ""
    @State private var usesCommitter = false
    @State private var committerName = ""
    @State private var committerEmail = ""
    @State private var showsCommitter = false
    @State private var fillMessage: String?
    @State private var isFilling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Profile name", text: $displayName, prompt: Text(verbatim: "Work"))
                    issueText(.displayName)
                    LabeledContent("Color") {
                        HStack(spacing: Space.s3) {
                            ForEach(ProfileColor.allCases, id: \.self) { swatch in
                                Button {
                                    colorIndex = swatch.rawValue
                                } label: {
                                    Circle()
                                        .fill(swatch.color)
                                        .frame(width: IconSize.lg, height: IconSize.lg)
                                        .overlay {
                                            if colorIndex == swatch.rawValue {
                                                Circle().strokeBorder(Selection.edge, lineWidth: 2).padding(-3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(swatch.name)
                                .accessibilityAddTraits(colorIndex == swatch.rawValue ? .isSelected : [])
                            }
                        }
                    }
                }
                Section {
                    TextField("Author name", text: $authorName, prompt: Text(verbatim: "Ada Lovelace"))
                    issueText(.authorName)
                    TextField("Author email", text: $authorEmail, prompt: Text(verbatim: "ada@example.com"))
                    issueText(.authorEmail)
                    HStack {
                        Button(isFilling ? "Reading Git config…" : "Fill from Git config", action: fillFromGitConfig)
                            .disabled(isFilling)
                        if let fillMessage {
                            Text(fillMessage)
                                .typeStyle(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Jit never changes your global Git configuration.")
                        .typeStyle(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Committer (optional)", isExpanded: $showsCommitter) {
                        Toggle("Use a different committer", isOn: $usesCommitter)
                        if usesCommitter {
                            TextField("Committer name", text: $committerName)
                            issueText(.committerName)
                            TextField("Committer email", text: $committerEmail)
                            issueText(.committerEmail)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: finish)
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create Profile" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ProfileValidation.canSave(issues))
            }
            .padding(Space.s6)
        }
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var author: GitIdentity { GitIdentity(name: authorName, email: authorEmail) }
    private var committer: GitIdentity? {
        usesCommitter ? GitIdentity(name: committerName, email: committerEmail) : nil
    }

    private var issues: [ProfileValidation.Issue] {
        ProfileValidation.validate(displayName: displayName, author: author, committer: committer)
    }

    @ViewBuilder
    private func issueText(_ field: ProfileValidation.Field) -> some View {
        // Errors show once the field has content (or another field does), so an empty form isn't red.
        if let issue = issues.first(where: { $0.field == field }), hasStartedEditing || issue.severity == .warning {
            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                .typeStyle(.caption)
                .foregroundStyle(.token(issue.severity == .error ? .statusDanger : .statusWarning))
        }
    }

    private var hasStartedEditing: Bool {
        !displayName.isEmpty || !authorName.isEmpty || !authorEmail.isEmpty || editing != nil
    }

    private func load() {
        if let editing {
            displayName = editing.displayName
            colorIndex = editing.colorIndex
            authorName = editing.author.name
            authorEmail = editing.author.email
            if let committer = editing.committer {
                usesCommitter = true
                showsCommitter = true
                committerName = committer.name
                committerEmail = committer.email
            }
        } else {
            colorIndex = store.nextColorIndex()
            if prefillFromGitConfig { fillFromGitConfig() }
        }
    }

    /// Reads `git config --global user.name/email` (read-only) and pre-fills empty fields.
    private func fillFromGitConfig() {
        isFilling = true
        Task {
            defer { isFilling = false }
            do throws(GitCoreError) {
                let identity = try await engine.readGlobalIdentity()
                if let name = identity.name, authorName.trimmingCharacters(in: .whitespaces).isEmpty {
                    authorName = name
                }
                if let email = identity.email, authorEmail.trimmingCharacters(in: .whitespaces).isEmpty {
                    authorEmail = email
                }
                if displayName.isEmpty, identity.name != nil { displayName = "Personal" }
                fillMessage =
                    identity.name == nil && identity.email == nil
                    ? "No user.name or user.email in your Git config." : nil
            } catch {
                fillMessage = error.summary
            }
        }
    }

    private func save() {
        guard ProfileValidation.canSave(issues) else { return }
        let trimmedAuthor = GitIdentity(
            name: authorName.trimmingCharacters(in: .whitespaces),
            email: authorEmail.trimmingCharacters(in: .whitespaces))
        let trimmedCommitter = committer.map {
            GitIdentity(
                name: $0.name.trimmingCharacters(in: .whitespaces), email: $0.email.trimmingCharacters(in: .whitespaces)
            )
        }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        if var profile = editing {
            profile.displayName = name
            profile.colorIndex = colorIndex
            profile.author = trimmedAuthor
            profile.committer = trimmedCommitter
            store.update(profile)
        } else {
            store.create(
                GitProfile(
                    displayName: name, colorIndex: colorIndex, author: trimmedAuthor, committer: trimmedCommitter),
                activate: store.activeProfile == nil)
        }
        finish()
    }
}

/// Presents the editor as a sheet on any window.
@MainActor
enum ProfileEditorPresenter {
    static func present(
        on window: NSWindow, store: ProfileStore, engine: GitEngine, editing: GitProfile?, prefillFromGitConfig: Bool
    ) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled], backing: .buffered,
            defer: true)
        let host = NSHostingController(
            rootView: ProfileEditorView(
                store: store, engine: engine, editing: editing, prefillFromGitConfig: prefillFromGitConfig
            ) { [weak window, weak sheet] in
                if let window, let sheet { window.endSheet(sheet) }
            })
        host.sizingOptions = .preferredContentSize
        sheet.contentViewController = host
        sheet.title = editing == nil ? "New Profile" : "Edit Profile"
        window.beginSheet(sheet)
    }
}

/// Settings ▸ Profiles: list, create, edit, activate, delete (with confirmation).
struct ProfilesSettingsView: View {
    let store: ProfileStore
    let engine: GitEngine
    @State private var selection: UUID?
    @State private var pendingDelete: GitProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            if store.activeProfile == nil {
                Label(
                    store.profiles.isEmpty
                        ? "No profiles yet. Commits need an identity — create one."
                        : "No profile is active. Select one and click Make Active.",
                    systemImage: "exclamationmark.triangle"
                )
                .typeStyle(.callout)
                .foregroundStyle(.token(.statusWarning))
            }
            List(selection: $selection) {
                ForEach(store.profiles) { profile in
                    HStack(spacing: Space.s4) {
                        ProfileAvatar(profile: profile, size: ProfileMetrics.largeAvatar)
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(profile.displayName).typeStyle(.headline)
                            Text("\(profile.author.name) <\(profile.author.email)>")
                                .typeStyle(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id == store.activeProfileID {
                            Text("Active")
                                .typeStyle(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, Space.s2)
                    .tag(profile.id)
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.bordered)
            .contextMenu(forSelectionType: UUID.self) { _ in
            } primaryAction: { ids in
                ids.first.flatMap(profile).map(edit)
            }
            HStack {
                Button("Add", systemImage: "plus") { present(nil) }
                    .labelStyle(.iconOnly)
                    .help("New Profile")
                Button("Delete", systemImage: "minus") { pendingDelete = selection.flatMap(profile) }
                    .labelStyle(.iconOnly)
                    .disabled(selection == nil)
                    .help("Delete Profile")
                Spacer()
                Button("Edit…") { selection.flatMap(profile).map(edit) }
                    .disabled(selection == nil)
                Button("Make Active") { store.setActive(selection) }
                    .disabled(selection == nil || selection == store.activeProfileID)
            }
            Text("Jit never changes your global Git configuration. Profiles apply only to commits Jit makes.")
                .typeStyle(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Space.s7)
        .frame(width: 560, height: 420)
        .confirmationDialog(
            "Delete the profile “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { profile in
            Button("Delete Profile", role: .destructive) {
                store.delete(id: profile.id)
                selection = nil
            }
        } message: { profile in
            Text(
                profile.id == store.activeProfileID
                    ? "It is the active profile. After deleting it no profile will be active until you choose one. Your Git configuration is not affected."
                    : "This removes the identity from Jit. Your Git configuration and repositories are not affected.")
        }
    }

    private func profile(_ id: UUID) -> GitProfile? { store.profiles.first { $0.id == id } }

    private func edit(_ profile: GitProfile) { present(profile) }

    private func present(_ profile: GitProfile?) {
        guard let window = NSApp.keyWindow else { return }
        ProfileEditorPresenter.present(
            on: window, store: store, engine: engine, editing: profile, prefillFromGitConfig: false)
    }
}
