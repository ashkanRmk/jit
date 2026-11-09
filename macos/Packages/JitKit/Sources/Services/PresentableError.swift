import Foundation
import GitCore

/// What the user can do about a failure (design §4.11). Phase 5 adds account actions.
public enum RecoveryAction: String, Sendable, Hashable {
    case retry
    case refresh
    case resolveConflicts
    case abortOperation
    case chooseProfile
    case stashAndRetry
    case showWorkingDirectory
    case openInTerminal
    case revealInFinder
    case pullFastForward
    case pullRebase
    case forcePushWithLease
    case unsetUpstream
    case publishBranch
    case createBranch
    // Phase 5 — accounts (design §3.4). Never automatic: each is an explicit click.
    case editProfile
    case manageAccounts
    case trustHostKey
    case showDiagnostics
    case switchProfileAndRetry
}

/// "Switch to '<profile>' and Retry" (design §3.4): retry uses a fresh snapshot of that profile.
public struct ProfileSwitch: Sendable, Hashable {
    public var profileID: UUID
    public var name: String

    public init(profileID: UUID, name: String) {
        self.profileID = profileID
        self.name = name
    }
}

/// The SSH host an unknown-host-key failure was about (opens the trust sheet).
public struct HostKeyTarget: Sendable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// A Git failure in Jit's words: a title, a plain explanation, recovery actions and sanitized technical
/// detail (design §4.11). Cancellation is neutral, never an error color.
public struct PresentableError: Sendable, Equatable, Error {
    public var title: String
    public var explanation: String
    public var actions: [RecoveryAction]
    public var technicalDetail: String?
    public var paths: [String]
    public var remoteLines: [String]
    public var isCancellation: Bool
    public var kind: FailureKind?
    /// Profiles whose account or SSH host matches the remote (explicit switch actions).
    public var profileSwitches: [ProfileSwitch] = []
    public var hostKey: HostKeyTarget?

    public init(
        title: String, explanation: String, actions: [RecoveryAction] = [], technicalDetail: String? = nil,
        paths: [String] = [], remoteLines: [String] = [], isCancellation: Bool = false, kind: FailureKind? = nil
    ) {
        self.title = title
        self.explanation = explanation
        self.actions = actions
        self.technicalDetail = technicalDetail
        self.paths = paths
        self.remoteLines = remoteLines
        self.isCancellation = isCancellation
        self.kind = kind
    }

    public static func make(_ error: GitCoreError) -> PresentableError {
        switch error {
        case .cancelled:
            return PresentableError(
                title: "Cancelled", explanation: "The operation was cancelled.", isCancellation: true)
        case .noActiveProfile:
            return PresentableError(
                title: "Choose a profile first",
                explanation:
                    "This operation creates commits, and Jit needs to know who they are by. Choose or create a profile — Jit never changes your Git configuration.",
                actions: [.chooseProfile])
        case .staleSnapshot(let summary):
            return PresentableError(
                title: "The repository changed", explanation: summary, actions: [.refresh])
        case .indexLocked(let path):
            let age =
                (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date).map {
                    " The lock file is \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())) old."
                } ?? ""
            return PresentableError(
                title: "Another Git process is using this repository",
                explanation:
                    "Git found index.lock in the repository: another program (a terminal, an editor, or a crashed Git) is working here.\(age) Try again when it finishes.",
                actions: [.retry, .openInTerminal], technicalDetail: path)
        case .refused(let summary):
            return PresentableError(title: summary, explanation: "Nothing was changed.")
        case .failed(let failure):
            return make(failure)
        case .processFailed, .timedOut, .outputTooLarge, .launchFailed, .io, .internalError, .verificationFailed:
            return PresentableError(
                title: error.summary, explanation: "Nothing was changed unless Git says otherwise below.",
                actions: [.retry], technicalDetail: error.detail)
        case .gitNotFound, .gitTooOld, .notARepository, .pathNotFound, .permissionDenied, .unsafeRepository:
            return PresentableError(title: error.summary, explanation: "", actions: [.revealInFinder])
        }
    }

    static func make(_ failure: ClassifiedFailure) -> PresentableError {
        func error(_ title: String, _ explanation: String, _ actions: [RecoveryAction] = []) -> PresentableError {
            PresentableError(
                title: title, explanation: explanation, actions: actions,
                technicalDetail: failure.detail.isEmpty ? nil : failure.detail, paths: failure.paths,
                remoteLines: failure.remoteLines, kind: failure.kind)
        }
        switch failure.kind {
        case .invalidRepository:
            return error(
                "This folder is no longer a Git repository.", "It may have been moved or deleted.", [.revealInFinder])
        case .detachedHead:
            return error("You're not on a branch.", "Create a branch here or switch to one first.", [.createBranch])
        case .dirtyWorkingTree, .untrackedWouldBeOverwritten:
            return error(
                failure.kind == .untrackedWouldBeOverwritten
                    ? "Untracked files are in the way." : "Local changes would be overwritten.",
                failure.paths.isEmpty
                    ? "Commit or stash your changes first."
                    : "These files have changes that the operation would overwrite. Nothing was changed.",
                [.stashAndRetry, .showWorkingDirectory])
        case .unmergedIndex:
            return error(
                "There are unresolved conflicts.", "Resolve them, or abort the operation.",
                [.resolveConflicts, .abortOperation])
        case .authenticationFailed:
            return error(
                "This remote needs credentials.",
                "The active profile has no account that this server accepted. Connect an account to the profile, or switch to a profile that has one. Jit never falls back to other credentials.",
                [.editProfile])
        case .expiredToken:
            return error(
                "The access token has expired.", "Replace the token or reconnect the account.", [.manageAccounts])
        case .sshPublicKeyDenied:
            return error(
                "The server refused your SSH key.",
                "Check that the profile's SSH key (or the key loaded in ssh-agent) is registered with this server.",
                [.editProfile])
        case .sshHostKeyUnknown:
            return error(
                "This SSH host isn't trusted yet.",
                "Jit never accepts host keys silently. Verify the server's fingerprint to trust it.",
                [.trustHostKey])
        case .sshHostKeyChanged:
            return error(
                "Warning: the server's SSH host key has changed.",
                "This can mean someone is intercepting the connection, or the server was reinstalled. Verify the new key with the server's administrator before connecting. Jit will not retry."
            )
        case .tlsFailure:
            return error(
                "The server's certificate couldn't be verified.",
                "The connection was stopped to protect you. If this is a company server with its own certificate authority, import that CA for the server in Settings ▸ Servers & Network. Jit never disables verification.",
                [.showDiagnostics]
            )
        case .proxyFailure:
            return error("The proxy refused or couldn't be reached.", "Check your network's proxy settings.", [.retry])
        case .hostNotFound:
            return error(
                "The server's name couldn't be resolved.",
                "Check the remote URL and your connection. Private servers may need a VPN.", [.retry])
        case .connectionTimedOut:
            return error(
                "The connection timed out.", "The server didn't answer. Check your connection or VPN.", [.retry])
        case .connectionRefused:
            return error("The server refused the connection.", "It may be down, or the port may be wrong.", [.retry])
        case .remoteRepositoryNotFound:
            return error(
                "The remote repository wasn't found.",
                "Check the URL. A private repository can also look missing without credentials.", [.retry])
        case .pushRejected, .notFastForward:
            return error(
                "The remote has commits you don't have.",
                "Pull first (fast-forward or rebase), or force push with lease if you mean to overwrite them.",
                [.pullFastForward, .pullRebase, .forcePushWithLease])
        case .hookRejected:
            return error(
                "The remote rejected the push.", "Its hook or branch protection declined it — see the server's message."
            )
        case .mergeConflicts:
            return error("Stopped with conflicts.", "Resolve the conflicted files, then continue.", [.resolveConflicts])
        case .indexLocked:
            return error("Another Git process is using this repository.", "Try again when it finishes.", [.retry])
        case .permissionDenied:
            return error("Permission was denied.", "Check the file's permissions in Finder.", [.revealInFinder])
        case .diskFull:
            return error("The disk is full.", "Free some space, then try again.", [.retry])
        case .branchNotFullyMerged:
            return error("The branch has unmerged commits.", "Deleting it would lose them unless they are elsewhere.")
        case .branchCheckedOutElsewhere:
            return error(
                "The branch is checked out in another worktree.",
                "Git allows a branch in one worktree at a time. Switch that worktree to another branch first.")
        case .invalidName:
            return error(failure.summary, "Branch names can't contain spaces, “..”, “~”, “^”, “:” or end with “.lock”.")
        case .alreadyExists:
            return error(failure.summary, "Choose another name.")
        case .unknown:
            return error(failure.summary, "Git reported an error. Details are below.", [.retry])
        }
    }
}
