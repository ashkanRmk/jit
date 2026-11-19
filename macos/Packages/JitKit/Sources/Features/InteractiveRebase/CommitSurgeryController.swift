import AppKit
import GitCore
import Services

extension OperationsController {
    var historyEditUnavailableReason: String? {
        if session.lifecycle != .active { return "Wait for this repository to finish loading." }
        if session.isBusy || session.operationState != .clean { return "Finish the current operation first." }
        if headIsDetached || currentBranch == nil { return "Check out a branch before editing its history." }
        guard let status = session.status, status.branch.oid != nil else { return "This branch has no commits yet." }
        if let summary = status.summary, summary.staged + summary.unstaged + summary.conflicted > 0 {
            return "Commit or stash tracked changes before editing history."
        }
        if interactiveRebase != nil { return "Close the interactive rebase editor first." }
        return nil
    }

    func commitSurgeryMenuItems(for oid: String, parentCount: Int, singleSelection: Bool) -> [NSMenuItem] {
        let isHead = session.status?.branch.oid == oid
        return [CommitSurgeryAction.editMessage, .drop].map { action in
            let item = ClosureMenuItem(title: action.title + "…") { [weak self] in
                self?.beginCommitSurgery(for: oid, action: action)
            }
            let reason =
                !singleSelection
                ? "Select one commit to edit its history."
                : historyEditUnavailableReason
                    ?? ((parentCount == 1 || action == .editMessage && isHead)
                        ? nil : "Root and merge commits cannot be replayed by this action.")
            item.isEnabled = reason == nil
            item.toolTip = reason
            return item
        }
    }

    func beginCommitSurgery(for oid: String, action: CommitSurgeryAction) {
        guard historyEditUnavailableReason == nil, let repository = session.repository else { return }
        cancelSheet()
        let generation = UUID()
        surgeryGeneration = generation
        surgeryPreparation = Task { [weak self] in
            do throws(GitCoreError) {
                let plan = try await repository.commitSurgeryPlan(for: oid, action: action)
                guard let self, !Task.isCancelled, self.surgeryGeneration == generation,
                    self.session.lifecycle == .active, self.sheet == nil, self.interactiveRebase == nil
                else { return }
                self.surgeryPreparation = nil
                self.sheet = .commitSurgery(plan)
            } catch {
                guard let self, !Task.isCancelled, self.surgeryGeneration == generation,
                    self.session.lifecycle == .active, self.sheet == nil
                else { return }
                self.surgeryPreparation = nil
                self.present(PresentableError.make(error))
            }
        }
    }

    func runCommitSurgery(_ plan: CommitSurgeryPlan, token: ConfirmationToken) {
        guard historyEditUnavailableReason == nil, plan.validationIssues.isEmpty, hasProfile else { return }
        let context = execContext
        cancelSheet()
        Task {
            handle(await session.applyCommitSurgery(plan, token: token, context: context)) { outcome in
                handleIntegration(outcome)
                if case .stoppedInProgress = outcome { showWorkingDirectory() }
            }
        }
    }
}
