import Foundation
import Testing
@testable import MuDoCore

@Suite struct RecentSessionsTests {
    private func session(_ id: String, _ state: SessionState, minutesAgo: Int) -> Session {
        Session(id: id, agent: "claude", host: "devbox", cwd: "/p/\(id)", project: id, state: state,
                stateSince: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60), lastPrompt: "x")
    }

    private func ids(_ list: [Session]) -> [String] { list.map(\.id) }

    @Test func waitingFirstThenNewest() {
        let input = [session("a", .done, minutesAgo: 1), session("b", .waiting, minutesAgo: 30),
                     session("c", .running, minutesAgo: 2), session("d", .waiting, minutesAgo: 10)]
        #expect(ids(RecentSessions.pick(input)) == ["d", "b", "a"])
    }

    @Test func endedSessionsAreSkipped() {
        let input = [session("a", .ended, minutesAgo: 0), session("b", .idle, minutesAgo: 5)]
        #expect(ids(RecentSessions.pick(input)) == ["b"])
    }

    @Test func fewerThanThree() {
        #expect(ids(RecentSessions.pick([session("a", .done, minutesAgo: 1)])) == ["a"])
        #expect(RecentSessions.pick([]).isEmpty)
    }

    @Test func tiesBreakById() {
        let input = [session("b", .done, minutesAgo: 5), session("a", .done, minutesAgo: 5)]
        #expect(ids(RecentSessions.pick(input)) == ["a", "b"])
    }

    @Test func countIsHonored() {
        let input = (0..<6).map { session("s\($0)", .done, minutesAgo: $0) }
        #expect(ids(RecentSessions.pick(input, count: 2)) == ["s0", "s1"])
    }
}
