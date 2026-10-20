import Foundation
import Testing
@testable import MuDoCore

@Suite struct TerminalInfoTests {
    static let full = TerminalInfo(
        program: "iTerm.app", codeServer: true, tty: "/dev/ttys004",
        itermSession: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
        tmuxSocket: "/private/tmp/tmux-501/default", tmuxPane: "%3", tmuxBin: "/opt/homebrew/bin/tmux",
        sshClientIp: "fd7a:115c:a1e0::20", sshClientPort: 52144,
        sshServerIp: "100.64.0.10", sshServerPort: 22)

    @Test func keepsValidFields() {
        #expect(Self.full.validated() == Self.full)
    }

    @Test func dropsBadTTY() {
        for bad in ["/dev/ttys004; rm", "../x", "/dev/tty", "/dev/ttys"] {
            var t = Self.full
            t.tty = bad
            #expect(t.validated().tty == nil, "\(bad)")
        }
    }

    @Test func dropsBadPane() {
        var t = Self.full
        t.tmuxPane = "3"
        #expect(t.validated().tmuxPane == nil)
        t.tmuxPane = "%3;x"
        #expect(t.validated().tmuxPane == nil)
    }

    @Test func dropsBadITermSession() {
        var t = Self.full
        t.itermSession = "abc"
        #expect(t.validated().itermSession == nil)
    }

    @Test func dropsBadPaths() {
        for bad in ["-x", "/a/../b", "relative/tmux", "", "/tmp/a\nb", "/tmp/a\u{7}"] {
            var t = Self.full
            t.tmuxSocket = bad
            t.tmuxBin = bad
            #expect(t.validated().tmuxSocket == nil, "\(bad)")
            #expect(t.validated().tmuxBin == nil, "\(bad)")
        }
    }

    @Test func dropsBadPorts() {
        for bad in [0, -1, 70000] {
            var t = Self.full
            t.sshClientPort = bad
            t.sshServerPort = bad
            #expect(t.validated().sshClientPort == nil, "\(bad)")
            #expect(t.validated().sshServerPort == nil, "\(bad)")
        }
    }

    @Test func checksIPs() {
        var t = Self.full
        t.sshClientIp = "fd7a:115c:a1e0::10"
        t.sshServerIp = "192.168.1.10"
        #expect(t.validated().sshClientIp == "fd7a:115c:a1e0::10")
        #expect(t.validated().sshServerIp == "192.168.1.10")
        t.sshClientIp = "devbox"
        t.sshServerIp = "100.64.0.10; rm"
        #expect(t.validated().sshClientIp == nil)
        #expect(t.validated().sshServerIp == nil)
    }

    @Test func decodesSlackChannel() throws {
        let t = try WireDate.decoder().decode(TerminalInfo.self, from: Data(#"{"slack_channel":"C0123456789","slack_team":"T0123456789"}"#.utf8))
        #expect(t.slackChannel == "C0123456789")
        #expect(t.validated().slackChannel == "C0123456789")
        #expect(t.validated().slackTeam == "T0123456789")
    }

    @Test func dropsBadSlackChannel() {
        var t = Self.full
        t.slackChannel = "C01;rm"
        #expect(t.validated().slackChannel == nil)
    }
}
