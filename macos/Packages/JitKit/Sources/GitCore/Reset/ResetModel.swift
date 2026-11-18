import Foundation

public enum ResetMode: String, CaseIterable, Sendable, Hashable {
    case soft, mixed, keep, hard
    public var title: String { rawValue.capitalized }
    public var explanation: String {
        switch self {
        case .soft: "Move the branch, keeping the index and working files."
        case .mixed: "Move the branch and reset the index, keeping working files."
        case .keep: "Move the branch and keep local changes; refuse if they conflict."
        case .hard: "Move the branch and replace tracked local changes with this commit."
        }
    }
}

public struct ResetChange: Sendable, Equatable, Identifiable {
    public let path: String
    public let staged: Bool
    public let unstaged: Bool
    public let untracked: Bool
    public let isSubmodule: Bool
    public let cannotStash: Bool
    public var id: String { path }
}

/// Immutable read-only plan. The token must confirm this exact ID, target, mode and stash choice.
public struct ResetPreview: Sendable, Identifiable {
    public let id = UUID()
    public let target: String
    public let mode: ResetMode
    public let previousHead: String
    public let branch: String?
    public let localChanges: [ResetChange]
    public let obstructingPaths: [String]
    public let removedCount: Int
    public let unreachableCount: Int
    public let unreachableCommits: [CommitSummary]
    public let publishedCount: Int
    let snapshot: ResetSnapshot

    public var discardedPaths: [String] {
        mode == .hard ? localChanges.filter { !$0.untracked && !$0.isSubmodule }.map(\.path) : []
    }
    public var unsupportedStashPaths: [String] { localChanges.filter(\.cannotStash).map(\.path) }
    public var needsStash: Bool { mode == .hard && !localChanges.isEmpty }
    public func confirmationAction(stashFirst: Bool) -> DestructiveAction {
        .reset(previewID: id, commit: target, mode: mode, stashFirst: stashFirst)
    }
}

public struct ResetOutcome: Sendable, Equatable {
    public let commit: String
    public let previousHead: String
    public let stashOID: String?
}

struct ResetSnapshot: Sendable, Equatable {
    let root: String
    let state: RepoStateToken
    let index: [UInt8]
    let status: [UInt8]
    let files: [String: ResetFileState]
    let references: [String: String]
}
