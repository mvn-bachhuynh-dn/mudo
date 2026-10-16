import Foundation
import Security

/// Generic-password items under service `dev.steve.MuDo`, one per server id.
enum Keychain {
    static let service = "dev.steve.MuDo"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored value with `errSecSuccess`; otherwise nil and the failing status
    /// (`errSecItemNotFound` when there is no item).
    static func read(account: String) -> (value: String?, status: OSStatus) {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { return (nil, status) }
        guard let data = out as? Data, let value = String(data: data, encoding: .utf8) else {
            return (nil, errSecDecode)
        }
        return (value, errSecSuccess)
    }

    /// Returns `errSecSuccess` on success, otherwise the failing status.
    static func write(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query(account)
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
