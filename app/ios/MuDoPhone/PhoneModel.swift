import Foundation
import MuDoCore
import Observation

@MainActor
@Observable
final class PhoneModel {
    let store = SessionStore()
    private(set) var servers: [ServerConfig] = []
    /// A server from a `mudo://add` link, waiting for the user to confirm.
    var pendingDraft: ServerDraft?

    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    @ObservationIgnored private var active = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let serversKey = "servers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store.hideIdleAfter = TimeInterval(IdleFold.defaultHours * 3600)
        if let data = defaults.data(forKey: Self.serversKey),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved.filter { !$0.managedLocal }
        }
        store.setServers(servers)
    }

    func token(for id: UUID) -> String { KeychainStore.read(id.uuidString) ?? "" }

    var cswapServers: [(config: ServerConfig, token: String)] {
        servers.map { ($0, token(for: $0.id)) }
    }

    /// Adds a server, or updates the name and token of the one with the same address.
    /// Returns false when the token could not be saved to the Keychain.
    @discardableResult
    func add(_ draft: ServerDraft) -> Bool {
        if let i = servers.firstIndex(where: { $0.daemonURL == draft.daemonURL }) {
            let id = servers[i].id
            guard KeychainStore.write(draft.token, account: id.uuidString) else { return false }
            servers[i].name = draft.name
            if let cs = draft.codeServerURL { servers[i].codeServerURL = cs }
            connections[id]?.stop()
            connections[id] = nil
            persist()
            if active { connect(servers[i]) }
            return true
        }
        let config = ServerConfig(id: UUID(), name: draft.name, daemonURL: draft.daemonURL,
                                  codeServerURL: draft.codeServerURL)
        guard KeychainStore.write(draft.token, account: config.id.uuidString) else { return false }
        servers.append(config)
        persist()
        if active { connect(config) }
        return true
    }

    func remove(_ id: UUID) {
        connections[id]?.stop()
        connections[id] = nil
        KeychainStore.delete(account: id.uuidString)
        servers.removeAll { $0.id == id }
        persist()
    }

    /// True while the app is in the foreground: connect every server; false: drop all connections.
    func setActive(_ on: Bool) {
        active = on
        if on {
            for connection in connections.values { connection.reconnectNow() }
            for config in servers where connections[config.id] == nil { connect(config) }
        } else {
            for connection in connections.values { connection.stop() }
            connections = [:]
        }
    }

    func handle(url: URL) {
        if let draft = AddLink.parse(url) { pendingDraft = draft }
    }

    private func connect(_ config: ServerConfig) {
        let connection = ServerConnection(config: config, token: token(for: config.id),
                                          store: store, transport: URLSessionTransport())
        connections[config.id] = connection
        connection.start()
    }

    private func persist() {
        store.setServers(servers)
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Self.serversKey) }
    }
}
