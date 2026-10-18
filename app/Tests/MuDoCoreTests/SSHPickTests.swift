import Foundation
import Testing
@testable import MuDoCore

@Suite struct SSHPickTests {
    let terminal = TerminalInfo(sshClientIp: "100.64.0.20", sshClientPort: 52000,
                                sshServerIp: "100.64.0.10", sshServerPort: 22)
    let noMux: (Int) -> Bool = { _ in false }

    @Test func exactMatch() {
        let conns = [
            SSHConn(pid: 10, localPort: 51000, remoteHost: "100.64.0.10", remotePort: 22),
            SSHConn(pid: 11, localPort: 52000, remoteHost: "100.64.0.10", remotePort: 22),
        ]
        #expect(SSHPick.choose(conns: conns, terminal: terminal, isMux: noMux)?.pid == 11)
    }

    @Test func natChangedPortSingleHostMatch() {
        let conns = [
            SSHConn(pid: 10, localPort: 60001, remoteHost: "192.168.1.10", remotePort: 22),
            SSHConn(pid: 11, localPort: 60002, remoteHost: "100.64.0.10", remotePort: 22),
            SSHConn(pid: 12, localPort: 60003, remoteHost: "100.64.0.10", remotePort: 2222),
        ]
        #expect(SSHPick.choose(conns: conns, terminal: terminal, isMux: noMux)?.pid == 11)
    }

    @Test func twoHostMatchesIsAmbiguous() {
        let conns = [
            SSHConn(pid: 10, localPort: 60001, remoteHost: "100.64.0.10", remotePort: 22),
            SSHConn(pid: 11, localPort: 60002, remoteHost: "100.64.0.10", remotePort: 22),
        ]
        #expect(SSHPick.choose(conns: conns, terminal: terminal, isMux: noMux) == nil)
    }

    @Test func muxRemovedFirst() {
        let conns = [
            SSHConn(pid: 10, localPort: 60001, remoteHost: "100.64.0.10", remotePort: 22),
            SSHConn(pid: 11, localPort: 52000, remoteHost: "100.64.0.10", remotePort: 22),
        ]
        // The exact match is a ControlMaster: dropped, leaving one host match.
        #expect(SSHPick.choose(conns: conns, terminal: terminal, isMux: { $0 == 11 })?.pid == 10)
        #expect(SSHPick.choose(conns: conns, terminal: terminal, isMux: { _ in true }) == nil)
    }

    @Test func ipv6ComparedNumerically() {
        let t = TerminalInfo(sshClientPort: 52000, sshServerIp: "fd7a:115c:a1e0::10", sshServerPort: 22)
        let conns = [SSHConn(pid: 10, localPort: 60001, remoteHost: "fd7a:115c:a1e0:0:0:0:0:10", remotePort: 22)]
        #expect(SSHPick.choose(conns: conns, terminal: t, isMux: noMux)?.pid == 10)
    }

    @Test func noServerAddress() {
        let t = TerminalInfo(sshClientPort: 52000)
        let conns = [SSHConn(pid: 10, localPort: 60001, remoteHost: "100.64.0.10", remotePort: 22)]
        #expect(SSHPick.choose(conns: conns, terminal: t, isMux: noMux) == nil)
        #expect(SSHPick.choose(conns: [], terminal: terminal, isMux: noMux) == nil)
    }

    static let ps = """
        1     0 ??       /sbin/launchd
      500     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2
      510   500 ttys003  /usr/bin/login
      511   510 ttys003  -zsh
      512   511 ttys003  ssh
      520     1 ??       ssh
      530     1 ??       ssh
      600     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
      610   600 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
      620   610 ??       /usr/bin/ssh

    """
    let table = ProcessTable(psOutput: Self.ps)

    @Test func discardKeepsTerminalSSH() {
        #expect(!SSHPick.discard(pid: 512, table: table, commandLine: "ssh devbox"))
    }

    @Test func discardDropsControlMaster() {
        #expect(SSHPick.discard(pid: 530, table: table, commandLine: "ssh: /Users/dev/.ssh/cm-devbox [mux]"))
        // Even on a tty, a ControlMaster is never the session's client.
        #expect(SSHPick.discard(pid: 512, table: table, commandLine: "ssh: /Users/dev/.ssh/cm-devbox [mux]"))
    }

    @Test func discardDropsTTYlessTunnelUnderLaunchd() {
        #expect(SSHPick.discard(pid: 520, table: table, commandLine: "ssh -N -L 8080:localhost:8080 devbox"))
        #expect(SSHPick.discard(pid: 520, table: table, commandLine: nil))
    }

    @Test func discardKeepsTTYlessSSHUnderEditor() {
        #expect(!SSHPick.discard(pid: 620, table: table,
                                 commandLine: "/usr/bin/ssh -T -D 61234 -o ConnectTimeout=15 devbox bash"))
    }

    @Test func discardDropsUnknownPID() {
        #expect(SSHPick.discard(pid: 4242, table: table, commandLine: nil))
    }
}
