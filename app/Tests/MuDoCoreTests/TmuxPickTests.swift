import Foundation
import Testing
@testable import MuDoCore

@Suite struct TmuxPickTests {
    @Test func mostRecentClientOnSession() {
        let out = """
        1760000100 work /dev/ttys003
        1760000300 other /dev/ttys004
        1760000200 work /dev/ttys005

        """
        #expect(TmuxPick.client(listClients: out, session: "work") == "/dev/ttys005")
    }

    @Test func clientOnAnotherSessionIgnored() {
        #expect(TmuxPick.client(listClients: "1760000300 other /dev/ttys004\n", session: "work") == nil)
    }

    @Test func noClient() {
        #expect(TmuxPick.client(listClients: "", session: "work") == nil)
        #expect(TmuxPick.client(listClients: "junk\nx work /dev/ttys001\n", session: "work") == nil)
    }

    @Test func sessionNameWithSpaces() {
        #expect(TmuxPick.client(listClients: "5 my work /dev/ttys002\n", session: "my work") == "/dev/ttys002")
    }

    @Test func paneByTTY() {
        let out = """
        /dev/ttys007 %3 /private/tmp/tmux-501/default
        /dev/ttys008 %4 /Users/dev/tmux sockets/alt

        """
        #expect(TmuxPick.pane(listPanes: out, tty: "/dev/ttys008")! == ("%4", "/Users/dev/tmux sockets/alt"))
        #expect(TmuxPick.pane(listPanes: out, tty: "/dev/ttys007")! == ("%3", "/private/tmp/tmux-501/default"))
        #expect(TmuxPick.pane(listPanes: out, tty: "/dev/ttys009") == nil)
        #expect(TmuxPick.pane(listPanes: "/dev/ttys009 %1\n", tty: "/dev/ttys009") == nil)
    }

    @Test func resolveBinaryPrefersRecorded() {
        let all: (String) -> Bool = { _ in true }
        #expect(TmuxPick.resolveBinary(recorded: "/nix/bin/tmux", exists: all, home: "/Users/dev") == "/nix/bin/tmux")
    }

    @Test func resolveBinaryOrder() {
        func pick(_ present: Set<String>, recorded: String? = nil) -> String? {
            TmuxPick.resolveBinary(recorded: recorded, exists: { present.contains($0) }, home: "/Users/dev")
        }
        let all: Set = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/Users/dev/.local/bin/tmux", "/usr/bin/tmux"]
        #expect(pick(all, recorded: "/gone/tmux") == "/opt/homebrew/bin/tmux")
        #expect(pick(all.subtracting(["/opt/homebrew/bin/tmux"])) == "/usr/local/bin/tmux")
        #expect(pick(["/Users/dev/.local/bin/tmux", "/usr/bin/tmux"]) == "/Users/dev/.local/bin/tmux")
        #expect(pick(["/usr/bin/tmux"]) == "/usr/bin/tmux")
        #expect(pick([]) == nil)
    }
}
