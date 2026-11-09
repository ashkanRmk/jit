import Foundation
import GitCore

/// Turns an auth-class failure into the specific explanation of design §3.4, using the snapshot the operation ran
/// with and its resolution: no account for this host / rejected or expired / no access / SSH key refused / unknown
/// host key. Offers "Switch to '<profile>' and Retry" for profiles that match the remote — never acts on its own.
public enum AuthFailureExplainer {
    public static let authKinds: Set<FailureKind> = [
        .authenticationFailed, .expiredToken, .remoteRepositoryNotFound, .sshPublicKeyDenied, .sshHostKeyUnknown,
    ]

    public static func explain(
        _ error: PresentableError, snapshot: ProfileSnapshot?, resolution: AccessResolution?,
        candidates: [GitProfile], remoteURLs: [String] = []
    ) -> PresentableError {
        guard let kind = error.kind, authKinds.contains(kind) else { return error }
        var result = error
        let hosts = resolution?.remoteHosts ?? remoteURLs.compactMap { RemoteURL.parse($0)?.host }
        let host = hosts.first ?? "this server"
        let profileName = snapshot.map { "“\($0.profileName)”" } ?? "No profile"
        result.profileSwitches = candidates.map { ProfileSwitch(profileID: $0.id, name: $0.displayName) }
        let switchActions: [RecoveryAction] = candidates.isEmpty ? [] : [.switchProfileAndRetry]

        switch kind {
        case .sshHostKeyUnknown:
            if let url = remoteURLs.compactMap(RemoteURL.parse).first(where: \.isSSH) {
                result.hostKey = HostKeyTarget(host: url.host, port: url.port)
                result.title = "\(url.host) isn't a trusted SSH host yet."
            }
            return result
        case .sshPublicKeyDenied:
            let key: String
            switch snapshot?.auth?.ssh {
            case .keyFile(let path, let fingerprint):
                key = "the key \((path as NSString).lastPathComponent) (\(fingerprint))"
            case .agent: key = "the keys in ssh-agent"
            case nil: key = "the keys in ssh-agent (the profile has no SSH key configured)"
            }
            result.title = "\(host) refused \(profileName)'s SSH key."
            result.explanation =
                "SSH offered \(key) and the server didn't accept it. Check the key is registered with this account, or switch to the profile that owns this repository."
            result.actions = switchActions + [.editProfile]
            return result
        default:
            break
        }

        let mismatch = resolution?.mismatches.first
        switch mismatch {
        case .noAccountForHost(let mismatchHost), .noHTTPSAccount(let mismatchHost):
            result.title = "The active profile \(profileName) has no account for \(mismatchHost)."
            result.explanation =
                "Git ran without credentials, and the server requires them. Jit never uses another profile's account or credentials saved elsewhere."
            result.actions = switchActions + [.editProfile]
            return result
        case .noProfileAuth:
            result.title =
                "\(profileName == "No profile" ? "No profile is active" : "The profile \(profileName) has no account")."
            result.explanation = "Connect an account to the profile (Settings ▸ Profiles) or switch to one that has it."
            result.actions = switchActions + [.editProfile]
            return result
        case .sshHostNotInstance, nil:
            break
        }

        let account = snapshot?.account
        let login = account.map { "@\($0.login)" } ?? "The account"
        if kind == .remoteRepositoryNotFound {
            guard account != nil else { return result }
            let repository =
                remoteURLs.compactMap(RemoteURL.parse).first.map {
                    $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(
                        of: ".git", with: "")
                } ?? "this repository"
            result.title = "\(login) can't access \(repository)."
            result.explanation =
                "The server answered as if the repository doesn't exist — that's also what it says when the account has no access. Another profile may have access."
            result.actions = switchActions + [.editProfile]
            return result
        }
        if let account {
            let instance = snapshot?.instance?.name ?? "The server"
            if kind == .expiredToken || account.expiresAt.map({ $0 < Date() }) == true {
                let date =
                    account.expiresAt.map {
                        " (expired on \($0.formatted(date: .abbreviated, time: .omitted)))"
                    } ?? ""
                result.title = "\(instance) rejected the token for \(login)\(date)."
            } else {
                result.title = "\(instance) rejected the credentials for \(login)."
            }
            result.explanation =
                account.method == .oauth
                ? "Reconnect the account to sign in again."
                : "Replace the token in Settings ▸ Accounts (it may have been revoked)."
            result.actions = [.manageAccounts] + switchActions
        }
        return result
    }
}
