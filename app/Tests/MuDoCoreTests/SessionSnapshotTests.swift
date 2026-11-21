import Foundation
import Testing
@testable import MuDoCore

@Suite struct SessionSnapshotTests {
    private static let snapshotJSON = """
    {"server_now":"2026-11-21T01:00:00Z","host":"devbox","sessions":[{"id":"s1","agent":"claude","host":"devbox","cwd":"/p","project":"p","state":"waiting","state_since":"2026-11-21T00:59:00Z","last_prompt":"hi"}]}
    """
    private static let pingJSON = "{\"server_now\":\"2026-11-21T01:00:00Z\"}"

    private struct FakeTransport: EventTransport {
        var events: [SSEEvent] = []
        var error: (any Error)?
        var hangs = false
        func events(url: URL, token: String) -> AsyncThrowingStream<SSEEvent, any Error> {
            AsyncThrowingStream { continuation in
                if hangs { return }
                for e in events { continuation.yield(e) }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
        }
    }

    private let daemon = URL(string: "http://100.64.0.10:7879")!

    @Test func firstReturnsTheSnapshotSessions() async throws {
        let transport = FakeTransport(events: [SSEEvent(event: "ping", data: Self.pingJSON),
                                               SSEEvent(event: "snapshot", data: Self.snapshotJSON)])
        let sessions = try await SessionSnapshot.first(from: transport.events(url: daemon, token: "t"))
        #expect(sessions?.map(\.id) == ["s1"])
    }

    @Test func firstIsNilWithoutASnapshot() async throws {
        let transport = FakeTransport(events: [SSEEvent(event: "ping", data: Self.pingJSON)])
        #expect(try await SessionSnapshot.first(from: transport.events(url: daemon, token: "t")) == nil)
    }

    @Test func fetchReturnsTheSessions() async {
        let transport = FakeTransport(events: [SSEEvent(event: "snapshot", data: Self.snapshotJSON)])
        let result = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport)
        #expect((try? result.get())?.map(\.id) == ["s1"])
    }

    @Test func fetchMapsUnauthorized() async {
        let transport = FakeTransport(error: StreamError.unauthorized)
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .unauthorized)
        #expect(f.message == "token invalid")
    }

    @Test func fetchMapsHttpErrors() async {
        let transport = FakeTransport(error: StreamError.http(503))
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .http(503))
        #expect(f.message == "HTTP 503")
    }

    @Test func fetchReportsNoSnapshot() async {
        let transport = FakeTransport(events: [])
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .noSnapshot)
    }

    @Test func fetchTimesOut() async {
        let transport = FakeTransport(hangs: true)
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport,
                                                                timeout: .milliseconds(100)) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .timeout)
    }
}
