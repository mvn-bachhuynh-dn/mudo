import Foundation
import Testing
@testable import MuDoCore

@MainActor
@Suite struct SessionStoreRowsTests {
    let t0 = utc(2026, 10, 16, 10, 0, 0)

    private func connectedStore(_ clock: TestClock, _ sessions: [Session], offset: TimeInterval = 0)
        -> (SessionStore, ServerConfig) {
        let store = SessionStore(clock: { clock.now })
        let a = makeServer("a")
        store.setServers([a])
        store.setStatus(.connected, for: a.id)
        store.apply(.snapshot(serverNow: clock.now.addingTimeInterval(offset), host: "a", sessions: sessions), from: a.id)
        return (store, a)
    }

    @Test func staleThreshold() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .done, since: t0)])
        clock.advance(299)
        store.tick()
        #expect(store.rows.map(\.bucket) == [.done])
        #expect(store.rows[0].blinking == false)
        clock.advance(1)
        store.tick()
        #expect(store.rows.map(\.bucket) == [.stale])
        #expect(store.rows[0].blinking)
        #expect(store.rows[0].elapsed == 300)
    }

    @Test func staleAfterIsConfigurable() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .done, since: t0)])
        store.staleAfter = 60
        clock.advance(60)
        store.tick()
        #expect(store.rows[0].bucket == .stale)
    }

    @Test func clockOffsetAppliedToElapsed() {
        // Server clock is 120 s ahead; session finished 30 s ago in server time.
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .done, since: t0.addingTimeInterval(90))], offset: 120)
        #expect(store.rows[0].elapsed == 30)
        #expect(store.rows[0].since == t0.addingTimeInterval(-30))
    }

    @Test func elapsedNeverNegative() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .running, since: t0.addingTimeInterval(50))])
        #expect(store.rows[0].elapsed == 0)
    }

    @Test func snoozeStopsBlinkUntilExpiry() {
        let clock = TestClock(t0)
        let (store, a) = connectedStore(clock, [makeSession("1", .done, since: t0)])
        let key = SessionKey(serverID: a.id, sessionID: "1")
        clock.advance(400)
        store.tick()
        store.snooze(key)
        #expect(store.rows[0].bucket == .stale)
        #expect(store.rows[0].blinking == false)
        clock.advance(599)
        store.tick()
        #expect(store.rows[0].blinking == false)
        clock.advance(1)
        store.tick()
        #expect(store.rows[0].blinking)
    }

    @Test func snoozeDroppedWhenSessionLeavesDone() {
        let clock = TestClock(t0)
        let (store, a) = connectedStore(clock, [makeSession("1", .done, since: t0)])
        let key = SessionKey(serverID: a.id, sessionID: "1")
        clock.advance(400)
        store.tick()
        store.snooze(key)
        store.apply(.upsert(serverNow: clock.now, session: makeSession("1", .running, since: clock.now)), from: a.id)
        store.apply(.upsert(serverNow: clock.now, session: makeSession("1", .done, since: t0)), from: a.id)
        #expect(store.rows[0].blinking)
    }

    @Test func snoozeIgnoredForNonDoneAndClearSnoozeWorks() {
        let clock = TestClock(t0)
        let (store, a) = connectedStore(clock, [makeSession("1", .running, since: t0), makeSession("2", .done, since: t0)])
        store.snooze(SessionKey(serverID: a.id, sessionID: "1"))
        clock.advance(400)
        store.tick()
        let k2 = SessionKey(serverID: a.id, sessionID: "2")
        store.snooze(k2)
        #expect(store.rows.first { $0.id == k2 }?.blinking == false)
        store.clearSnooze(k2)
        #expect(store.rows.first { $0.id == k2 }?.blinking == true)
    }

    @Test func pauseStopsAllBlinkingUntilResumeOrExpiry() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .done, since: t0)])
        clock.advance(400)
        store.tick()
        store.pause(for: 3600)
        #expect(store.isPaused)
        #expect(store.rows[0].blinking == false)
        store.resume()
        #expect(store.rows[0].blinking)
        store.pause(for: 3600)
        clock.advance(3600)
        store.tick()
        #expect(!store.isPaused)
        #expect(store.rows[0].blinking)
    }

    @Test func offlineServerNeverBlinksAndIsMarked() {
        let clock = TestClock(t0)
        let (store, a) = connectedStore(clock, [makeSession("1", .done, since: t0)])
        clock.advance(400)
        store.tick()
        store.setStatus(.offline, for: a.id)
        #expect(store.rows[0].offline)
        #expect(store.rows[0].blinking == false)
        #expect(store.rows[0].bucket == .stale)
    }

    @Test func endedHidden() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .ended, since: t0), makeSession("2", .idle, since: t0)])
        #expect(store.rows.map(\.session.id) == ["2"])
    }

    @Test func sortOrder() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [
            makeSession("idle", .idle, since: t0),
            makeSession("run-new", .running, since: t0.addingTimeInterval(-10)),
            makeSession("run-old", .running, since: t0.addingTimeInterval(-100)),
            makeSession("done", .done, since: t0.addingTimeInterval(-60)),
            makeSession("stale", .done, since: t0.addingTimeInterval(-600)),
            makeSession("wait", .waiting, since: t0),
        ])
        #expect(store.rows.map(\.session.id) == ["wait", "stale", "done", "run-old", "run-new", "idle"])
    }

    @Test func pillSummary() {
        let clock = TestClock(t0)
        let (store, a) = connectedStore(clock, [
            makeSession("1", .running, since: t0),
            makeSession("2", .running, since: t0),
            makeSession("3", .waiting, since: t0),
            makeSession("4", .done, since: t0.addingTimeInterval(-600)),
            makeSession("5", .done, since: t0),
            makeSession("6", .idle, since: t0),
        ])
        #expect(store.pill == PillSummary(running: 2, waiting: 1, done: 2, blinking: true, offline: false))
        store.setStatus(.offline, for: a.id)
        #expect(store.pill == PillSummary(running: 2, waiting: 1, done: 2, blinking: false, offline: true))
    }

    @Test func pillOfflineWithoutServers() {
        let store = SessionStore(clock: { Date() })
        #expect(store.pill.offline)
    }

    @Test func rowCarriesServerName() {
        let clock = TestClock(t0)
        let (store, _) = connectedStore(clock, [makeSession("1", .idle, since: t0)])
        #expect(store.rows[0].serverName == "a")
    }
}
