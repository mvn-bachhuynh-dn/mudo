import Foundation
import Security

/// Server tokens, one generic-password item per server id, in the App Group's keychain access group.
enum KeychainStore {
    private static let service = "dev.steve.MuDoPhone"

    private static func query(_ account: String, shared: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if shared { q[kSecAttrAccessGroup as String] = SharedConfig.appGroup }
        return q
    }

    private static func read(_ account: String, shared: Bool) -> String? {
        var q = query(account, shared: shared)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The shared item first, then the legacy one (an update the app has not migrated yet).
    static func read(_ account: String) -> String? {
        read(account, shared: true) ?? read(account, shared: false)
    }

    /// Writes to the shared group; when that is not possible writes the legacy item so the app keeps working.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if write(value, account: account, shared: true) { return true }
        return write(value, account: account, shared: false)
    }

    private static func write(_ value: String, account: String, shared: Bool) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account, shared: shared) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account, shared: shared)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the item everywhere (an unscoped delete also matches the shared one, which is wanted here).
    static func delete(account: String) {
        SecItemDelete(query(account, shared: true) as CFDictionary)
        SecItemDelete(query(account, shared: false) as CFDictionary)
    }

    /// Copies legacy items into the shared group. The legacy item is NOT deleted: a query without an
    /// access group also matches the shared item, so the delete could remove the copy just written.
    /// The leftover is harmless (reads prefer the shared item; `delete(account:)` removes both).
    static func migrateToSharedGroup(accounts: [String]) {
        for account in accounts {
            guard read(account, shared: true) == nil, let legacy = read(account, shared: false) else { continue }
            _ = write(legacy, account: account, shared: true)
        }
    }
}
