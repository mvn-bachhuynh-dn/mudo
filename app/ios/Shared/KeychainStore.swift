import Foundation
import Security

/// Server tokens, one generic-password item per server id, (and other small blobs) in the shared keychain access group.
enum KeychainStore {
    private static let service = "dev.steve.MuDoPhone"

    private static func query(_ account: String, shared: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        // Without a usable shared group (unsigned Simulator build) only the default group is used.
        if shared, let group = SharedConfig.keychainGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func readData(_ account: String, shared: Bool) -> Data? {
        var q = query(account, shared: shared)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// The shared item first, then the legacy one (an update the app has not migrated yet).
    static func readData(_ account: String) -> Data? {
        readData(account, shared: true) ?? readData(account, shared: false)
    }

    /// Writes to the shared group; when that is not possible writes the legacy item so the app keeps working.
    @discardableResult
    static func writeData(_ data: Data, account: String) -> Bool {
        if writeData(data, account: account, shared: true) {
            // Best effort, update only: keeps an old unmigrated item from disagreeing with the shared one.
            SecItemUpdate(query(account, shared: false) as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
            return true
        }
        return writeData(data, account: account, shared: false)
    }

    private static func writeData(_ data: Data, account: String, shared: Bool) -> Bool {
        let status = SecItemUpdate(query(account, shared: shared) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account, shared: shared)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String) -> String? {
        readData(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        writeData(Data(value.utf8), account: account)
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
            guard readData(account, shared: true) == nil, let legacy = readData(account, shared: false) else { continue }
            _ = writeData(legacy, account: account, shared: true)
        }
    }
}
