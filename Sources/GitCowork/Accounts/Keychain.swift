import Foundation
import Security

/// Tokens in the login keychain, one item per host.
enum Keychain {
    private static let service = "git-cowork"

    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    @discardableResult
    static func save(_ data: Data, host: String) -> Bool {
        SecItemDelete(query(host) as CFDictionary)
        var item = query(host)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "git-cowork: \(host)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load(host: String) -> Data? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(host: String) {
        SecItemDelete(query(host) as CFDictionary)
    }
}
