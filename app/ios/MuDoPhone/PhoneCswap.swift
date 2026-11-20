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
    /// Set when a refresh is requested while one is in flight.
    @ObservationIgnored private var refreshAgain = false

    @ObservationIgnored private let client = CswapClient()
    @ObservationIgnored private let servers: @MainActor () -> [(config: ServerConfig, token: String)]

    init(servers: @escaping @MainActor () -> [(config: ServerConfig, token: String)]) {
        self.servers = servers
    }

    var current: CswapSource? { sources.first { $0.id == selectedID } ?? sources.first }

    func refresh() async {
        if loading { refreshAgain = true; return }
        loading = true
        defer { loading = false }
        repeat {
            refreshAgain = false
            let loaded = await CswapSources.loadRemote(servers: servers(), client: client)
            // Leaving the tab cancels the fetch; its failures are not a result.
            if Task.isCancelled { break }
            sources = loaded
            if !sources.contains(where: { $0.id == selectedID }), let first = sources.first {
                selectedID = first.id
            }
        } while refreshAgain
    }

    func switchTo(_ account: CswapAccount, in source: CswapSource) async {
        guard switching == nil,
              let entry = servers().first(where: { $0.config.id.uuidString == source.id }) else { return }
        switching = "\(source.id)/\(account.number)"
        defer { switching = nil }
        let result = await client.switchTo(account.number, daemon: entry.config.daemonURL, token: entry.token)
        // Let any in-flight fetch finish (it may predate the switch), then reload.
        while loading { try? await Task.sleep(for: .milliseconds(100)) }
        await refresh()
        if case .failure(let failure) = result, let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].error = failure.message
        }
    }
}
