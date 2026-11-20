import Foundation
import Testing
@testable import MuDoCore

extension StubHTTPTests {
@Suite struct CswapSourcesTests {
    private let okJSON = Data("""
    {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
     {"number":1,"email":"user@example.com","organizationName":"","active":true,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":10.0},"sevenDay":{"pct":20.0}}}]}
    """.utf8)

    private func server(_ name: String, host: String) -> (config: ServerConfig, token: String) {
        (ServerConfig(id: UUID(), name: name, daemonURL: URL(string: "http://\(host):7879")!, codeServerURL: nil), "t")
    }

    @Test func keepsOrderDropsNotAvailableAndKeepsErrors() async {
        let json = okJSON
        let a = server("alpha", host: "100.64.0.1")
        let b = server("beta", host: "100.64.0.2")
        let c = server("gamma", host: "100.64.0.3")
        let d = server("delta", host: "100.64.0.4")
        let client = CswapClient(session: StubURLProtocol.session { req in
            switch req.url?.host {
            case "100.64.0.1", "100.64.0.4": return (200, json)
            case "100.64.0.2": return (404, Data())
            default: return (401, Data())
            }
        })
        let sources = await CswapSources.loadRemote(servers: [a, b, c, d], client: client)
        #expect(sources.map(\.name) == ["alpha", "gamma", "delta"])
        #expect(sources[0].id == a.config.id.uuidString)
        #expect(sources[0].accounts.map(\.number) == [1])
        #expect(sources[0].error == nil)
        #expect(sources[1].accounts.isEmpty)
        #expect(sources[1].error == "token invalid")
        #expect(sources[2].accounts.map(\.number) == [1])
    }

    @Test func noServersGivesNoSources() async {
        let client = CswapClient(session: StubURLProtocol.session { _ in (200, Data()) })
        #expect(await CswapSources.loadRemote(servers: [], client: client).isEmpty)
    }
}
}
