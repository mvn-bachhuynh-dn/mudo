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
}
