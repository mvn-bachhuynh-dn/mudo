import Foundation
import Testing
@testable import MuDoCore

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

func makeSession(_ id: String, _ state: SessionState, since: Date,
                 project: String = "p", prompt: String = "") -> Session {
    Session(id: id, agent: "claude", host: "h", cwd: "/home/x/\(project)", project: project,
            state: state, stateSince: since, lastPrompt: prompt)
}

func makeServer(_ name: String, id: UUID = UUID()) -> ServerConfig {
    ServerConfig(id: id, name: name, daemonURL: URL(string: "http://\(name):7879")!, codeServerURL: nil)
}

@MainActor
@Suite struct SessionStoreTests {
    let t0 = utc(2026, 10, 16, 10, 0, 0)

    @Test func newServersStartConnecting() {
        let store = SessionStore(clock: { Date() })
        let a = makeServer("a")
        store.setServers([a])
        #expect(store.status(of: a.id) == .connecting)
        #expect(store.servers == [ServerRow(id: a.id, name: "a", status: .connecting)])
    }

    @Test func snapshotReplacesOnlyThatServer() {
        let clock = TestClock(t0)
        let store = SessionStore(clock: { clock.now })
        let a = makeServer("a"), b = makeServer("b")
        store.setServers([a, b])
        store.apply(.snapshot(serverNow: t0, host: "a", sessions: [makeSession("1", .idle, since: t0)]), from: a.id)
        store.apply(.snapshot(serverNow: t0, host: "b", sessions: [makeSession("9", .idle, since: t0)]), from: b.id)
        store.apply(.snapshot(serverNow: t0, host: "a", sessions: [makeSession("2", .done, since: t0)]), from: a.id)
        #expect(store.session(SessionKey(serverID: a.id, sessionID: "1")) == nil)
        #expect(store.session(SessionKey(serverID: a.id, sessionID: "2"))?.state == .done)
        #expect(store.session(SessionKey(serverID: b.id, sessionID: "9")) != nil)
    }

    @Test func upsertAndRemove() {
        let store = SessionStore(clock: { Date() })
        let a = makeServer("a")
        store.setServers([a])
        let key = SessionKey(serverID: a.id, sessionID: "1")
        store.apply(.upsert(serverNow: t0, session: makeSession("1", .running, since: t0)), from: a.id)
        #expect(store.session(key)?.state == .running)
        store.apply(.upsert(serverNow: t0, session: makeSession("1", .done, since: t0)), from: a.id)
        #expect(store.session(key)?.state == .done)
        store.apply(.remove(serverNow: t0, id: "1"), from: a.id)
        #expect(store.session(key) == nil)
    }

    @Test func messagesForUnknownServerAreIgnored() {
        let store = SessionStore(clock: { Date() })
        let ghost = UUID()
        store.apply(.upsert(serverNow: t0, session: makeSession("1", .running, since: t0)), from: ghost)
        #expect(store.session(SessionKey(serverID: ghost, sessionID: "1")) == nil)
    }

    @Test func offsetIsServerMinusLocal() {
        let clock = TestClock(t0)
        let store = SessionStore(clock: { clock.now })
        let a = makeServer("a")
        store.setServers([a])
        store.apply(.ping(serverNow: t0.addingTimeInterval(120)), from: a.id)
        #expect(store.offset(of: a.id) == 120)
        clock.advance(10)
        store.apply(.ping(serverNow: t0.addingTimeInterval(125)), from: a.id)
        #expect(store.offset(of: a.id) == 115)
    }

    @Test func setServersDropsRemovedAndKeepsExisting() {
        let store = SessionStore(clock: { Date() })
        let a = makeServer("a"), b = makeServer("b")
        store.setServers([a, b])
        store.setStatus(.connected, for: a.id)
        store.apply(.upsert(serverNow: t0, session: makeSession("1", .idle, since: t0)), from: a.id)
        store.apply(.upsert(serverNow: t0, session: makeSession("2", .idle, since: t0)), from: b.id)
        var renamed = a
        renamed.name = "a2"
        store.setServers([renamed])
        #expect(store.servers == [ServerRow(id: a.id, name: "a2", status: .connected)])
        #expect(store.session(SessionKey(serverID: a.id, sessionID: "1")) != nil)
        #expect(store.session(SessionKey(serverID: b.id, sessionID: "2")) == nil)
        #expect(store.status(of: b.id) == nil)
    }

    @Test func problemServersAndMultipleFlag() {
        let store = SessionStore(clock: { Date() })
        let a = makeServer("a"), b = makeServer("b")
        store.setServers([a])
        #expect(!store.hasMultipleServers)
        store.setServers([a, b])
        #expect(store.hasMultipleServers)
        store.setStatus(.connected, for: a.id)
        store.setStatus(.unauthorized, for: b.id)
        #expect(store.problemServers == [ServerRow(id: b.id, name: "b", status: .unauthorized)])
    }

    @Test func failedAckRetriedOnceOnSnapshotWhenStillDone() {
        let store = SessionStore(clock: { Date() })
        let a = makeServer("a")
        store.setServers([a])
        let k1 = SessionKey(serverID: a.id, sessionID: "1")
        let k2 = SessionKey(serverID: a.id, sessionID: "2")
        store.markAckFailed(k1)
        store.markAckFailed(k2)
        #expect(store.apply(.ping(serverNow: t0), from: a.id).isEmpty)
        let retries = store.apply(.snapshot(serverNow: t0, host: "a", sessions: [
            makeSession("1", .done, since: t0),
            makeSession("2", .idle, since: t0),
        ]), from: a.id)
        #expect(retries == [k1])
        #expect(store.apply(.snapshot(serverNow: t0, host: "a", sessions: [makeSession("1", .done, since: t0)]), from: a.id).isEmpty)
    }

    @Test func tickAdvancesNow() {
        let clock = TestClock(t0)
        let store = SessionStore(clock: { clock.now })
        clock.advance(5)
        store.tick()
        #expect(store.now == t0.addingTimeInterval(5))
    }
}
