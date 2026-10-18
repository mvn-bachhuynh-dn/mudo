import Foundation
import Testing
@testable import MuDoCore

@Suite struct ProcessTableTests {
    static let ps = """
        1     0 ??       /sbin/launchd
      500     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2
      610     1 ??       /Users/dev/Library/Application Support/iTerm2/iTermServer-3.5.4
    61020   610 ttys000  /usr/bin/login
    61021 61020 ttys000  zsh (kiro-cli-term)
    61032 61021 ttys001  /bin/zsh
    61100 61032 ttys001  claude
      700     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
      710   700 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
      720   710 ttys005  /bin/zsh
      800     1 ??       tmux
      810   800 ttys007  -zsh
      820   810 ttys007  ssh

    """
    let table = ProcessTable(psOutput: Self.ps)

    @Test func parsesRows() {
        #expect(table.process(1) == ProcInfo(pid: 1, ppid: 0, tty: nil, comm: "/sbin/launchd"))
        #expect(table.process(61021) == ProcInfo(pid: 61021, ppid: 61020, tty: "/dev/ttys000", comm: "zsh (kiro-cli-term)"))
        #expect(table.process(610)?.comm == "/Users/dev/Library/Application Support/iTerm2/iTermServer-3.5.4")
        #expect(table.process(710)?.comm == "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
        #expect(table.process(4242) == nil)
    }

    @Test func skipsGarbage() {
        let t = ProcessTable(psOutput: "junk\n  12 x ?? a\n  13 1 ?? b\n")
        #expect(t.process(12) == nil)
        #expect(t.process(13)?.comm == "b")
    }

    @Test func iTermThroughKiroChain() {
        #expect(table.owner(of: 61100) == .app(.iTerm2))
        #expect(table.outerTTY(of: 61100) == "/dev/ttys000")
    }

    @Test func vscodeHelper() {
        #expect(table.owner(of: 720) == .app(.vscodeLike(bundlePath: "/Applications/Visual Studio Code.app")))
        #expect(table.outerTTY(of: 720) == "/dev/ttys005")
    }

    @Test func tmux() {
        #expect(table.owner(of: 820) == .tmux(pid: 800))
    }

    @Test func launchdAndMissing() {
        #expect(table.owner(of: 1) == nil)
        #expect(table.owner(of: 4242) == nil)
        #expect(table.outerTTY(of: 700) == nil)
        let orphan = ProcessTable(psOutput: "  5 99 ttys001 /bin/zsh\n")
        #expect(orphan.owner(of: 5) == nil)
    }

    @Test func parentLoopTerminates() {
        let loop = ProcessTable(psOutput: "  5 6 ttys001 a\n  6 5 ttys001 b\n")
        #expect(loop.owner(of: 5) == nil)
        #expect(loop.outerTTY(of: 5) == "/dev/ttys001")
    }

    @Test func processesOnTTY() {
        #expect(table.processes(onTTY: "/dev/ttys007").map(\.pid) == [810, 820])
        #expect(table.processes(onTTY: "/dev/ttys099").isEmpty)
    }

    @Test func classifiesBundles() {
        let ps = """
          1 0 ?? /sbin/launchd
          2 1 ttys001 /Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
          3 1 ttys002 /Applications/Ghostty.app/Contents/MacOS/ghostty
          4 1 ttys003 /Applications/Cursor.app/Contents/MacOS/Cursor
          5 1 ttys004 /Applications/Kiro.app/Contents/MacOS/Electron
          6 1 ttys005 /Applications/WezTerm.app/Contents/MacOS/wezterm-gui
          7 1 ttys006 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        """
        let t = ProcessTable(psOutput: ps)
        #expect(t.owner(of: 2) == .app(.terminal))
        #expect(t.owner(of: 3) == .app(.ghostty))
        #expect(t.owner(of: 4) == .app(.vscodeLike(bundlePath: "/Applications/Cursor.app")))
        #expect(t.owner(of: 5) == .app(.vscodeLike(bundlePath: "/Applications/Kiro.app")))
        #expect(t.owner(of: 6) == .app(.other(bundlePath: "/Applications/WezTerm.app")))
        #expect(t.owner(of: 7) == .app(.terminal))
    }

    @Test func outermostBundle() {
        #expect(ProcessTable.outermostBundle("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
            == "/Applications/Visual Studio Code.app")
        #expect(ProcessTable.outermostBundle("/Applications/iTerm.app") == "/Applications/iTerm.app")
        #expect(ProcessTable.outermostBundle("/bin/zsh") == nil)
        #expect(ProcessTable.outermostBundle("claude") == nil)
    }
}

@Suite struct LsofSSHTests {
    @Test func parsesOnlySSH() {
        let out = """
        p820
        cssh
        f3
        n[fd7a:115c:a1e0::20]:52144->[fd7a:115c:a1e0::10]:22
        p900
        csshd-session
        f4
        n192.168.1.10:22->192.168.1.20:40000
        p901
        cssh
        f3
        n192.168.1.20:50000->192.168.1.10:22

        """
        #expect(LsofSSH.parse(out) == [
            SSHConn(pid: 820, localPort: 52144, remoteHost: "fd7a:115c:a1e0::10", remotePort: 22),
            SSHConn(pid: 901, localPort: 50000, remoteHost: "192.168.1.10", remotePort: 22),
        ])
    }

    @Test func ignoresMalformed() {
        let out = "p1\ncssh\nnnoarrow\nn1.2.3.4:x->5.6.7.8:22\npbad\ncssh\nn1.2.3.4:1->5.6.7.8:22\n"
        #expect(LsofSSH.parse(out).isEmpty)
        #expect(LsofSSH.parse("").isEmpty)
    }
}
