import Foundation
import MuDoCore

enum Loader {
    /// Builds the entry for the server with this id, or for the first server when `serverID` is nil or unknown.
    static func load(serverID: String?, content: ContentChoice) async -> MuDoEntry {
        let servers = ServerStore.load()
        guard let config = servers.first(where: { $0.id.uuidString == serverID }) ?? servers.first else {
            return MuDoEntry(date: .now, message: "Open MuDo to add a server", content: content)
        }
        let token = KeychainStore.read(config.id.uuidString) ?? ""
        guard !token.isEmpty else {
            return MuDoEntry(date: .now, serverName: config.name, message: "Open MuDo: token missing", content: content)
        }
        async let accountsResult = CswapClient(timeout: 10).list(daemon: config.daemonURL, token: token)
        async let sessionsResult = SessionSnapshot.fetch(daemon: config.daemonURL, token: token, transport: URLSessionTransport())
        var entry = MuDoEntry(date: .now, serverName: config.name, content: content)
        switch await accountsResult {
        case .success(let list):
            let usableFirst = ServerStore.sortUsableFirst
            entry.accounts = CswapOrder.sorted(list.accounts, usableFirst: usableFirst)
        case .failure(let failure):
            entry.accountsError = failure.message
        }
        switch await sessionsResult {
        case .success(let snapshot):
            entry.sessions = RecentSessions.pick(snapshot.sessions, serverNow: snapshot.serverNow)
        case .failure(let failure):
            entry.sessionsError = failure.message
        }
        return entry
    }
}
