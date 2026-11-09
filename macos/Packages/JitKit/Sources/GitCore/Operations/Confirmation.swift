import Foundation

/// A destructive action, exactly as the user confirmed it (design §3.2, ADR-0015). Destructive methods on
/// `RepositoryHandle` take a `ConfirmationToken` and refuse unless the token names the same action.
public enum DestructiveAction: Sendable, Hashable {
    case deleteBranch(name: String, force: Bool)
    case deleteRemoteBranch(remote: String, branch: String)
    case forcePush(remote: String, remoteRef: String, expected: String)
    case skipCurrent
    case abortOperation
    case resolveConflict(path: String, choice: String)
    case dropStash(index: Int, oid: String)
    case clearStashes
    case discardForSwitch(paths: [String])
}

/// What the confirmation sheet shows (design §3.2): title naming action and object, context, what changes,
/// what may be lost, how to recover, and the verb on the destructive button.
public struct ConfirmationRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let action: DestructiveAction
    public var title: String
    public var context: String
    public var changes: String
    public var losses: [String]
    public var recoverability: String
    /// Copyable recovery value (a SHA), shown with a Copy button.
    public var recoveryValue: String?
    public var verb: String
    /// Force push, remote branch deletion: the destructive button enables only after a short delay.
    public var isHighRisk: Bool

    public init(
        action: DestructiveAction, title: String, context: String, changes: String, losses: [String] = [],
        recoverability: String, recoveryValue: String? = nil, verb: String, isHighRisk: Bool = false
    ) {
        self.action = action
        self.title = title
        self.context = context
        self.changes = changes
        self.losses = losses
        self.recoverability = recoverability
        self.recoveryValue = recoveryValue
        self.verb = verb
        self.isHighRisk = isHighRisk
    }

    /// The user pressed the destructive button. The only way to obtain a `ConfirmationToken`.
    public func confirm() -> ConfirmationToken { ConfirmationToken(action: action) }

    public static func == (lhs: ConfirmationRequest, rhs: ConfirmationRequest) -> Bool { lhs.id == rhs.id }
}

/// Proof that the user confirmed a specific `DestructiveAction`. Its initializer is internal: outside
/// `GitCore` a token can only come from `ConfirmationRequest.confirm()` (Swift access control, not a
/// convention).
public struct ConfirmationToken: Sendable, Hashable {
    public let action: DestructiveAction

    init(action: DestructiveAction) { self.action = action }

    /// Throws unless the token confirms exactly `expected`.
    func verify(_ expected: DestructiveAction) throws(GitCoreError) {
        guard action == expected else {
            throw .refused(summary: "This action wasn't confirmed. Nothing was changed.")
        }
    }
}
