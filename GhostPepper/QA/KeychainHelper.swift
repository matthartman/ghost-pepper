import Foundation
import Security

enum KeychainHelper {
    static let service = "com.github.matthartman.ghostpepper"

    static func set(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        if value.isEmpty {
            return true
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    static func migrateUserDefaultsString(defaultsKey: String, keychainKey: String, defaults: UserDefaults = .standard) -> String? {
        if let existing = get(keychainKey), !existing.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
            return existing
        }

        guard let legacy = defaults.string(forKey: defaultsKey), !legacy.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return nil
        }

        if set(legacy, for: keychainKey) {
            defaults.removeObject(forKey: defaultsKey)
        }
        return legacy
    }
}
