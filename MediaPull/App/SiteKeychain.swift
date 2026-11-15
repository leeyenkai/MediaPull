import Foundation
import MediaPullCore
import Security

/// The person's own API keys for sites (SPEC R-1111b), kept in the login Keychain, never in preferences or files.
enum SiteKeychain {
    private static let service = "MediaPull site keys"

    private static func account(_ category: String, _ option: String) -> String { "\(category).\(option)" }

    static func value(_ category: String, _ option: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(category, option), kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, _ category: String, _ option: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account(category, option)]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// The keys saved for a site, by gallery-dl option name.
    static func keys(for category: String, fields: [SiteKeys.Field]) -> [String: String] {
        var keys: [String: String] = [:]
        for field in fields { if let value = value(category, field.option) { keys[field.option] = value } }
        return keys
    }
}
