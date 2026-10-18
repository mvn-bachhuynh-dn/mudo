import Foundation
import MuDoCore
import Observation
import Security

/// User settings (spec 6.5). Server list and numbers in UserDefaults, tokens in the Keychain.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let servers = "servers"
        static let stale = "staleMinutes"
        static let snooze = "snoozeMinutes"
        static let ignoredPaths = "ignoredPaths"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Tokens read from or written to the Keychain this launch, so each server's token
    /// is read at most once (every read can trigger a Keychain access prompt).
    @ObservationIgnored private var tokenCache: [UUID: String] = [:]
    /// Servers whose Keychain read failed; not retried until `reloadToken(for:)`.
    @ObservationIgnored private var failedReads: Set<UUID> = []

    private(set) var servers: [ServerConfig]
    /// The server added by Monitor this Mac, if any: the only one whose mudod the app manages.
    var localServer: ServerConfig? { servers.first(where: \.managedLocal) }
    /// Set when a token save or read failed; nil after a successful save.
    private(set) var keychainError: String?
    var staleMinutes: Int {
        didSet { defaults.set(staleMinutes, forKey: Key.stale) }
    }
    var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: Key.snooze) }
    }

    static let defaultIgnoredPaths = ["*/kirocrew-workspace/_bg*", "/tmp/*"]

    /// Glob patterns for session folders to hide, one per entry.
    var ignoredPaths: [String] {
        didSet { defaults.set(ignoredPaths, forKey: Key.ignoredPaths) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = defaults.data(forKey: Key.servers)
            .flatMap { try? JSONDecoder().decode([ServerConfig].self, from: $0) } ?? []
        let stale = defaults.integer(forKey: Key.stale)
        staleMinutes = stale > 0 ? stale : 5
        let snooze = defaults.integer(forKey: Key.snooze)
        snoozeMinutes = snooze > 0 ? snooze : 10
        ignoredPaths = defaults.stringArray(forKey: Key.ignoredPaths) ?? Self.defaultIgnoredPaths
    }

    /// The server's token; "" when none is stored; nil when the Keychain read failed.
    /// Served from the in-memory cache; the Keychain is read only on first access.
    func token(for id: UUID) -> String? {
        if let cached = tokenCache[id] { return cached }
        if failedReads.contains(id) { return nil }
        return readToken(for: id)
    }

    /// Like `token(for:)`, but retries a Keychain read that failed earlier
    /// (used when Settings explicitly loads a server).
    func reloadToken(for id: UUID) -> String? {
        if let cached = tokenCache[id] { return cached }
        failedReads.remove(id)
        return readToken(for: id)
    }

    private func readToken(for id: UUID) -> String? {
        let (value, status) = Keychain.read(account: id.uuidString)
        if status == errSecSuccess || status == errSecItemNotFound {
            let token = status == errSecSuccess ? value ?? "" : ""
            tokenCache[id] = token
            return token
        }
        failedReads.insert(id)
        keychainError = "Could not read the token from the Keychain (OSStatus \(status))."
        return nil
    }

    func setToken(_ token: String, for id: UUID) {
        let status = Keychain.write(token, account: id.uuidString)
        if status == errSecSuccess {
            tokenCache[id] = token
            failedReads.remove(id)
            keychainError = nil
        } else {
            keychainError = "Could not save the token in the Keychain (OSStatus \(status))."
        }
    }

    /// `managedLocal`: added by Monitor this Mac. Re-adding a server never clears the flag.
    @discardableResult
    func add(_ draft: ServerDraft, managedLocal: Bool = false) -> ServerConfig {
        if let i = servers.firstIndex(where: { $0.daemonURL == draft.daemonURL }) {
            servers[i].name = draft.name
            if managedLocal { servers[i].managedLocal = true }
            if let cs = draft.codeServerURL { servers[i].codeServerURL = cs }
            setToken(draft.token, for: servers[i].id)
            save()
            return servers[i]
        }
        let config = ServerConfig(id: UUID(), name: draft.name, daemonURL: draft.daemonURL,
                                  codeServerURL: draft.codeServerURL, managedLocal: managedLocal)
        servers.append(config)
        setToken(draft.token, for: config.id)
        save()
        return config
    }

    /// A nil token leaves the stored token untouched.
    func update(_ config: ServerConfig, token: String?) {
        guard let i = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[i] = config
        if let token { setToken(token, for: config.id) }
        save()
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        Keychain.delete(account: id.uuidString)
        tokenCache[id] = nil
        failedReads.remove(id)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Key.servers)
        }
    }
}
