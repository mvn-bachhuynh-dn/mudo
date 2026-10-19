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

    @Test func ttyMatchesExactly() {
        #expect(AutoAck.isInView(.tty("/dev/ttys004"), front: .terminal(tty: "/dev/ttys004", tmuxPane: nil)))
        #expect(!AutoAck.isInView(.tty("/dev/ttys004"), front: .terminal(tty: "/dev/ttys005", tmuxPane: nil)))
    }

    @Test func tmuxNeedsTheActivePane() {
        let place = SessionPlace.tmux(pane: "%3", socket: nil)
        #expect(AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%3")))
        #expect(!AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%4")))
        #expect(!AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: nil)))
    }

    @Test func editorTitleContainsACandidate() {
        let place = SessionPlace.editor(titles: ["api", "proj"])
        #expect(AutoAck.isInView(place, front: .editor(title: "main.go — proj")))
        #expect(!AutoAck.isInView(place, front: .editor(title: "main.go — other")))
        #expect(!AutoAck.isInView(.editor(titles: [""]), front: .editor(title: "anything")))
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

    @Test func candidatesAreDoneOnlineAndNotYetAcked() {
        let server = UUID()
        func row(_ id: String, _ state: SessionState, offline: Bool = false) -> SessionRow {
            let s = Session(id: id, agent: "claude", host: "devbox", cwd: "/w/\(id)", project: id, state: state,
                            stateSince: Date(timeIntervalSince1970: 0), lastPrompt: "", terminal: nil)
            return SessionRow(id: SessionKey(serverID: server, sessionID: id), session: s, serverName: "devbox",
                              bucket: .done, since: Date(timeIntervalSince1970: 0), elapsed: 0,
                              blinking: false, offline: offline)
        }
        let rows = [row("a", .done), row("b", .running), row("c", .done, offline: true), row("d", .done)]
        let acked: Set = [SessionKey(serverID: server, sessionID: "d")]
        #expect(AutoAck.candidates(rows, alreadyAcked: acked).map(\.session.id) == ["a"])
    }
}
