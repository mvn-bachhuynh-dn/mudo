import Foundation
import MuDoCore
import Observation

@MainActor
@Observable
final class PhoneCswap {
    private(set) var sources: [CswapSource] = []
    var selectedID = ""
    private(set) var loading = false
    /// "<source id>/<account number>" while a switch runs.
    private(set) var switching: String?

    @ObservationIgnored private let client = CswapClient()
    @ObservationIgnored private let servers: @MainActor () -> [(config: ServerConfig, token: String)]

    init(servers: @escaping @MainActor () -> [(config: ServerConfig, token: String)]) {
        self.servers = servers
    }

    var current: CswapSource? { sources.first { $0.id == selectedID } ?? sources.first }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        sources = await CswapSources.loadRemote(servers: servers(), client: client)
        if !sources.contains(where: { $0.id == selectedID }), let first = sources.first {
            selectedID = first.id
        }
    }

    func switchTo(_ account: CswapAccount, in source: CswapSource) async {
        guard switching == nil,
              let entry = servers().first(where: { $0.config.id.uuidString == source.id }) else { return }
        switching = "\(source.id)/\(account.number)"
        defer { switching = nil }
        let result = await client.switchTo(account.number, daemon: entry.config.daemonURL, token: entry.token)
        await refresh()
        if case .failure(let failure) = result, let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].error = failure.message
        }
    }
}
