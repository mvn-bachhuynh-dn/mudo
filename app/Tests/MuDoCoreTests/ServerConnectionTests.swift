import Foundation
import Testing
@testable import MuDoCore

final class FakeTransport: EventTransport, @unchecked Sendable {
    enum Attempt {
        case events([SSEEvent], end: (any Error)?)
        case eventsThenHang([SSEEvent])
        case hang
    }

    private let lock = NSLock()
    private var attempts: [Attempt]
    private var _calls: [(URL, String)] = []

    init(_ attempts: [Attempt]) { self.attempts = attempts }

    var calls: [(URL, String)] { lock.withLock { _calls } }

    func events(url: URL, token: String) -> AsyncThrowingStream<SSEEvent, any Error> {
        let attempt: Attempt = lock.withLock {
            _calls.append((url, token))
            return attempts.isEmpty ? .hang : attempts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch attempt {
            case let .events(events, end):
                for e in events { continuation.yield(e) }
                continuation.finish(throwing: end)
            case let .eventsThenHang(events):
                for e in events { continuation.yield(e) }
            case .hang:
                break
            }
        }
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Duration] = []
    var values: [Duration] { lock.withLock { _values } }
    func record(_ d: Duration) { lock.withLock { _values.append(d) } }
}

@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
@Suite struct ServerConnectionTests {
    let server = ServerConfig(id: UUID(), name: "a", daemonURL: URL(string: "http://h:7879")!, codeServerURL: nil)
    static let snapshot = SSEEvent(event: "snapshot", data: #"{"server_now":"2026-10-16T09:49:45Z","host":"h","sessions":[{"id":"1","agent":"claude","host":"h","cwd":"/x","project":"x","state":"done","state_since":"2026-10-16T09:49:45Z","last_prompt":""}]}"#)
    static let upsert2 = SSEEvent(event: "upsert", data: #"{"server_now":"2026-10-16T09:49:45Z","session":{"id":"2","agent":"kiro","host":"h","cwd":"/y","project":"y","state":"running","state_since":"2026-10-16T09:49:45Z","last_prompt":""}}"#)

    private func make(_ transport: FakeTransport, _ sleeps: SleepRecorder,
                      onAckRetry: @escaping @MainActor ([SessionKey]) -> Void = { _ in }) -> (SessionStore, ServerConnection) {
        let store = SessionStore(clock: { Date() })
        store.setServers([server])
        let conn = ServerConnection(config: server, token: "tok", store: store, transport: transport,
                                    sleep: { sleeps.record($0) }, onAckRetry: onAckRetry)
        return (store, conn)
    }

    @Test func connectsAndAppliesSnapshot() async {
        let transport = FakeTransport([.events([Self.snapshot], end: nil)])
        let (store, conn) = make(transport, SleepRecorder())
        conn.start()
        #expect(await eventually { store.session(SessionKey(serverID: server.id, sessionID: "1")) != nil })
        #expect(transport.calls.first?.0.absoluteString == "http://h:7879/v1/stream")
        #expect(transport.calls.first?.1 == "tok")
        conn.stop()
    }

    @Test func statusConnectingThenConnected() async {
        let transport = FakeTransport([.eventsThenHang([Self.snapshot])])
        let (store, conn) = make(transport, SleepRecorder())
        conn.start()
        #expect(store.status(of: server.id) == .connecting)
        #expect(await eventually { store.status(of: server.id) == .connected })
        conn.stop()
    }

    @Test func streamEndAfterConnectGoesOffline() async {
        let transport = FakeTransport([.events([Self.snapshot], end: nil)])
        let sleeps = SleepRecorder()
        let (store, conn) = make(transport, sleeps)
        conn.start()
        #expect(await eventually { transport.calls.count == 2 })
        #expect(store.status(of: server.id) == .offline)
        #expect(sleeps.values == [.seconds(1)])
        conn.stop()
    }

    @Test func backoffDoublesAndResetsAfterConnect() async {
        let failure = URLError(.notConnectedToInternet)
        let transport = FakeTransport([
            .events([], end: failure),
            .events([], end: failure),
            .events([Self.snapshot], end: failure),
            .events([], end: failure),
        ])
        let sleeps = SleepRecorder()
        let (store, conn) = make(transport, sleeps)
        conn.start()
        #expect(await eventually { transport.calls.count == 5 })
        #expect(sleeps.values == [.seconds(1), .seconds(2), .seconds(1), .seconds(2)])
        #expect(store.status(of: server.id) == .offline)
        conn.stop()
    }

    @Test func unauthorizedStopsRetrying() async {
        let transport = FakeTransport([.events([], end: StreamError.unauthorized)])
        let sleeps = SleepRecorder()
        let (store, conn) = make(transport, sleeps)
        conn.start()
        #expect(await eventually { store.status(of: server.id) == .unauthorized })
        for _ in 0..<50 { await Task.yield() }
        #expect(transport.calls.count == 1)
        #expect(sleeps.values.isEmpty)
        conn.reconnectNow()
        for _ in 0..<50 { await Task.yield() }
        #expect(transport.calls.count == 1)
        conn.start()
        #expect(await eventually { transport.calls.count == 2 })
        conn.stop()
    }

    @Test func malformedMessagesSkipped() async {
        let transport = FakeTransport([.events([
            Self.snapshot,
            SSEEvent(event: "upsert", data: "{"),
            SSEEvent(event: "mystery", data: "{}"),
            Self.upsert2,
        ], end: nil)])
        let (store, conn) = make(transport, SleepRecorder())
        conn.start()
        #expect(await eventually { store.session(SessionKey(serverID: server.id, sessionID: "2")) != nil })
        conn.stop()
    }

    @Test func ackRetriesForwarded() async {
        var forwarded: [SessionKey] = []
        let transport = FakeTransport([.events([Self.snapshot], end: nil)])
        let (store, conn) = make(transport, SleepRecorder(), onAckRetry: { forwarded += $0 })
        let key = SessionKey(serverID: server.id, sessionID: "1")
        store.markAckFailed(key)
        conn.start()
        #expect(await eventually { forwarded == [key] })
        conn.stop()
    }

    @Test func stopPreventsFurtherStoreWrites() async {
        let transport = FakeTransport([])
        let (store, conn) = make(transport, SleepRecorder())
        conn.start()
        #expect(await eventually { transport.calls.count == 1 })
        conn.stop()
        store.setStatus(.connected, for: server.id)
        for _ in 0..<50 { await Task.yield() }
        #expect(store.status(of: server.id) == .connected)
    }
}

@Suite struct BackoffTests {
    @Test func sequence() {
        var b = Backoff()
        #expect((0..<7).map { _ in b.next() } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
        b.reset()
        #expect(b.next() == .seconds(1))
    }
}
