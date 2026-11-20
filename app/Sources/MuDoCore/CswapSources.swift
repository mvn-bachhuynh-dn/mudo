import Foundation

/// Where a list of cswap accounts lives: cswap keeps its own accounts per machine, so the Mac
/// and each mudod server that has cswap installed are separate sources.
public struct CswapSource: Identifiable, Equatable, Sendable {
    /// "local" (Mac app only) or the server's UUID string.
    public var id: String
    public var name: String
    public var accounts: [CswapAccount]
    public var error: String?

    public init(id: String, name: String, accounts: [CswapAccount] = [], error: String? = nil) {
        self.id = id
        self.name = name
        self.accounts = accounts
        self.error = error
    }
}

public enum CswapSources {
    /// One source per server that answers `GET /v1/cswap`, in the order of `servers`. A server
    /// without cswap (404, or an older mudod) is left out; any other failure keeps its source with
    /// the error text so the UI can show it.
    public static func loadRemote(servers: [(config: ServerConfig, token: String)],
                                  client: CswapClient) async -> [CswapSource] {
        await withTaskGroup(of: (Int, CswapSource?).self) { group in
            for (index, entry) in servers.enumerated() {
                group.addTask {
                    var source = CswapSource(id: entry.config.id.uuidString, name: entry.config.name)
                    switch await client.list(daemon: entry.config.daemonURL, token: entry.token) {
                    case .success(let result):
                        source.accounts = result.accounts
                    case .failure(.notAvailable):
                        return (index, nil)
                    case .failure(let failure):
                        source.error = failure.message
                    }
                    return (index, source)
                }
            }
            var found: [(Int, CswapSource)] = []
            for await (index, source) in group {
                if let source { found.append((index, source)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
