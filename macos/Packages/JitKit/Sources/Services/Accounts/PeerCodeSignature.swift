import Darwin
import Foundation
import Security

/// Code-signature check of the credential helper on the other end of the broker socket (ADR-0016, completed in
/// Phase 7 / ADR-0046). When Jit itself is signed with a Developer ID, the peer must be valid code signed by the
/// same team — on top of the executable-path check. Ad-hoc and development builds have no team, so only the
/// path check applies to them.
enum PeerCodeSignature {
    /// The Team ID Jit is signed with, or `nil` (ad-hoc / unsigned / development).
    static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// The designated-requirement text for "Apple-anchored Developer ID code of `team`"; `nil` for a malformed team.
    static func requirement(team: String) -> String? {
        guard !team.isEmpty, team.count <= 20, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Whether the process on the other end of the Unix socket `descriptor` is valid code signed by `team`.
    /// Uses the peer's audit token (not its pid), so a recycled pid cannot pass.
    static func peer(_ descriptor: Int32, isSignedByTeam team: String) -> Bool {
        guard let text = requirement(team: team) else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}
