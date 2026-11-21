import Foundation
import MuDoCore

/// The server list and the sort switch shared by the app and the widget, as Keychain items in the shared group.
enum ServerStore {
    private static let serversAccount = "servers"
    private static let prefsAccount = "prefs"
    private struct Prefs: Codable { var sortUsableFirst: Bool }

    static func load() -> [ServerConfig] {
        guard let data = KeychainStore.readData(serversAccount),
              let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return saved.filter { !$0.managedLocal }
    }

    static func save(_ servers: [ServerConfig]) {
        if let data = try? JSONEncoder().encode(servers) { _ = KeychainStore.writeData(data, account: serversAccount) }
    }

    /// Whether usable accounts are listed first; true when never set.
    static var sortUsableFirst: Bool {
        get {
            guard let data = KeychainStore.readData(prefsAccount),
                  let prefs = try? JSONDecoder().decode(Prefs.self, from: data) else { return true }
            return prefs.sortUsableFirst
        }
        set {
            if let data = try? JSONEncoder().encode(Prefs(sortUsableFirst: newValue)) {
                _ = KeychainStore.writeData(data, account: prefsAccount)
            }
        }
    }

    /// After an update: copies the list and the sort switch from the standard defaults, once
    /// (only when the Keychain item is absent).
    static func migrateFromStandardDefaults() {
        let defaults = UserDefaults.standard
        if KeychainStore.readData(serversAccount) == nil, let old = defaults.data(forKey: serversAccount) {
            _ = KeychainStore.writeData(old, account: serversAccount)
        }
        if KeychainStore.readData(prefsAccount) == nil,
           let sort = defaults.object(forKey: SharedConfig.sortKey) as? Bool {
            sortUsableFirst = sort
        }
    }
}
