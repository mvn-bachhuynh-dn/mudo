import Foundation
import Testing
@testable import MuDoCore

@Suite struct FocusPlanTests {
    let cs = URL(string: "https://code.example.com")!

    func server(_ url: String, codeServer: URL? = nil) -> ServerConfig {
        ServerConfig(id: UUID(), name: "s", daemonURL: URL(string: url)!, codeServerURL: codeServer)
    }

    func session(_ terminal: TerminalInfo?) -> Session {
        Session(id: "a", agent: "claude", host: "devbox", cwd: "/x/proj", project: "proj",
                state: .waiting, stateSince: utc(2026, 10, 17, 0, 0, 0), lastPrompt: "", terminal: terminal)
    }

    @Test func localServerWinsOverCodeServer() {
        let t = TerminalInfo(program: "vscode", codeServer: true, tty: "/dev/ttys004")
        let plan = FocusPlan.plan(server: server("http://127.0.0.1:7879", codeServer: cs), session: session(t))
        #expect(plan == .local(t, cwd: "/x/proj", project: "proj"))
    }

    @Test func localPassesValidatedInfo() {
        let t = TerminalInfo(tty: "/dev/ttys004; rm", tmuxPane: "%1")
        let plan = FocusPlan.plan(server: server("http://localhost:7879"), session: session(t))
        #expect(plan == .local(TerminalInfo(tmuxPane: "%1"), cwd: "/x/proj", project: "proj"))
        #expect(FocusPlan.plan(server: server("http://localhost:7879"), session: session(nil))
            == .local(nil, cwd: "/x/proj", project: "proj"))
    }

    @Test func codeServerTerminalGoesToChrome() {
        let t = TerminalInfo(program: "vscode", codeServer: true, sshClientIp: "100.64.0.20", sshClientPort: 50000)
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879", codeServer: cs), session: session(t))
            == .chrome(codeServer: cs, cwd: "/x/proj", project: "proj"))
    }

    @Test func remoteSSHGoesToSSH() {
        let t = TerminalInfo(program: "vscode", sshClientIp: "100.64.0.20", sshClientPort: 50000,
                             sshServerIp: "100.64.0.10", sshServerPort: 22)
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879", codeServer: cs), session: session(t))
            == .ssh(t, cwd: "/x/proj", project: "proj"))
    }

    @Test func codeServerWithoutCodeServerURLFallsToSSH() {
        let t = TerminalInfo(codeServer: true, sshClientIp: "100.64.0.20", sshClientPort: 50000)
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879"), session: session(t))
            == .ssh(t, cwd: "/x/proj", project: "proj"))
    }

    @Test func oldHookFallsBackToChrome() {
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879", codeServer: cs), session: session(nil))
            == .chrome(codeServer: cs, cwd: "/x/proj", project: "proj"))
    }

    @Test func nothingKnown() {
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879"), session: session(nil)) == .none)
    }

    @Test func invalidSSHPortFallsThrough() {
        let t = TerminalInfo(sshClientIp: "100.64.0.20", sshClientPort: 0)
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879", codeServer: cs), session: session(t))
            == .chrome(codeServer: cs, cwd: "/x/proj", project: "proj"))
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879"), session: session(t)) == .none)
    }

    @Test func slackChannelWinsEverywhere() {
        let t = TerminalInfo(codeServer: true, slackChannel: "C0123456789")
        #expect(FocusPlan.plan(server: server("http://127.0.0.1:7879", codeServer: cs), session: session(t))
            == .slack(channel: "C0123456789", team: nil))
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879", codeServer: cs), session: session(t))
            == .slack(channel: "C0123456789", team: nil))
    }

    @Test func slackCarriesTheSessionsValidTeam() {
        let t = TerminalInfo(slackChannel: "C0123456789", slackTeam: "T0123456789")
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879"), session: session(t))
            == .slack(channel: "C0123456789", team: "T0123456789"))
        let bad = TerminalInfo(slackChannel: "C0123456789", slackTeam: "T01&x=1")
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879"), session: session(bad))
            == .slack(channel: "C0123456789", team: nil))
    }

    @Test func invalidSlackChannelFallsBack() {
        let t = TerminalInfo(codeServer: true, slackChannel: "nope")
        let valid = TerminalInfo(codeServer: true)
        #expect(FocusPlan.plan(server: server("http://127.0.0.1:7879", codeServer: cs), session: session(t))
            == .local(valid, cwd: "/x/proj", project: "proj"))
        #expect(FocusPlan.plan(server: server("http://100.64.0.10:7879", codeServer: cs), session: session(t))
            == .chrome(codeServer: cs, cwd: "/x/proj", project: "proj"))
    }
}
