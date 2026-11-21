import Foundation
import Testing
@testable import MuDoCore

@MainActor
@Suite struct RecentSessionsTests {
    private let now = utc(2026, 11, 21, 12, 0, 0)

    private func session(_ id: String, _ state: SessionState, secondsAgo: Double) -> Session {
        makeSession(id, state, since: now.addingTimeInterval(-secondsAgo), project: id)
    }

    private func pick(_ list: [Session], count: Int = 3) -> [String] {
        RecentSessions.pick(list, serverNow: now, count: count).map(\.id)
    }

    @Test func waitingFirstLongestInStateFirst() {
        let input = [session("a", .done, secondsAgo: 60), session("b", .waiting, secondsAgo: 1800),
                     session("c", .running, secondsAgo: 120), session("d", .waiting, secondsAgo: 600)]
        #expect(pick(input) == ["b", "d", "a"])
    }

    @Test func doneComesAfterWaiting() {
        let input = [session("a", .done, secondsAgo: 10), session("b", .waiting, secondsAgo: 5)]
        #expect(pick(input) == ["b", "a"])
    }

    @Test func staleDoneBeforeFreshDone() {
        let input = [session("fresh", .done, secondsAgo: 299), session("stale", .done, secondsAgo: 300),
                     session("run", .running, secondsAgo: 1000)]
        #expect(pick(input) == ["stale", "fresh", "run"])
    }

    @Test func runningLongestInStateFirst() {
        let input = [session("a", .running, secondsAgo: 10), session("b", .running, secondsAgo: 500),
                     session("c", .running, secondsAgo: 100)]
        #expect(pick(input) == ["b", "c", "a"])
    }

    @Test func idleNewestFirstAfterLiveOnes() {
        let input = [session("old", .idle, secondsAgo: 3600), session("new", .idle, secondsAgo: 60),
                     session("run", .running, secondsAgo: 5)]
        #expect(pick(input) == ["run", "new", "old"])
    }

    @Test func endedCountsAsIdleUntilSevenDays() {
        let week = 7.0 * 24 * 3600
        let input = [session("gone", .ended, secondsAgo: week), session("kept", .ended, secondsAgo: week - 1),
                     session("idle", .idle, secondsAgo: week)]
        #expect(pick(input) == ["kept"])
        #expect(RecentSessions.pick(input, serverNow: now, hideIdleAfter: week + 10).map(\.id) == ["kept", "gone", "idle"])
    }

    @Test func fewerThanThree() {
        #expect(pick([session("a", .done, secondsAgo: 1)]) == ["a"])
        #expect(pick([]).isEmpty)
    }

    @Test func tiesBreakById() {
        let input = [session("b", .done, secondsAgo: 5), session("a", .done, secondsAgo: 5)]
        #expect(pick(input) == ["a", "b"])
    }

    @Test func countIsHonored() {
        let input = (0..<6).map { session("s\($0)", .running, secondsAgo: Double(100 - $0)) }
        #expect(pick(input, count: 2) == ["s0", "s1"])
        #expect(pick(input, count: 0).isEmpty)
    }

    @Test func futureStateSinceCountsAsZeroElapsed() {
        #expect(pick([session("a", .done, secondsAgo: -50)]) == ["a"])
    }

    @Test func matchesTheSessionsTabOrder() {
        let all = [session("w1", .waiting, secondsAgo: 30), session("w2", .waiting, secondsAgo: 900),
                   session("d1", .done, secondsAgo: 20), session("d2", .done, secondsAgo: 400),
                   session("r1", .running, secondsAgo: 5), session("r2", .running, secondsAgo: 700),
                   session("i1", .idle, secondsAgo: 5000), session("i2", .idle, secondsAgo: 50),
                   session("e1", .ended, secondsAgo: 9000), session("e2", .ended, secondsAgo: 8 * 24 * 3600)]
        let clock = TestClock(now)
        let store = SessionStore(clock: { clock.now })
        let server = makeServer("a")
        store.setServers([server])
        store.setStatus(.connected, for: server.id)
        store.hideIdleAfter = TimeInterval(IdleFold.defaultHours * 3600)
        store.apply(.snapshot(serverNow: now, host: "a", sessions: all), from: server.id)
        let rows = store.rows.map(\.session.id)
        #expect(rows == ["w2", "w1", "d2", "d1", "r2", "r1", "i2", "i1", "e1"])
        for count in 0...rows.count + 1 {
            #expect(pick(all, count: count) == Array(rows.prefix(count)))
        }
    }
}
