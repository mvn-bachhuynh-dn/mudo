import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MuDoCore

extension StubHTTPTests {
@Suite struct CswapClientTests {
    private let daemon = URL(string: "http://100.64.0.10:7879")!
    private let listJSON = Data("""
    {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
     {"number":2,"email":"user@example.com","organizationName":"Team A","active":true,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":26.0},"sevenDay":{"pct":95.0}}}]}
    """.utf8)

    private func client(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> CswapClient {
        CswapClient(session: StubURLProtocol.session(handler))
    }

    @Test func listParsesAccountsAndSendsBearerGET() async throws {
        let json = listJSON
        let c = client { _ in (200, json) }
        let result = try await c.list(daemon: daemon, token: "fake-token").get()
        #expect(result.accounts.map(\.number) == [2])
        #expect(result.activeNumber == 2)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/v1/cswap")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    }

    @Test func listWorksWithAnIPv6Daemon() async throws {
        let json = listJSON
        let c = client { _ in (200, json) }
        let v6 = URL(string: "http://[fd7a:115c:a1e0::10]:7879")!
        _ = try await c.list(daemon: v6, token: "t").get()
        #expect(StubURLProtocol.requests.first?.url?.host == "fd7a:115c:a1e0::10")
    }

    @Test func notFoundMeansNotAvailable() async {
        let c = client { _ in (404, Data()) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.notAvailable))
    }

    @Test func unauthorizedSaysTokenInvalid() async {
        let c = client { _ in (401, Data()) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("token invalid")))
    }

    @Test func serverErrorShowsFirstBodyLine() async {
        let c = client { _ in (502, Data("cswap exploded\nsecond line".utf8)) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("cswap exploded")))
    }

    @Test func emptyErrorBodyShowsStatus() async {
        let c = client { _ in (500, Data()) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("HTTP 500")))
    }

    @Test func badJSONIsUnexpectedOutput() async {
        let c = client { _ in (200, Data("nope".utf8)) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("Unexpected cswap output")))
    }

    @Test func connectionFailureBecomesAMessage() async {
        let c = client { _ in (0, Data()) }
        guard case .failure(.message(let m)) = await c.list(daemon: daemon, token: "t") else {
            Issue.record("expected a message failure"); return
        }
        #expect(!m.isEmpty)
    }

    @Test func switchPostsToTheNumberedPath() async throws {
        let c = client { _ in (204, Data()) }
        try await c.switchTo(3, daemon: daemon, token: "fake-token").get()
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/cswap/switch/3")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    }

    @Test func switchFailureCarriesTheErrorLine() async {
        let c = client { _ in (502, Data("A newer version is available\nno such account".utf8)) }
        let r = await c.switchTo(9, daemon: daemon, token: "t")
        guard case .failure(let failure) = r else {
            Issue.record("expected a failure"); return
        }
        #expect(failure == .message("no such account"))
    }
}
}
