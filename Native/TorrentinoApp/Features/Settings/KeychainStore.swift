// Layer: UI (Keychain storage for proxy credentials).
// Role: SecItem wrapper for storing, retrieving, and deleting proxy passwords safely.
// Must-not: store passwords in UserDefaults or log them in plaintext.
// Invariants: service is "com.torrentino.app"; account is "proxy_password"; thread-safe.

import Foundation
import Security

public enum KeychainStore {
    private static let service = "com.torrentino.app"
    private static let account = "proxy_password"

    @discardableResult
    public static func saveProxyPassword(_ password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        deleteProxyPassword()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func loadProxyPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data, let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    @discardableResult
    public static func deleteProxyPassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
