import DesignSystem
import GitCore
import Services
import SwiftUI

/// Presents the active `OperationSheet` as a standard window-modal sheet. Lives in a zero-size host in the
/// tab's main pane.
struct OperationSheetsHost: View {
    @Bindable var controller: OperationsController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .sheet(item: $controller.sheet) { sheet in
                content(sheet)
            }
    }

    @ViewBuilder private func content(_ sheet: OperationSheet) -> some View {
        switch sheet {
        case .confirm(let request):
            ConfirmationSheet(request: request, cancel: controller.cancelSheet) { controller.confirmed(request) }
        case .error(let error):
            ErrorSheet(error: error, perform: controller.perform, dismiss: controller.cancelSheet)
        case .newBranch(let start, let label):
            NewBranchSheet(controller: controller, start: start, label: label)
        case .rename(let branch):
            RenameBranchSheet(controller: controller, branch: branch)
        case .setUpstream(let branch, let remotes):
            UpstreamSheet(controller: controller, branch: branch, remotes: remotes)
        case .publish(let branch, let remotes):
            PublishSheet(controller: controller, branch: branch, remotes: remotes)
        case .pushRejected(let request, let outcome):
            PushRejectedSheet(controller: controller, request: request, outcome: outcome)
        case .notFastForward(let ahead, let behind):
            NotFastForwardSheet(controller: controller, ahead: ahead, behind: behind)
        case .merge(let source, let label, let conflicts):
            MergeSheet(controller: controller, source: source, label: label, predicted: conflicts)
        case .rebase(let onto, let label, let plan):
            RebaseSheet(controller: controller, onto: onto, label: label, plan: plan)
        case .mainline(let commit, let parents, let isRevert):
            MainlineSheet(controller: controller, commit: commit, parents: parents, isRevert: isRevert)
        case .blockedSwitch(let target, let paths, let untracked):
            BlockedSwitchSheet(controller: controller, target: target, paths: paths, untracked: untracked)
        case .stashCreate(let paths):
            StashCreateSheet(controller: controller, paths: paths)
        case .remotes(let remotes):
            RemotesSheet(remotes: remotes, dismiss: controller.cancelSheet)
        case .detached(let oid):
            DetachedSheet(controller: controller, oid: oid)
        case .unmerged(let branch, let commits, let tip):
            UnmergedBranchSheet(controller: controller, branch: branch, commits: commits, tip: tip)
        case .insecureClone:
            EmptyView()
        }
    }
}

/// Common sheet chrome: title, optional subtitle, content, buttons.
struct SheetScaffold<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 460
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s6) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(title)
                    .typeStyle(.headline)
                    .foregroundStyle(.token(.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .typeStyle(.monoCaption)
                        .foregroundStyle(.token(.textTertiary))
                }
            }
            content
            HStack {
                Spacer()
                buttons
            }
            .controlSize(.large)
        }
        .padding(Space.s8)
        .frame(width: width)
    }
}

/// "Commits as Ada <ada@…> · Personal profile", or the blocking no-profile state.
struct IdentityLine: View {
    let controller: OperationsController

    var body: some View {
        if let line = controller.identityLine {
            Label(line, systemImage: "person.crop.circle")
                .typeStyle(.caption)
                .foregroundStyle(.token(.textSecondary))
        } else {
            HStack {
                Label(
                    "No active profile — this creates commits.", systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.statusWarning))
                Button("Choose Profile…") { controller.chooseProfile() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Branches

struct NewBranchSheet: View {
    let controller: OperationsController
    let start: String
    let label: String
    @State private var name = ""
    @State private var switchTo = true
    @State private var validation: String?
    @State private var isValid = false

    var body: some View {
        SheetScaffold(title: "New Branch", subtitle: "from \(label)") {
            VStack(alignment: .leading, spacing: Space.s3) {
                TextField("Branch name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                if let validation {
                    Text(validation).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                }
                Toggle("Switch to it", isOn: $switchTo)
            }
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Create Branch", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .task(id: name) {
            guard !name.isEmpty else {
                isValid = false
                validation = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard let repository = controller.session.repository else { return }
            do throws(GitCoreError) {
                _ = try await repository.validateBranchName(name)
                isValid = true
                validation = nil
            } catch {
                isValid = false
                validation = error.summary
            }
        }
    }

    private func create() {
        guard isValid else { return }
        controller.cancelSheet()
        controller.createBranch(name, at: start, switchTo: switchTo)
    }
}

struct RenameBranchSheet: View {
    let controller: OperationsController
    let branch: String
    @State private var name = ""
    @State private var validation: String?
    @State private var isValid = false

    var body: some View {
        SheetScaffold(title: "Rename \(branch)", subtitle: controller.contextLine) {
            VStack(alignment: .leading, spacing: Space.s3) {
                TextField("New name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(rename)
                if let validation {
                    Text(validation).typeStyle(.caption).foregroundStyle(.token(.statusDanger))
                }
                Text("The upstream setting follows the branch. The remote branch is not renamed.")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.textSecondary))
            }
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Rename", action: rename)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .onAppear { name = branch }
        .task(id: name) {
            guard !name.isEmpty, name != branch, let repository = controller.session.repository else {
                isValid = false
                return
            }
            do throws(GitCoreError) {
                _ = try await repository.validateBranchName(name)
                isValid = true
                validation = nil
            } catch {
                isValid = false
                validation = error.summary
            }
        }
    }

    private func rename() {
        guard isValid else { return }
        controller.cancelSheet()
        controller.renameBranch(branch, to: name)
    }
}

struct UpstreamSheet: View {
    let controller: OperationsController
    let branch: String
    let remotes: [String]
    @State private var choice = ""

    var body: some View {
        SheetScaffold(title: "Set Upstream of \(branch)", subtitle: controller.contextLine) {
            if remotes.isEmpty {
                Text("There are no remote branches. Fetch first, or publish this branch.")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
            } else {
                Picker("Track", selection: $choice) {
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }
            }
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Set Upstream") {
                controller.cancelSheet()
                controller.setUpstream(branch, to: choice)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(choice.isEmpty)
        }
        .onAppear { choice = remotes.first { $0.hasSuffix("/\(branch)") } ?? remotes.first ?? "" }
    }
}

struct BlockedSwitchSheet: View {
    let controller: OperationsController
    let target: SwitchTarget
    let paths: [String]
    let untracked: Bool

    var body: some View {
        SheetScaffold(
            title: untracked
                ? "Can't switch: untracked files are in the way"
                : "Can't switch: these files have changes that would be overwritten",
            subtitle: controller.contextLine
        ) {
            PathList(paths: paths)
            Text(
                "Nothing was changed. Stash and Switch puts all your changes (including untracked files) in a stash, switches, and leaves the stash for you to pop later. If switching still fails, your changes are restored."
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            IdentityLine(controller: controller)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.defaultAction)
            Button("Stash and Switch") { controller.stashAndSwitch(target) }
                .disabled(!controller.hasProfile)
        }
    }
}

struct DetachedSheet: View {
    let controller: OperationsController
    let oid: String

    var body: some View {
        SheetScaffold(title: "Check out \(oid.prefix(7)) without a branch?", subtitle: controller.contextLine) {
            Text(
                "You'll be in “detached HEAD” state: you can look around and build, but new commits belong to no branch until you create one (New Branch Here…). Nothing is lost by switching back."
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Check Out") { controller.detachConfirmed(oid) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct UnmergedBranchSheet: View {
    let controller: OperationsController
    let branch: String
    let commits: [CommitSummary]
    let tip: String

    var body: some View {
        SheetScaffold(title: "\(branch) has unmerged commits", subtitle: controller.contextLine) {
            Text(
                "Git didn't delete it: these commits are not in \(controller.currentBranch ?? "HEAD") or the branch's upstream."
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.textSecondary))
            PathList(paths: commits.map { "\($0.shortOID) \($0.subject)" })
        } buttons: {
            Button("Keep Branch", action: controller.cancelSheet)
                .keyboardShortcut(.defaultAction)
            Button("Delete Anyway…") { controller.forceDelete(branch: branch, commits: commits, tip: tip) }
        }
    }
}

// MARK: - Remote

struct PublishSheet: View {
    let controller: OperationsController
    let branch: String
    let remotes: [String]
    @State private var remote = ""
    @State private var remoteBranch = ""
    @State private var track = true

    var body: some View {
        SheetScaffold(title: "Publish \(branch)", subtitle: controller.contextLine) {
            Form {
                Picker("Remote", selection: $remote) {
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }
                TextField("Remote branch", text: $remoteBranch)
                Toggle("Track this remote branch", isOn: $track)
            }
            .formStyle(.columns)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Publish") {
                controller.cancelSheet()
                controller.run(
                    PushRequest(remote: remote, localBranch: branch, remoteBranch: remoteBranch, setUpstream: track))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(remote.isEmpty || remoteBranch.isEmpty)
        }
        .onAppear {
            remote = remotes.contains("origin") ? "origin" : remotes.first ?? ""
            remoteBranch = branch
        }
    }
}

struct PushRejectedSheet: View {
    let controller: OperationsController
    let request: PushRequest
    let outcome: PushOutcome

    var body: some View {
        SheetScaffold(
            title: title, subtitle: "\(request.localBranch) → \(request.remote)/\(request.remoteBranch)", width: 500
        ) {
            Text(explanation)
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if !outcome.remoteLines.isEmpty {
                PathList(paths: outcome.remoteLines)
            }
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.defaultAction)
            if case .nonFastForward? = outcome.rejection {
                Button("Pull") {
                    controller.cancelSheet()
                    controller.pull(.fastForwardOnly)
                }
                Button("Pull with Rebase") {
                    controller.cancelSheet()
                    controller.pull(.rebase)
                }
                Button("Force Push with Lease…") { controller.confirmForcePush(request) }
            }
        }
    }

    private var title: String {
        switch outcome.rejection {
        case .nonFastForward?: "The remote has commits you don't have"
        case .staleLease?: "The remote moved since you fetched"
        case .remoteHook?: "The remote rejected the push"
        default: "The push was rejected"
        }
    }

    private var explanation: String {
        switch outcome.rejection {
        case .nonFastForward?:
            "Someone pushed to \(request.remote)/\(request.remoteBranch) since you last pulled. Pull (fast-forward only, or with rebase to put your commits on top), then push again. Force push with lease overwrites the remote — only if nobody pushed after your last fetch."
        case .staleLease?: "Nothing was overwritten. Fetch and review the new commits first."
        case .remoteHook(let reason)?:
            "The server declined the push (\(reason)). Its message is below — often a protected branch or a policy check."
        case .other(let reason)?: "Git reported: \(reason)."
        case nil: ""
        }
    }
}

struct NotFastForwardSheet: View {
    let controller: OperationsController
    let ahead: Int
    let behind: Int

    var body: some View {
        SheetScaffold(title: "Can't fast-forward", subtitle: controller.contextLine) {
            Text(
                "Your branch has \(ahead) \(ahead == 1 ? "commit" : "commits") the upstream lacks, and the upstream has \(behind) you don't have. Nothing was integrated. Choose how to combine them:"
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            IdentityLine(controller: controller)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.defaultAction)
            Button("Pull with Merge") {
                controller.cancelSheet()
                controller.pull(.merge)
            }
            .disabled(!controller.hasProfile)
            Button("Pull with Rebase") {
                controller.cancelSheet()
                controller.pull(.rebase)
            }
            .disabled(!controller.hasProfile)
        }
    }
}

struct RemotesSheet: View {
    let remotes: [RemoteInfo]
    let dismiss: () -> Void

    var body: some View {
        SheetScaffold(
            title: "Remotes", subtitle: "Read-only. Add or edit remotes in Terminal (git remote).", width: 600
        ) {
            if remotes.isEmpty {
                Text("This repository has no remotes.")
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textSecondary))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s6) {
                        ForEach(remotes) { remote in
                            VStack(alignment: .leading, spacing: Space.s2) {
                                Text(remote.name).typeStyle(.headline)
                                ForEach(remote.fetchURLs, id: \.self) { url in row("Fetch", url) }
                                ForEach(remote.pushURLs, id: \.self) { url in row("Push", url) }
                                Text("Prune on fetch: \(remote.prune ? "on" : "off")")
                                    .typeStyle(.caption)
                                    .foregroundStyle(.token(.textTertiary))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
        } buttons: {
            Button("Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func row(_ label: String, _ url: String) -> some View {
        let masked = RemoteInfo.masked(url)
        return HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            Text(label).typeStyle(.caption).foregroundStyle(.token(.textTertiary)).frame(width: 40, alignment: .leading)
            Text(masked.url).typeStyle(.monoCaption).textSelection(.enabled)
            if masked.hadCredentials {
                Label("Contains credentials", systemImage: "exclamationmark.triangle.fill")
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.statusWarning))
                    .help("This URL stores a password or token in plain text in .git/config. Jit hides it here.")
            }
        }
    }
}

// MARK: - Integration

struct MergeSheet: View {
    let controller: OperationsController
    let source: String
    let label: String
    let predicted: [String]
    @State private var strategy: MergeStrategy = .fastForwardIfPossible
    @State private var message = ""

    var body: some View {
        SheetScaffold(
            title: "Merge \(label) into \(controller.currentBranch ?? "HEAD")", subtitle: controller.contextLine
        ) {
            Picker("Strategy", selection: $strategy) {
                Text("Fast-forward when possible").tag(MergeStrategy.fastForwardIfPossible)
                Text("Always create a merge commit").tag(MergeStrategy.noFastForward)
                Text("Fast-forward only").tag(MergeStrategy.fastForwardOnly)
            }
            .pickerStyle(.radioGroup)
            if strategy != .fastForwardOnly {
                TextField("Message (optional — Git's default otherwise)", text: $message, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            if !predicted.isEmpty {
                Label(
                    "This merge will conflict in \(predicted.count) \(predicted.count == 1 ? "file" : "files"): \(predicted.prefix(3).joined(separator: ", "))\(predicted.count > 3 ? "…" : "")",
                    systemImage: "exclamationmark.triangle"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.statusWarning))
            }
            if let summary = controller.session.status?.summary, !summary.isClean {
                Label(
                    "You have uncommitted changes. Abort may not restore them exactly — commit or stash first?",
                    systemImage: "info.circle"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.textSecondary))
            }
            IdentityLine(controller: controller)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Merge") {
                controller.cancelSheet()
                controller.runMerge(
                    MergeRequest(source: source, strategy: strategy, message: message.isEmpty ? nil : message))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(strategy != .fastForwardOnly && !controller.hasProfile)
        }
    }
}

struct RebaseSheet: View {
    let controller: OperationsController
    let onto: String
    let label: String
    let plan: RebasePlan

    var body: some View {
        SheetScaffold(
            title: "Rebase \(controller.currentBranch ?? "HEAD") onto \(label)", subtitle: controller.contextLine,
            width: 500
        ) {
            if plan.commits.isEmpty {
                Text(
                    "There's nothing to replay: \(controller.currentBranch ?? "HEAD") has no commits that \(label) lacks."
                )
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
            } else {
                Text(
                    "\(plan.commits.count) \(plan.commits.count == 1 ? "commit is" : "commits are") replayed on top of \(label), oldest first. Authors are kept; you become the committer."
                )
                .typeStyle(.callout)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                PathList(paths: plan.commits.map { "\($0.shortOID) \($0.subject)" })
            }
            if plan.pushedCount > 0 {
                Label(
                    "This rewrites \(plan.pushedCount) \(plan.pushedCount == 1 ? "commit" : "commits") already pushed; a later push will need force-with-lease.",
                    systemImage: "exclamationmark.triangle"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.statusWarning))
            }
            if let summary = controller.session.status?.summary, summary.staged + summary.unstaged > 0 {
                Label(
                    "Commit or stash your changes first: rebase needs a clean working tree.",
                    systemImage: "xmark.octagon"
                )
                .typeStyle(.caption)
                .foregroundStyle(.token(.statusDanger))
            }
            IdentityLine(controller: controller)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Rebase") {
                controller.cancelSheet()
                controller.runRebase(onto: onto)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                plan.commits.isEmpty || !controller.hasProfile
                    || !(controller.session.status?.summary.map { $0.staged + $0.unstaged == 0 } ?? true))
        }
    }
}

struct MainlineSheet: View {
    let controller: OperationsController
    let commit: String
    let parents: [CommitSummary]
    let isRevert: Bool
    @State private var mainline = 1

    var body: some View {
        SheetScaffold(title: "\(commit.prefix(7)) is a merge commit", subtitle: controller.contextLine) {
            Text(
                "Choose the parent that is the mainline — the changes are computed against it (usually parent 1, the branch that was merged into)."
            )
            .typeStyle(.callout)
            .foregroundStyle(.token(.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
            Picker("Mainline", selection: $mainline) {
                ForEach(Array(parents.enumerated()), id: \.offset) { index, parent in
                    Text("Parent \(index + 1): \(parent.shortOID) \(parent.subject)").tag(index + 1)
                }
            }
            .pickerStyle(.radioGroup)
            IdentityLine(controller: controller)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button(isRevert ? "Revert" : "Cherry-pick") {
                controller.cancelSheet()
                if isRevert {
                    controller.runRevert(commit, mainline: mainline)
                } else {
                    controller.runCherryPick([commit], mainline: mainline)
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Stash

struct StashCreateSheet: View {
    let controller: OperationsController
    let paths: [String]
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false
    @State private var stagedOnly = false
    @State private var onlySelected = true

    var body: some View {
        SheetScaffold(title: "Stash Changes", subtitle: controller.contextLine) {
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: Space.s3) {
                Toggle("Include untracked files", isOn: $includeUntracked)
                    .disabled(stagedOnly)
                Toggle("Keep staged changes in the index", isOn: $keepIndex)
                    .disabled(stagedOnly)
                Toggle("Stash only staged changes", isOn: $stagedOnly)
                if !paths.isEmpty {
                    Toggle(
                        "Only the \(paths.count) selected \(paths.count == 1 ? "file" : "files")", isOn: $onlySelected)
                }
            }
            IdentityLine(controller: controller)
        } buttons: {
            Button("Cancel", action: controller.cancelSheet)
                .keyboardShortcut(.cancelAction)
            Button("Stash") {
                controller.cancelSheet()
                controller.runStash(
                    StashPushRequest(
                        message: message.isEmpty ? nil : message, includeUntracked: includeUntracked && !stagedOnly,
                        keepIndex: keepIndex && !stagedOnly, stagedOnly: stagedOnly, paths: onlySelected ? paths : []))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!controller.hasProfile)
        }
    }
}
