import Foundation
import MuDoCore

/// The server list shared by the app and the widget (App Group defaults).
enum ServerStore {
    private static let key = "servers"

    static func load() -> [ServerConfig] {
        guard let data = SharedConfig.defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return saved.filter { !$0.managedLocal }
    }

    static func save(_ servers: [ServerConfig]) {
        if let data = try? JSONEncoder().encode(servers) { SharedConfig.defaults.set(data, forKey: key) }
    }

    /// After an update: copies the list and the sort switch from the standard defaults, once.
    static func migrateFromStandardDefaults() {
        let shared = SharedConfig.defaults
        if shared.data(forKey: key) == nil, let old = UserDefaults.standard.data(forKey: key) {
            shared.set(old, forKey: key)
        }
        if shared.object(forKey: SharedConfig.sortKey) == nil,
           let sort = UserDefaults.standard.object(forKey: SharedConfig.sortKey) as? Bool {
            shared.set(sort, forKey: SharedConfig.sortKey)
        }
    }
}
