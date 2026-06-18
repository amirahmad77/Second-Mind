import Foundation
import Security

/// Tiny keychain wrapper. Single item per key, generic-password class, app's
/// default access group. We avoid SDK-flavored helpers so this stays a single
/// file with zero dependencies.
///
/// Used for: auth session JSON. Anything we can't lose (refresh_token) and
/// anything sensitive (access_token + email).
enum Keychain {

    @discardableResult
    static func set(_ data: Data, for key: String) -> Bool {
        delete(key) // upsert via delete + add
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrAccount as String:  key,
            kSecValueData as String:    data,
            // After-first-unlock, this-device-only: available to background sync
            // (SyncDaemon) once the user has unlocked once after reboot, but the
            // item is excluded from iCloud Keychain backup/migration — the auth
            // token never leaves this device. Right balance for an offline-tolerant
            // app that must not leak credentials to other devices.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
