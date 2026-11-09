import Foundation
import Security

/// What a Keychain item holds (design §4.3). The account attribute is a Jit ID — never a login or host, so
/// the item list doesn't reveal which accounts a user has beyond its label.
public enum SecretKind: String, Sendable, Hashable {
    /// PAT bytes, or OAuth token JSON.
    case account
    case sshPassphrase = "ssh-passphrase"
    case proxy
}

public struct SecretReference: Sendable, Hashable {
    public var kind: SecretKind
    public var id: String

    public init(_ kind: SecretKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func account(_ id: HostingAccountID) -> SecretReference { SecretReference(.account, id: id.rawValue) }
    public static func proxy(_ id: ProxyConfigID) -> SecretReference { SecretReference(.proxy, id: id.rawValue) }
    public static func passphrase(fingerprint: String) -> SecretReference {
        SecretReference(.sshPassphrase, id: fingerprint)
    }
}

public enum KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound
    case interactionNotAllowed
    case authFailed
    case unexpected(OSStatus)

    init(_ status: OSStatus) {
        switch status {
        case errSecItemNotFound: self = .notFound
        case errSecInteractionNotAllowed: self = .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled: self = .authFailed
        default: self = .unexpected(status)
        }
    }

    public var description: String {
        switch self {
        case .notFound: "The Keychain has no item for this account."
        case .interactionNotAllowed: "The Keychain is locked."
        case .authFailed: "Access to the Keychain item was denied."
        case .unexpected(let status): "Keychain error \(status)."
        }
    }
}

/// Where secrets are stored. The production store is the Keychain; tests use an in-memory store or a Keychain
/// store with a test service prefix.
public protocol SecretStore: Sendable {
    func store(_ secret: SecretBytes, for reference: SecretReference, label: String) async throws(KeychainError)
    func read(_ reference: SecretReference) async throws(KeychainError) -> SecretBytes
    func delete(_ reference: SecretReference) async throws(KeychainError)
    func exists(_ reference: SecretReference) async -> Bool
}

/// Generic-password items: service `<prefix>.<kind>`, account = Jit ID, `WhenUnlockedThisDeviceOnly`, never
/// synchronized (ADR-0035). Uses the data-protection keychain when the process is signed with a team (the
/// entitlement is present); unsigned dev builds fall back to the file-based login keychain. All calls run off
/// the main actor.
public struct KeychainStore: SecretStore {
    public let servicePrefix: String
    let useDataProtection: Bool

    public init(servicePrefix: String = Bundle.main.bundleIdentifier ?? "com.ashkanrmk.jit") {
        self.servicePrefix = servicePrefix
        useDataProtection = Self.hasDataProtectionKeychain()
    }

    func service(_ kind: SecretKind) -> String { "\(servicePrefix).\(kind.rawValue)" }

    private func baseQuery(_ reference: SecretReference) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(reference.kind),
            kSecAttrAccount as String: reference.id,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if useDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    @concurrent
    public func store(_ secret: SecretBytes, for reference: SecretReference, label: String) async throws(KeychainError)
    {
        let data = secret.dataCopy()
        var query = baseQuery(reference)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = label
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    @concurrent
    public func read(_ reference: SecretReference) async throws(KeychainError) -> SecretBytes {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return SecretBytes(data)
    }

    @concurrent
    public func delete(_ reference: SecretReference) async throws(KeychainError) {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    @concurrent
    public func exists(_ reference: SecretReference) async -> Bool {
        var query = baseQuery(reference)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The stored item's protection attributes (tests assert ThisDeviceOnly / non-synchronizable).
    public func attributes(_ reference: SecretReference) -> [String: Any]? {
        var query = baseQuery(reference)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    /// The data-protection keychain needs a signed app with an application identifier; probing the
    /// entitlement avoids `errSecMissingEntitlement` on unsigned dev builds.
    static func hasDataProtectionKeychain() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
        return value != nil
    }
}

/// In-memory secrets for tests and previews (never used by the app).
public actor MemorySecretStore: SecretStore {
    private var items: [SecretReference: SecretBytes] = [:]
    public private(set) var labels: [SecretReference: String] = [:]

    public init() {}

    public func store(_ secret: SecretBytes, for reference: SecretReference, label: String) throws(KeychainError) {
        items[reference] = SecretBytes(secret.dataCopy())
        labels[reference] = label
    }

    public func read(_ reference: SecretReference) throws(KeychainError) -> SecretBytes {
        guard let secret = items[reference] else { throw .notFound }
        return secret
    }

    public func delete(_ reference: SecretReference) throws(KeychainError) {
        items[reference] = nil
        labels[reference] = nil
    }

    public func exists(_ reference: SecretReference) -> Bool { items[reference] != nil }
}
