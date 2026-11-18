import AppKit
import GitCore
import Services

extension OperationsController {
    func recoverBranch(at commit: String) {
        guard !session.isBusy else { return }
        Task { [weak self] in
            guard let self, let expected = await session.captureState() else { return }
            sheet = .recoverBranch(commit: commit, expected: expected)
        }
    }

    func newTag(at commit: String, label: String, annotated: Bool = false) {
        guard !session.isBusy else { return }
        Task {
            guard let expected = await session.captureState() else { return }
            let remotes = ((try? await session.repository?.remotes()) ?? []).map(\.name)
            sheet = .newTag(commit: commit, label: label, annotated: annotated, remotes: remotes, expected: expected)
        }
    }

    func createTag(_ name: String, at commit: String, message: String?, remote: String?, expected: RepoStateToken) {
        guard !session.isBusy else { return }
        let context = execContext
        Task {
            switch await session.createTag(name, at: commit, message: message, context: context, expected: expected) {
            case .failure(let error): present(error)
            case .success(let object):
                if let remote,
                    case .failure(let error) = await session.pushTag(
                        name, remote: remote, object: object, context: context)
                {
                    var error = error
                    error.title = "Tag “\(name)” Created — Push Failed"
                    error.explanation = "Tag “\(name)” was created locally. Pushing it failed.\n\n" + error.explanation
                    if let detail = error.technicalDetail {
                        error.technicalDetail = "The local tag was kept.\n\n" + detail
                    }
                    present(error)
                }
            }
        }
    }

    func push(ref: GitRef) {
        guard !session.isBusy else { return }
        if ref.kind == .tag {
            manageTag(ref)
        } else if ref.kind == .local {
            push(branch: ref.shortName)
        } else if ref.kind == .remote, let local = ref.remoteBranchName, let remote = ref.remoteName {
            guard refs?.ref(named: "refs/heads/\(local)") != nil else {
                present(
                    PresentableError(
                        title: "No local branch to push",
                        explanation: "Check out “\(ref.shortName)” to create its local branch first."))
                return
            }
            run(PushRequest(remote: remote, localBranch: local, remoteBranch: local))
        }
    }

    func pull(ref: GitRef) {
        guard !session.isBusy else { return }
        let branch = ref.kind == .local ? ref.shortName : ref.remoteBranchName
        guard let branch else { return }
        if ref.kind == .local, branch == currentBranch { pull(.fastForwardOnly); return }
        Task {
            let expected = await session.captureState()
            if case .failure(let error) = await session.pullBranch(
                branch, remote: ref.remoteName,
                remoteBranch: ref.remoteBranchName, context: execContext, expected: expected)
            {
                present(error)
            }
        }
    }

    func fastForward(_ ref: GitRef) {
        guard !session.isBusy, let commit = session.status?.branch.oid else { return }
        Task {
            let expected = await session.captureState()
            if case .failure(let error) = await session.fastForwardBranch(ref.shortName, to: commit, expected: expected)
            {
                present(error)
            }
        }
    }

    func resetMenu(at commit: String) -> NSMenuItem {
        let parent = NSMenuItem(
            title: "Reset \(currentBranch ?? "HEAD") to This Commit", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (mode, title) in [
            ("soft", "Soft — Keep Index and Files…"), ("mixed", "Mixed — Keep Files…"),
            ("keep", "Keep — Preserve Local Changes…"),
            ("hard", "Hard — Discard Tracked Changes…"),
        ] {
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.confirmReset(to: commit, mode: mode) })
        }
        parent.submenu = menu
        return parent
    }

    func confirmReset(to commit: String, mode: String) {
        guard !session.isBusy, let mode = ResetMode(rawValue: mode) else { return }
        sheet = .reset(commit: commit, mode: mode)
    }

    func createWorktree(at commit: String) {
        let panel = NSSavePanel()
        panel.title = "Create Worktree"
        panel.nameFieldStringValue = repositoryName + "-worktree"
        panel.prompt = "Create"
        guard let window = NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let path = panel.url?.path else { return }
            Task { @MainActor in
                let expected = await self.session.captureState()
                if case .failure(let error) = await self.session.createWorktree(
                    at: path, commit: commit, expected: expected)
                {
                    self.present(error)
                }
            }
        }
    }

    func exportPatch(_ commit: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(commit.prefix(7)).patch"
        guard let window = NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    guard let repository = self.session.repository else { return }
                    let bytes = try await repository.commitPatch(commit)
                    guard !bytes.isEmpty else {
                        self.showToast(title: "No Patch to Export", message: "This commit has no file changes.")
                        return
                    }
                    try await Task.detached { try Data(bytes).write(to: url, options: .atomic) }.value
                    self.showToast(title: "Patch Saved", message: url.lastPathComponent)
                } catch {
                    self.present(
                        PresentableError(title: "Couldn't Save Patch", explanation: error.localizedDescription))
                }
            }
        }
    }
}

extension OperationsController {
    func deleteBoth(local: GitRef, remote: GitRef) {
        guard let remoteName = remote.remoteName, let remoteBranch = remote.remoteBranchName,
            let tip = remote.commit?.hex(refs?.format ?? .sha1)
        else { return }
        Task { [self] in
            guard let expected = await session.captureState() else { return }
            let request = ConfirmationRequest(
                action: .deleteLocalAndRemoteBranch(
                    branch: local.shortName, remote: remoteName, remoteBranch: remoteBranch),
                title: "Delete \(local.shortName) and \(remote.shortName)?", context: contextLine,
                changes:
                    "Remove the local branch and delete its upstream on the remote for everyone. Unmerged local branches are kept.",
                recoverability: "The remote can only be recovered by pushing its old tip again. Remote tip:",
                recoveryValue: tip, verb: "Delete Both Branches", isHighRisk: true)
            confirm(request) { [weak self] token in
                guard let self = self else { return }
                Task {
                    if case .failure(let error) = await self.session.deleteLocalAndRemoteBranch(
                        local.shortName,
                        remote: remoteName, remoteBranch: remoteBranch, remoteTip: tip, token: token,
                        context: self.execContext, expected: expected)
                    {
                        self.present(error)
                    }
                }
            }
        }
    }
}
