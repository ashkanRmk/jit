import Foundation
import GitCore
import Observation

/// An identity-only Git profile (Phase 1). Phase 5 adds provider/auth references — never secrets.
public struct GitProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    /// Index into the profile swatches (`DesignSystem.ProfileColor`).
    public var colorIndex: Int
    public var author: GitIdentity
    /// Optional committer override; the author is used when absent.
    public var committer: GitIdentity?

    public init(
        id: UUID = UUID(), displayName: String, colorIndex: Int, author: GitIdentity, committer: GitIdentity? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.author = author
        self.committer = committer
    }

    /// Up to two initials from the display name ("Work Account" → "WA").
    public var initials: String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// The identity an operation captures when it starts (§6.2, §10.2). Immutable: switching profiles
/// later never changes an operation already prepared. Phase 3 applies it with `GIT_AUTHOR_*` /
/// `GIT_COMMITTER_*` for one invocation.
public struct ProfileSnapshot: Sendable, Equatable {
    public let profileID: UUID
    public let author: GitIdentity
    public let committer: GitIdentity

    public init(_ profile: GitProfile) {
        profileID = profile.id
        author = profile.author
        committer = profile.committer ?? profile.author
    }
}

/// Inline validation for the profile editor. Errors block saving; warnings don't.
public enum ProfileValidation {
    public enum Field: Sendable, Equatable {
        case displayName, authorName, authorEmail, committerName, committerEmail
    }

    public struct Issue: Sendable, Equatable {
        public enum Severity: Sendable { case error, warning }
        public let field: Field
        public let severity: Severity
        public let message: String
    }

    public static func validate(displayName: String, author: GitIdentity, committer: GitIdentity?) -> [Issue] {
        var issues: [Issue] = []
        if displayName.trimmed.isEmpty {
            issues.append(Issue(field: .displayName, severity: .error, message: "Enter a profile name."))
        }
        issues += identityIssues(author, name: .authorName, email: .authorEmail)
        if let committer {
            issues += identityIssues(committer, name: .committerName, email: .committerEmail)
        }
        return issues
    }

    public static func canSave(_ issues: [Issue]) -> Bool { !issues.contains { $0.severity == .error } }

    private static func identityIssues(_ identity: GitIdentity, name: Field, email: Field) -> [Issue] {
        var issues: [Issue] = []
        if identity.name.trimmed.isEmpty {
            issues.append(Issue(field: name, severity: .error, message: "Enter the name Git records."))
        } else if identity.name.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }) {
            issues.append(Issue(field: name, severity: .error, message: "Names can't contain <, > or line breaks."))
        }
        let address = identity.email.trimmed
        if address.isEmpty {
            issues.append(Issue(field: email, severity: .error, message: "Enter the email Git records."))
        } else if address.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline || $0.isWhitespace }) {
            issues.append(Issue(field: email, severity: .error, message: "Emails can't contain spaces, < or >."))
        } else if !looksLikeEmail(address) {
            issues.append(
                Issue(field: email, severity: .warning, message: "This doesn't look like an email address."))
        }
        return issues
    }

    /// One `@`, non-empty local part, and a dot inside the domain.
    static func looksLikeEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.firstIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) != domain.endIndex
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Profiles and the active selection (`profiles.json`). Never writes any Git configuration.
@MainActor @Observable
public final class ProfileStore {
    struct File: Codable {
        var version = ProfileStore.fileVersion
        var profiles: [GitProfile]
        var activeProfileID: UUID?
    }

    nonisolated static let fileVersion = 1
    /// Number of color swatches profiles choose from.
    public static let colorCount = 8

    public private(set) var profiles: [GitProfile] = []
    public private(set) var activeProfileID: UUID?

    @ObservationIgnored private let writer: DebouncedWriter

    public init(location: StoreLocation = .applicationSupport(), fileName: String = "profiles.json") {
        let url = location.url(fileName)
        writer = DebouncedWriter(url: url, delay: .milliseconds(100))
        if let file = JSONFile.load(File.self, at: url, version: Self.fileVersion).value {
            profiles = file.profiles
            activeProfileID = file.activeProfileID.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
        }
    }

    public var activeProfile: GitProfile? { profiles.first { $0.id == activeProfileID } }

    /// An immutable copy of the active identity, or `nil` when no profile is active.
    public func snapshot() -> ProfileSnapshot? { activeProfile.map(ProfileSnapshot.init) }

    /// Adds a profile. The first profile becomes active; later ones only when `activate` is true.
    public func create(_ profile: GitProfile, activate: Bool = false) {
        profiles.append(profile)
        if activate || profiles.count == 1 { activeProfileID = profile.id }
        save()
    }

    public func update(_ profile: GitProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    /// Deletes a profile. Deleting the active profile leaves *no* profile active — Jit never picks
    /// another identity silently.
    public func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        save()
    }

    public func setActive(_ id: UUID?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        save()
    }

    /// The swatch for a new profile: the first one not yet used.
    public func nextColorIndex() -> Int {
        let used = Set(profiles.map(\.colorIndex))
        return (0..<Self.colorCount).first { !used.contains($0) } ?? profiles.count % Self.colorCount
    }

    public func flush() { writer.flush() }

    private func save() {
        writer.schedule { [weak self] in
            guard let self else { return nil }
            return try? JSONFile.encode(File(profiles: self.profiles, activeProfileID: self.activeProfileID))
        }
    }
}
