import Foundation
import MuDoCore

/// The server list and the sort switch shared by the app and the widget, as Keychain items in the shared group.
enum ServerStore {
    private static let serversAccount = "servers"
    private static let prefsAccount = "prefs"
    private struct Prefs: Codable {
        var sortUsableFirst: Bool
        var slackTeamID: String

        init(sortUsableFirst: Bool = true, slackTeamID: String = "") {
            self.sortUsableFirst = sortUsableFirst
            self.slackTeamID = slackTeamID
        }

        /// An item saved before `slackTeamID` existed has no such key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sortUsableFirst = try c.decode(Bool.self, forKey: .sortUsableFirst)
            slackTeamID = try c.decodeIfPresent(String.self, forKey: .slackTeamID) ?? ""
        }
    }

    private static func loadPrefs() -> Prefs {
        guard let data = KeychainStore.readData(prefsAccount),
              let prefs = try? JSONDecoder().decode(Prefs.self, from: data) else { return Prefs() }
        return prefs
    }

    private static func savePrefs(_ prefs: Prefs) {
        if let data = try? JSONEncoder().encode(prefs) { _ = KeychainStore.writeData(data, account: prefsAccount) }
    }

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
        get { loadPrefs().sortUsableFirst }
        set { var prefs = loadPrefs(); prefs.sortUsableFirst = newValue; savePrefs(prefs) }
    }

    /// Slack workspace ID (T...) used for sessions that do not carry one; empty when never set.
    static var slackTeamID: String {
        get { loadPrefs().slackTeamID }
        set { var prefs = loadPrefs(); prefs.slackTeamID = newValue; savePrefs(prefs) }
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
