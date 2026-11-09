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

/// The profile switcher popover (design §3.1): system popover glass, plain rows with system-style selection, the
/// active profile's identity and sign-in summary, status dots, search above seven profiles, footer actions in
/// one glass control group. Switching is one click and never changes any Git or SSH configuration.
struct ProfileSwitcherView: View {
    let store: ProfileStore
    let newProfile: (_ prefillFromGitConfig: Bool) -> Void
    let editProfile: (GitProfile) -> Void
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
                        "Profiles combine who you commit as with how you sign in to remotes. Jit never changes your global Git configuration."
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
                if let active = store.activeProfile {
                    ActiveProfileHeader(profile: active, store: store)
                } else {
                    Label("No profile is active. Choose one for commits.", systemImage: "exclamationmark.triangle")
                        .typeStyle(.callout)
                        .foregroundStyle(.token(.statusWarning))
                }
                Divider()
                if store.profiles.count > 7 {
                    TextField("Search Profiles", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                ScrollView {
                    VStack(spacing: Space.s1) {
                        ForEach(filtered) { profile in
                            ProfileRowButton(
                                profile: profile, store: store, isActive: profile.id == store.activeProfileID
                            ) {
                                store.setActive(profile.id)
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: store.profiles.count <= 7)
                GlassControlGroup(spacing: Space.s3) {
                    Button("Add Profile…") { newProfile(false) }.secondaryGlassButton()
                    if let active = store.activeProfile {
                        Button("Edit Active Profile…") { editProfile(active) }.secondaryGlassButton()
                    }
                    Button("Manage Profiles…", action: manageProfiles).secondaryGlassButton()
                }
                .controlSize(.small)
            }
        }
        .padding(Space.s6)
        .frame(width: 360)
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

/// "Active profile": larger avatar, name, `Author <email>`, provider + `@login on host`, auth method.
private struct ActiveProfileHeader: View {
    let profile: GitProfile
    let store: ProfileStore

    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            ProfileAvatar(profile: profile, size: ProfileMetrics.largeAvatar + Space.s4)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Active profile").typeStyle(.micro).foregroundStyle(.secondary)
                Text(profile.displayName).typeStyle(.headline)
                Text("\((profile.committer ?? profile.author).name) <\((profile.committer ?? profile.author).email)>")
                    .typeStyle(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ProfileDescriptions.authSummary(profile, store: store))
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileRowButton: View {
    let profile: GitProfile
    let store: ProfileStore
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                ProfileAvatar(profile: profile, size: ProfileMetrics.largeAvatar)
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text(profile.displayName)
                            .typeStyle(.headline)
                            .foregroundStyle(.primary)
                        if let kind {
                            Image(systemName: ProviderSymbols.symbol(kind))
                                .symbolSize(IconSize.sm)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(profile.author.email)
                        .typeStyle(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s4)
                if let account = store.account(for: profile) {
                    AccountStatusDot(status: account.status)
                }
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
        .accessibilityLabel(accessibilityText)
    }

    private var kind: ProviderKind? { profile.auth.flatMap { store.instance($0.instanceID)?.kind } }

    private var accessibilityText: String {
        var parts = ["Profile \(profile.displayName)", profile.author.email]
        if let kind { parts.append(kind.title) }
        if let account = store.account(for: profile) {
            parts.append(account.status == .ok ? "authenticated" : account.status.title)
        }
        if isActive { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

/// Create/edit sheet (system sheet glass, opaque form content).
struct ProfileEditorView: View {
    let store: ProfileStore
    let engine: GitEngine
    /// Opens Settings ▸ Accounts (Connect Account…).
    var openAccounts: () -> Void = {}
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
    @State private var auth = ProfileAuthDraft()

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
                    LabeledContent("Signing") {
                        Text("Planned").foregroundStyle(.secondary)
                    }
                }
                ProfileAuthSection(store: store, draft: $auth, openAccounts: openAccounts)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: finish)
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create Profile" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ProfileValidation.canSave(issues) || auth.blockingIssue(store) != nil)
            }
            .padding(Space.s6)
        }
        // Fixed height: the grouped Form scrolls instead of growing the sheet past the screen.
        .frame(width: 520, height: 640)
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
            auth = ProfileAuthDraft(editing.auth)
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
            profile.auth = auth.value
            store.update(profile)
        } else {
            store.create(
                GitProfile(
                    displayName: name, colorIndex: colorIndex, author: trimmedAuthor, committer: trimmedCommitter,
                    auth: auth.value),
                activate: store.activeProfile == nil)
        }
        finish()
    }
}

/// Presents the editor as a sheet on any window.
@MainActor
enum ProfileEditorPresenter {
    static func present(
        on window: NSWindow, store: ProfileStore, engine: GitEngine, editing: GitProfile?, prefillFromGitConfig: Bool,
        openAccounts: @escaping () -> Void = {
            NSApp.sendAction(Selector(("showSettingsAccounts:")), to: nil, from: nil)
        }
    ) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled], backing: .buffered,
            defer: true)
        let host = NSHostingController(
            rootView: ProfileEditorView(
                store: store, engine: engine, openAccounts: openAccounts, editing: editing,
                prefillFromGitConfig: prefillFromGitConfig
            ) { [weak window, weak sheet] in
                if let window, let sheet { window.endSheet(sheet) }
            })
        host.sizingOptions = .preferredContentSize
        sheet.contentViewController = host
        sheet.title = editing == nil ? "New Profile" : "Edit Profile"
        window.beginSheet(sheet)
    }
}

/// Settings ▸ Profiles: list, create, edit, activate, delete (destructive sheet). Each row shows who commits and
/// how the profile signs in to remotes.
struct ProfilesSettingsView: View {
    let accounts: AccountsService
    let engine: GitEngine
    let open: (SettingsWindowController.Pane) -> Void
    @State private var selection: UUID?
    @State private var pendingDelete: GitProfile?

    private var store: ProfileStore { accounts.profiles }

    var body: some View {
        Form {
            if store.profiles.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text("Profiles combine who you commit as with how you sign in to remotes.")
                            .typeStyle(.headline)
                        Text(
                            "Exactly one profile is active, and you choose it. Jit never changes your Git or SSH configuration."
                        )
                        .typeStyle(.callout)
                        .foregroundStyle(.secondary)
                        Button("Add Profile…") { present(nil) }
                    }
                    .padding(.vertical, Space.s2)
                }
            } else {
                if store.activeProfile == nil {
                    Label(
                        "No profile is active. Select one and click Make Active.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.statusWarning))
                }
                Section {
                    ForEach(store.profiles) { profile in
                        ProfileSettingsRow(
                            profile: profile, store: store, isActive: profile.id == store.activeProfileID,
                            isSelected: selection == profile.id
                        )
                        .contentShape(Rectangle())
                        // Double-click first: SwiftUI otherwise resolves every click as the single tap.
                        .onTapGesture(count: 2) { present(profile) }
                        .onTapGesture { selection = profile.id }
                        .contextMenu {
                            Button("Edit…") { present(profile) }
                            Button("Make Active") { store.setActive(profile.id) }
                                .disabled(profile.id == store.activeProfileID)
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = profile }
                        }
                    }
                } footer: {
                    HStack {
                        Button("Add Profile…") { present(nil) }
                        Spacer()
                        Button("Delete…", role: .destructive) { pendingDelete = selection.flatMap(profile) }
                            .disabled(selection == nil)
                        Button("Edit…") { selection.flatMap(profile).map(present) }
                            .disabled(selection == nil)
                        Button("Make Active") { store.setActive(selection) }
                            .disabled(selection == nil || selection == store.activeProfileID)
                    }
                    .padding(.top, Space.s3)
                }
                ForEach(Array(store.sharedSSHKeyConflicts().keys), id: \.self) { fingerprint in
                    Label(
                        "Profiles for different GitHub accounts use the same SSH key (\(fingerprint)). GitHub authenticates a key as one user, so one of them will act as the wrong account.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.statusWarning))
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pendingDelete) { profile in
            DeleteProfileSheet(profile: profile, isActive: profile.id == store.activeProfileID) {
                store.delete(id: profile.id)
                selection = nil
                pendingDelete = nil
            } cancel: {
                pendingDelete = nil
            }
        }
    }

    private func profile(_ id: UUID) -> GitProfile? { store.profiles.first { $0.id == id } }

    private func present(_ profile: GitProfile?) {
        guard let window = NSApp.keyWindow else { return }
        ProfileEditorPresenter.present(
            on: window, store: store, engine: engine, editing: profile, prefillFromGitConfig: false,
            openAccounts: { open(.accounts) })
    }
}

struct ProfileSettingsRow: View {
    let profile: GitProfile
    let store: ProfileStore
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Space.s4) {
            ProfileAvatar(profile: profile, size: ProfileMetrics.largeAvatar)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(profile.displayName).typeStyle(.headline)
                Text("\(profile.author.name) <\(profile.author.email)>")
                    .typeStyle(.callout)
                    .foregroundStyle(.secondary)
                Text(ProfileDescriptions.authSummary(profile, store: store))
                    .typeStyle(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("Active").typeStyle(.caption).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s2)
        .background(isSelected ? ColorToken.accentMuted.color : .clear, in: RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Destructive sheet for deleting a profile (design §3.2): commits are unaffected, accounts and keys remain.
struct DeleteProfileSheet: View {
    let profile: GitProfile
    let isActive: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Delete the profile “\(profile.displayName)”?").typeStyle(.headline)
            Text(
                "Commits already made with it are not affected. Its accounts and SSH keys stay available to other profiles; nothing is removed from the Keychain."
                    + (isActive
                        ? " It is the active profile — afterwards no profile is active until you choose one." : "")
            )
            .typeStyle(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Delete Profile", role: .destructive, action: confirm)
            }
        }
        .padding(Space.s8)
        .frame(width: 440)
    }
}

/// Human summaries of a profile's authentication.
enum ProfileDescriptions {
    @MainActor
    static func authSummary(_ profile: GitProfile, store: ProfileStore) -> String {
        guard let auth = profile.auth, let instance = store.instance(auth.instanceID) else {
            return "Identity only — public remotes and ssh-agent keys"
        }
        var parts: [String] = []
        if let account = store.account(for: profile) {
            parts.append("@\(account.login) on \(instance.name)")
            if account.status.needsAttention { parts.append(account.status.title) }
        } else {
            parts.append("\(instance.name), no HTTPS account")
        }
        switch auth.ssh {
        case .keyFile(let path, _): parts.append("SSH key \((path as NSString).lastPathComponent)")
        case .agent: parts.append("SSH via ssh-agent")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}
