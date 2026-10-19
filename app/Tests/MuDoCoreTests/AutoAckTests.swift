import Foundation
import Testing
@testable import MuDoCore

@Suite struct AutoAckTests {
    let cs = URL(string: "https://code.example.com")!

    @Test func chromeTabOfTheFolderIsInView() {
        let place = SessionPlace.chrome(codeServer: cs, cwd: "/home/user/proj", project: "proj")
        #expect(AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/?folder=/home/user/proj", title: "x")))
        #expect(!AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/?folder=/home/user/other", title: "x")))
        #expect(!AutoAck.isInView(place, front: .chromeTab(url: "https://example.org/?folder=/home/user/proj", title: "x")))
    }

    @Test func chromeParentFolderOrTitleIsNotInView() {
        let place = SessionPlace.chrome(codeServer: cs, cwd: "/home/user/proj", project: "proj")
        #expect(AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/?folder=/home/user/proj/", title: "x")))
        #expect(!AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/?folder=/home/user", title: "x")))
        #expect(!AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/", title: "main.go - proj - code-server")))
    }

    @Test func ttyMatchesExactly() {
        #expect(AutoAck.isInView(.tty("/dev/ttys004"), front: .terminal(tty: "/dev/ttys004", tmuxPane: nil, tmuxSocket: nil)))
        #expect(!AutoAck.isInView(.tty("/dev/ttys004"), front: .terminal(tty: "/dev/ttys005", tmuxPane: nil, tmuxSocket: nil)))
    }

    @Test func tmuxNeedsTheActivePane() {
        let place = SessionPlace.tmux(pane: "%3", socket: nil)
        #expect(AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%3", tmuxSocket: nil)))
        #expect(!AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%4", tmuxSocket: nil)))
        #expect(!AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: nil, tmuxSocket: nil)))
    }

    @Test func tmuxPaneOnAnotherServerIsNotInView() {
        let other = SessionPlace.tmux(pane: "%3", socket: "/tmp/tmux-501/x")
        #expect(!AutoAck.isInView(other, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%3", tmuxSocket: nil)))
        #expect(AutoAck.isInView(other, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%3", tmuxSocket: "/tmp/tmux-501/x")))
        #expect(!AutoAck.isInView(.tmux(pane: "%3", socket: nil),
                                  front: .terminal(tty: "/dev/ttys001", tmuxPane: "%3", tmuxSocket: "/tmp/tmux-501/x")))
    }

    @Test func editorTitleContainsACandidate() {
        let place = SessionPlace.editor(titles: ["api", "proj"])
        #expect(AutoAck.isInView(place, front: .editor(title: "main.go — proj")))
        #expect(!AutoAck.isInView(place, front: .editor(title: "main.go — other")))
        #expect(!AutoAck.isInView(.editor(titles: [""]), front: .editor(title: "anything")))
    }

    @Test func editorMatchesWholeTitleSegmentsOnly() {
        #expect(!AutoAck.isInView(.editor(titles: ["api"]), front: .editor(title: "capital.ts — budget")))
        #expect(!AutoAck.isInView(.editor(titles: ["app"]), front: .editor(title: "main.go — myapp-server — Visual Studio Code")))
        #expect(AutoAck.isInView(.editor(titles: ["app"]), front: .editor(title: "● main.go - app - Cursor")))
        #expect(AutoAck.isInView(.editor(titles: ["proj"]), front: .editor(title: "proj")))
    }

    @Test func mismatchedKindsAreNotInView() {
        #expect(!AutoAck.isInView(.tty("/dev/ttys004"), front: .editor(title: "/dev/ttys004")))
        #expect(!AutoAck.isInView(.editor(titles: ["proj"]), front: .chromeTab(url: "x", title: "proj")))
    }

    @Test func chromeFrontNeedsURLAndTitle() {
        #expect(AutoAck.chromeFront(["https://code.example.com/", "t"]) == .chromeTab(url: "https://code.example.com/", title: "t"))
        #expect(AutoAck.chromeFront([]) == nil)
        #expect(AutoAck.chromeFront(["https://code.example.com/"]) == nil)
    }

    @Test func placeFromTheOwningApp() {
        let titles = ["api", "proj"]
        #expect(AutoAck.place(app: .iTerm2, outerTTY: "/dev/ttys004", editorTitles: titles) == .tty("/dev/ttys004"))
        #expect(AutoAck.place(app: .terminal, outerTTY: "/dev/ttys005", editorTitles: titles) == .tty("/dev/ttys005"))
        #expect(AutoAck.place(app: .iTerm2, outerTTY: nil, editorTitles: titles) == nil)
        #expect(AutoAck.place(app: .vscodeLike(bundlePath: "/Applications/Cursor.app"), outerTTY: nil, editorTitles: titles)
            == .editor(titles: titles))
        #expect(AutoAck.place(app: .vscodeLike(bundlePath: "/Applications/Cursor.app"), outerTTY: nil, editorTitles: []) == nil)
        #expect(AutoAck.place(app: .ghostty, outerTTY: "/dev/ttys004", editorTitles: titles) == nil)
        #expect(AutoAck.place(app: .other(bundlePath: "/Applications/X.app"), outerTTY: "/dev/ttys004", editorTitles: titles) == nil)
    }

    @Test func editorTitlesUseOnlyTheFirstTwoCandidates() {
        #expect(AutoAck.editorTitles(cwd: "/Users/user/work/proj/api", project: "proj", home: "/Users/user", remote: false)
            == ["api", "proj"])
        #expect(AutoAck.editorTitles(cwd: "/home/user/proj/api", project: "proj", home: "/Users/user", remote: true) == ["proj"])
        #expect(AutoAck.editorTitles(cwd: "/home/user/proj", project: "", home: "/Users/user", remote: true) == [])
    }

    @Test func presence() {
        #expect(AutoAck.userPresent(idleSeconds: 5, screenLocked: false))
        #expect(!AutoAck.userPresent(idleSeconds: 60, screenLocked: false))
        #expect(!AutoAck.userPresent(idleSeconds: 1, screenLocked: true))
    }

    static let server = UUID()

    static func row(_ id: String, _ state: SessionState, offline: Bool = false) -> SessionRow {
        let s = Session(id: id, agent: "claude", host: "devbox", cwd: "/w/\(id)", project: id, state: state,
                        stateSince: Date(timeIntervalSince1970: 0), lastPrompt: "", terminal: nil)
        return SessionRow(id: key(id), session: s, serverName: "devbox",
                          bucket: .done, since: Date(timeIntervalSince1970: 0), elapsed: 0,
                          blinking: false, offline: offline)
    }

    static func key(_ id: String) -> SessionKey { SessionKey(serverID: server, sessionID: id) }

    @Test func candidatesAreDoneOnlineAndNotYetAcked() {
        let rows = [Self.row("a", .done), Self.row("b", .running), Self.row("c", .done, offline: true), Self.row("d", .done)]
        let acked: Set = [Self.key("d")]
        #expect(AutoAck.candidates(rows, alreadyAcked: acked).map(\.session.id) == ["a"])
    }

    @Test func autoAckedKeepsOnlyDoneSessions() {
        let rows = [Self.row("a", .done), Self.row("b", .idle), Self.row("c", .done, offline: true)]
        let acked: Set = [Self.key("a"), Self.key("b"), Self.key("c"), Self.key("gone")]
        #expect(AutoAck.keepDone(acked, rows: rows) == [Self.key("a"), Self.key("c")])
    }

    @Test func placeCacheResolvesOnceAndRetriesNilAfter30s() {
        var cache = PlaceCache()
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = Self.key("a"), b = Self.key("b")
        #expect(cache.needsResolve(a, now: t0))
        cache.set(.tty("/dev/ttys004"), for: a, at: t0)
        cache.set(nil, for: b, at: t0)
        #expect(cache.place(a) == .tty("/dev/ttys004"))
        #expect(cache.place(b) == nil)
        #expect(!cache.needsResolve(a, now: t0.addingTimeInterval(3600)))
        #expect(!cache.needsResolve(b, now: t0.addingTimeInterval(29)))
        #expect(cache.needsResolve(b, now: t0.addingTimeInterval(30)))
    }

    @Test func placeCacheDropsSessionsNoLongerDone() {
        var cache = PlaceCache()
        let t0 = Date(timeIntervalSince1970: 1000)
        for id in ["a", "b", "c"] { cache.set(.tty("/dev/\(id)"), for: Self.key(id), at: t0) }
        cache.prune(rows: [Self.row("a", .done), Self.row("b", .running)])
        #expect(cache.place(Self.key("a")) == .tty("/dev/a"))
        #expect(cache.needsResolve(Self.key("b"), now: t0))
        #expect(cache.needsResolve(Self.key("c"), now: t0))
    }

    @Test func placeCacheTmuxSocketsAreDistinctInOrder() {
        var cache = PlaceCache()
        let t0 = Date(timeIntervalSince1970: 1000)
        let keys = ["a", "b", "c", "d", "e"].map(Self.key)
        cache.set(.tmux(pane: "%1", socket: "/tmp/tmux-501/x"), for: keys[0], at: t0)
        cache.set(.tmux(pane: "%2", socket: nil), for: keys[1], at: t0)
        cache.set(.tmux(pane: "%3", socket: "/tmp/tmux-501/x"), for: keys[2], at: t0)
        cache.set(.tty("/dev/ttys004"), for: keys[3], at: t0)
        cache.set(.tmux(pane: "%4", socket: "/tmp/tmux-501/y"), for: Self.key("other"), at: t0)
        #expect(cache.tmuxSockets(for: keys) == ["/tmp/tmux-501/x", nil])
        #expect(cache.tmuxSockets(for: [keys[3], keys[4]]).isEmpty)
    }
}
