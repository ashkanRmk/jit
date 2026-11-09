import Foundation
import GitCore
import Observation

/// A global Git profile (§10): who commits (identity) and, separately, how remotes authenticate (`auth`,
/// Phase 5). Holds references only — never secrets (ADR-0035).
public struct GitProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    /// Index into the profile swatches (`DesignSystem.ProfileColor`).
    public var colorIndex: Int
    /// Optional SF Symbol shown instead of initials.
    public var symbol: String?
    public var author: GitIdentity
    /// Optional committer override; the author is used when absent.
    public var committer: GitIdentity?
    /// Remote authentication; `nil` = identity only (anonymous remotes, ssh-agent keys).
    public var auth: ProfileAuth?

    public init(
        id: UUID = UUID(), displayName: String, colorIndex: Int, symbol: String? = nil, author: GitIdentity,
        committer: GitIdentity? = nil, auth: ProfileAuth? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.symbol = symbol
        self.author = author
        self.committer = committer
        self.auth = auth
    }

    /// Up to two initials from the display name ("Work Account" → "WA").
    public var initials: String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// What an operation captures when it is enqueued (§6.2, §10.2, design §4.2): identity plus copies of the
/// profile's auth configuration, account, instance and network settings. Immutable — editing or switching
/// profiles later never changes an operation already prepared. Holds Keychain references, never secrets.
public struct ProfileSnapshot: Sendable, Equatable {
    public let profileID: UUID
    public let profileName: String
    public let author: GitIdentity
    public let committer: GitIdentity
    public let auth: ProfileAuth?
    public let account: HostingAccount?
    public let instance: ProviderInstance?
    public let globalNetwork: GlobalNetworkConfig
    /// Every configured server at enqueue: CA and proxy are properties of the server, so they apply to any
    /// profile reaching it. Credentials still come only from `account`.
    public let networkInstances: [ProviderInstance]

    public init(
        _ profile: GitProfile, account: HostingAccount? = nil, instance: ProviderInstance? = nil,
        globalNetwork: GlobalNetworkConfig = GlobalNetworkConfig(), networkInstances: [ProviderInstance] = []
    ) {
        profileID = profile.id
        profileName = profile.displayName
        author = profile.author
        committer = profile.committer ?? profile.author
        auth = profile.auth
        self.account = account
        self.instance = instance
        self.globalNetwork = globalNetwork
        self.networkInstances = networkInstances
    }

    public var identity: IdentitySnapshot { IdentitySnapshot(author: author, committer: committer) }
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

/// Profiles, hosting accounts, provider instances, global network settings and the active selection
/// (`profiles.json`, version 2; migrated from Phase 1's identity-only version 1). Never writes any Git or SSH
/// configuration. Secrets are not here — only in the Keychain (ADR-0035).
@MainActor @Observable
public final class ProfileStore {
    struct File: Codable {
        var version = ProfileStore.fileVersion
        var profiles: [GitProfile]
        var activeProfileID: UUID?
        var accounts: [HostingAccount]? = nil
        var instances: [ProviderInstance]? = nil
        var network: GlobalNetworkConfig? = nil
    }

    nonisolated static let fileVersion = 2
    /// Number of color swatches profiles choose from.
    public static let colorCount = 8

    public private(set) var profiles: [GitProfile] = []
    public private(set) var activeProfileID: UUID?
    public private(set) var accounts: [HostingAccount] = []
    /// Self-managed instances only; GitHub.com and GitLab.com are built in (`allInstances`).
    public private(set) var customInstances: [ProviderInstance] = []
    public private(set) var network = GlobalNetworkConfig()
    /// Bumped on every switch (one-shot UI feedback such as the "Switched to …" toast).
    public private(set) var switchCount = 0
    /// Where the file came from on load (tests and diagnostics).
    @ObservationIgnored public private(set) var loadedVersion: Int?

    @ObservationIgnored private let writer: DebouncedWriter

    public init(location: StoreLocation = .applicationSupport(), fileName: String = "profiles.json") {
        let url = location.url(fileName)
        writer = DebouncedWriter(url: url, delay: .milliseconds(100))
        if let file = Self.load(url) {
            profiles = file.profiles
            accounts = file.accounts ?? []
            customInstances = (file.instances ?? []).filter(\.isSelfManaged)
            network = file.network ?? GlobalNetworkConfig()
            activeProfileID = file.activeProfileID.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            loadedVersion = file.version
            if file.version != Self.fileVersion { save() }
        }
    }

    private struct VersionProbe: Decodable { let version: Int? }

    /// Version 1 (Phase 1) has the same profile fields minus `auth`/`symbol`, so it decodes as version 2 and
    /// is rewritten as version 2 on the next save. Unknown versions are backed up and reset.
    static func load(_ url: URL) -> File? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let probe = try? decoder.decode(VersionProbe.self, from: data), let version = probe.version,
            version == 1 || version == fileVersion, let file = try? decoder.decode(File.self, from: data)
        {
            return file
        }
        _ = JSONFile.backUp(url)
        return nil
    }

    public var activeProfile: GitProfile? { profiles.first { $0.id == activeProfileID } }

    public var allInstances: [ProviderInstance] { [.github, .gitlab] + customInstances }

    public func instance(_ id: ProviderInstanceID) -> ProviderInstance? { allInstances.first { $0.id == id } }
    public func account(_ id: HostingAccountID) -> HostingAccount? { accounts.first { $0.id == id } }

    /// The account a profile authenticates HTTPS/API requests with (if any).
    public func account(for profile: GitProfile) -> HostingAccount? { profile.auth?.accountID.flatMap(account) }

    /// Profiles that reference an account (the Accounts pane's "Used by").
    public func profiles(using accountID: HostingAccountID) -> [GitProfile] {
        profiles.filter { $0.auth?.accountID == accountID }
    }

    /// An immutable copy of the active profile's identity and auth configuration, or `nil` without one.
    public func snapshot() -> ProfileSnapshot? { activeProfile.map(snapshot(of:)) }

    public func snapshot(of profile: GitProfile) -> ProfileSnapshot {
        ProfileSnapshot(
            profile, account: account(for: profile), instance: profile.auth.flatMap { instance($0.instanceID) },
            globalNetwork: network, networkInstances: customInstances)
    }

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
    /// another identity silently. Accounts and keys stay (they may be used by other profiles).
    public func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        save()
    }

    public func setActive(_ id: UUID?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        guard id != activeProfileID else { return }
        activeProfileID = id
        switchCount += 1
        save()
    }

    // MARK: Accounts

    public func addAccount(_ account: HostingAccount) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        save()
    }

    public func updateAccount(_ account: HostingAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    /// Records what Jit observed on use or on Check Now (never in the background).
    public func setStatus(_ status: AccountStatus, for id: HostingAccountID, checkedAt: Date = Date()) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].status = status
        accounts[index].lastCheckedAt = checkedAt
        save()
    }

    /// Removes the account and detaches it from profiles (which keep their identity and SSH settings). The
    /// caller deletes the Keychain item (after the destructive sheet).
    public func removeAccount(_ id: HostingAccountID) {
        accounts.removeAll { $0.id == id }
        for index in profiles.indices where profiles[index].auth?.accountID == id {
            profiles[index].auth?.accountID = nil
        }
        save()
    }

    // MARK: Instances & network

    public func upsertInstance(_ instance: ProviderInstance) {
        guard instance.isSelfManaged else { return }
        if let index = customInstances.firstIndex(where: { $0.id == instance.id }) {
            customInstances[index] = instance
        } else {
            customInstances.append(instance)
        }
        save()
    }

    /// Removes a self-managed instance with its accounts; profiles bound to it lose their auth configuration.
    public func removeInstance(_ id: ProviderInstanceID) {
        customInstances.removeAll { $0.id == id }
        accounts.removeAll { $0.instanceID == id }
        for index in profiles.indices where profiles[index].auth?.instanceID == id { profiles[index].auth = nil }
        save()
    }

    public func setNetwork(_ config: GlobalNetworkConfig) {
        network = config
        save()
    }

    /// The swatch for a new profile: the first one not yet used.
    public func nextColorIndex() -> Int {
        let used = Set(profiles.map(\.colorIndex))
        return (0..<Self.colorCount).first { !used.contains($0) } ?? profiles.count % Self.colorCount
    }

    /// Profiles bound to different accounts of one GitHub instance that use the same SSH key fingerprint:
    /// GitHub authenticates a key as one user, so one of them will act as the wrong account (design §5).
    public func sharedSSHKeyConflicts() -> [String: [GitProfile]] {
        var byKey: [String: [GitProfile]] = [:]
        for profile in profiles {
            guard let auth = profile.auth, instance(auth.instanceID)?.kind == .github,
                let fingerprint = auth.ssh?.fingerprint
            else { continue }
            byKey[fingerprint, default: []].append(profile)
        }
        return byKey.filter { _, profiles in Set(profiles.compactMap { $0.auth?.accountID }).count > 1 }
    }

    public func flush() { writer.flush() }

    private func save() {
        writer.schedule { [weak self] in
            guard let self else { return nil }
            return try? JSONFile.encode(
                File(
                    profiles: self.profiles, activeProfileID: self.activeProfileID, accounts: self.accounts,
                    instances: self.customInstances, network: self.network))
        }
    }
}
