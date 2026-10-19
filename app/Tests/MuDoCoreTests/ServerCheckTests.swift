import Foundation
import Testing
@testable import MuDoCore

@Suite struct ServerCheckTests {
    @Test func healthyDaemonReportsVersion() {
        let body = Data(#"{"version":"0.1.0","uptime_s":12}"#.utf8)
        #expect(ServerCheck.daemon(status: 200, body: body, error: nil) == .ok(version: "0.1.0"))
    }

    @Test func okWithoutVersion() {
        #expect(ServerCheck.daemon(status: 200, body: Data("<html>".utf8), error: nil) == .ok(version: "?"))
    }

    @Test func badToken() {
        #expect(ServerCheck.daemon(status: 401, body: nil, error: nil) == .unauthorized)
    }

    @Test func otherStatus() {
        #expect(ServerCheck.daemon(status: 404, body: nil, error: nil) == .http(404))
    }

    @Test func noResponse() {
        #expect(ServerCheck.daemon(status: nil, body: nil, error: "timed out") == .unreachable("timed out"))
        #expect(ServerCheck.isOK(.unreachable("x")) == false)
    }

    @Test func codeServerAnyStatusIsReachable() {
        #expect(ServerCheck.codeServer(status: 302, error: nil) == .reachable(302))
        #expect(ServerCheck.codeServer(status: nil, error: "refused") == .unreachable("refused"))
        #expect(ServerCheck.message(.notSet) == nil)
    }
}
