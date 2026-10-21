import Foundation
import Security

/// Stores one secret per provider in the login keychain.
enum Keychain {
    /// Test runs can point at a separate service so real keys are never touched.
    static let service = "local.loadlens.ai"
        + (ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"].map { "." + $0 } ?? "")

    /// Location used before multi-provider support (DeepSeek only).
    static let legacyService = "local.loadlens.deepseek"
    static let legacyAccount = "api-key"

    @discardableResult
    static func save(_ value: String, account: String, service: String = service) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = data
        if let access = openAccess() {
            attributes[kSecAttrAccess as String] = access
        }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Access that lets any app of this user read the item without a prompt (like `security -A`).
    ///
    /// Locally built copies have no Apple team ID, so macOS ties Keychain permission to each build's
    /// hash and asks again after every rebuild. The user chose convenience over that per-build check;
    /// the trade-off is that other programs running as this user could read the key, much like a
    /// config file.
    private static func openAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("负载侦探 API Key" as CFString, [] as CFArray, &access) == errSecSuccess,
              let access else { return nil }
        if let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] {
            for acl in acls {
                // A nil application list means "any application".
                SecACLSetContents(acl, nil, "负载侦探 API Key" as CFString, SecKeychainPromptSelector())
            }
        }
        return access
    }

    static func load(account: String, service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func delete(account: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
