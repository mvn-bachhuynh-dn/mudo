import Foundation
import MuDoCore
import Observation

/// User settings (spec 6.5). Server list and numbers in UserDefaults, tokens in the Keychain.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let servers = "servers"
        static let stale = "staleMinutes"
        static let snooze = "snoozeMinutes"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var servers: [ServerConfig]
    var staleMinutes: Int {
        didSet { defaults.set(staleMinutes, forKey: Key.stale) }
    }
    var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: Key.snooze) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = defaults.data(forKey: Key.servers)
            .flatMap { try? JSONDecoder().decode([ServerConfig].self, from: $0) } ?? []
        let stale = defaults.integer(forKey: Key.stale)
        staleMinutes = stale > 0 ? stale : 5
        let snooze = defaults.integer(forKey: Key.snooze)
        snoozeMinutes = snooze > 0 ? snooze : 10
    }

    func token(for id: UUID) -> String {
        Keychain.read(account: id.uuidString) ?? ""
    }

    func setToken(_ token: String, for id: UUID) {
        Keychain.write(token, account: id.uuidString)
    }

    @discardableResult
    func add(_ draft: ServerDraft) -> ServerConfig {
        if let i = servers.firstIndex(where: { $0.daemonURL == draft.daemonURL }) {
            servers[i].name = draft.name
            if let cs = draft.codeServerURL { servers[i].codeServerURL = cs }
            setToken(draft.token, for: servers[i].id)
            save()
            return servers[i]
        }
        let config = ServerConfig(id: UUID(), name: draft.name, daemonURL: draft.daemonURL,
                                  codeServerURL: draft.codeServerURL)
        servers.append(config)
        setToken(draft.token, for: config.id)
        save()
        return config
    }

    func update(_ config: ServerConfig, token: String) {
        guard let i = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[i] = config
        setToken(token, for: config.id)
        save()
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        Keychain.delete(account: id.uuidString)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Key.servers)
        }
    }
}
