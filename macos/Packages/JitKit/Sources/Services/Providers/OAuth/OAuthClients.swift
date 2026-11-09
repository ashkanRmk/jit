import Foundation

/// OAuth client IDs for GitHub.com and GitLab.com from the build-time `OAuthClients.plist` (design §4.9).
/// Client IDs only — public clients have no secret, and none may ever be added here.
public struct OAuthClients: Sendable, Hashable {
    public var githubClientID: String?
    public var gitlabClientID: String?

    public init(githubClientID: String? = nil, gitlabClientID: String? = nil) {
        self.githubClientID = Self.validated(githubClientID)
        self.gitlabClientID = Self.validated(gitlabClientID)
    }

    /// Reads `OAuthClients.plist` from `bundle`; a missing file or empty values mean "not configured".
    public init(bundle: Bundle) {
        guard let url = bundle.url(forResource: "OAuthClients", withExtension: "plist"),
            let data = try? Data(contentsOf: url)
        else {
            self.init()
            return
        }
        self.init(plistData: data)
    }

    public init(plistData: Data) {
        let object = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
        let dictionary = object as? [String: Any] ?? [:]
        self.init(
            githubClientID: dictionary["GitHubClientID"] as? String,
            gitlabClientID: dictionary["GitLabClientID"] as? String)
    }

    /// The client ID to use for `instance`: SaaS IDs from the plist, self-managed GitLab from the instance's
    /// configured Application ID. `nil` → browser sign-in unavailable (show why, never fake it).
    public func clientID(for instance: ProviderInstance) -> String? {
        if instance.id == .github { return githubClientID }
        if instance.id == .gitlab { return gitlabClientID }
        return instance.kind == .gitlab ? Self.validated(instance.oauthClientID) : nil
    }

    /// Trimmed; only `[A-Za-z0-9._-]`, ≤ 128 characters; anything else is treated as not configured.
    static func validated(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            trimmed.count <= 128,
            trimmed.unicodeScalars.allSatisfy({
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-")
            })
        else { return nil }
        return trimmed
    }
}
