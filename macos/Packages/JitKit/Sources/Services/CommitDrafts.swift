import Foundation

/// Unfinished commit messages per repository (design §3.6 draft persistence): `commit-drafts.json` next to
/// the session file, `0600`. Written on change (debounced by the caller), read once.
@MainActor
public final class CommitDrafts {
    public struct Draft: Codable, Equatable, Sendable {
        public var summary: String
        public var description: String

        public init(summary: String = "", description: String = "") {
            self.summary = summary
            self.description = description
        }

        public var isEmpty: Bool { summary.isEmpty && description.isEmpty }
    }

    private struct File: Codable {
        var version = 1
        var drafts: [String: Draft] = [:]
    }

    private let url: URL
    private var file: File

    public init(location: StoreLocation = .applicationSupport()) {
        url = location.url("commit-drafts.json")
        file = JSONFile.load(File.self, at: url, version: 1).value ?? File()
    }

    public func draft(for repository: String) -> Draft { file.drafts[repository] ?? Draft() }

    public func save(_ draft: Draft, for repository: String) {
        let current = file.drafts[repository] ?? Draft()
        guard current != draft else { return }
        file.drafts[repository] = draft.isEmpty ? nil : draft
        if let data = try? JSONFile.encode(file) { try? JSONFile.write(data, to: url) }
    }
}
