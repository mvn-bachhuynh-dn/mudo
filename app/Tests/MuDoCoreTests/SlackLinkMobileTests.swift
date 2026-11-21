import Foundation
import Testing
@testable import MuDoCore

@Suite struct SlackLinkMobileTests {
    let team = "T0ABCDEF1", other = "T0ABCDEF9", channel = "C0ABCDEF2", ts = "1700000000.000100"

    private func session(_ terminal: TerminalInfo?) -> Session {
        Session(id: "s1", agent: "kiro", host: "h", cwd: "/w", project: "p", state: .running,
                stateSince: Date(timeIntervalSince1970: 0), lastPrompt: "", terminal: terminal)
    }

    @Test func teamAndThread() {
        #expect(SlackLink.mobileURL(channel: channel, team: team, thread: ts, includeThread: true)
            == URL(string: "slack://channel?team=T0ABCDEF1&id=C0ABCDEF2&message=1700000000.000100"))
    }

    @Test func threadParameterOff() {
        #expect(SlackLink.mobileURL(channel: channel, team: team, thread: ts, includeThread: false)
            == URL(string: "slack://channel?team=T0ABCDEF1&id=C0ABCDEF2"))
    }

    @Test func publicOverloadFollowsTheSwitch() {
        #expect(SlackLink.mobileURL(channel: channel, team: team, thread: ts)
            == SlackLink.mobileURL(channel: channel, team: team, thread: ts, includeThread: SlackLink.mobileThreadParameter))
    }

    @Test func noTeamFallsBackToAppRedirect() {
        let want = URL(string: "https://slack.com/app_redirect?channel=C0ABCDEF2")
        #expect(SlackLink.mobileURL(channel: channel, team: nil, thread: ts, includeThread: true) == want)
        #expect(SlackLink.mobileURL(channel: channel, team: "bogus", thread: ts, includeThread: true) == want)
    }

    @Test func trimsTheTeam() {
        #expect(SlackLink.mobileURL(channel: channel, team: " T0ABCDEF1 ", thread: nil, includeThread: true)
            == URL(string: "slack://channel?team=T0ABCDEF1&id=C0ABCDEF2"))
    }

    @Test func invalidChannelIsNil() {
        #expect(SlackLink.mobileURL(channel: "nope", team: team, thread: ts, includeThread: true) == nil)
    }

    @Test func invalidThreadIsIgnored() {
        #expect(SlackLink.mobileURL(channel: channel, team: team, thread: "x&y=1", includeThread: true)
            == URL(string: "slack://channel?team=T0ABCDEF1&id=C0ABCDEF2"))
    }

    @Test func sessionWithoutSlackDataIsNil() {
        #expect(SlackLink.mobileURL(for: session(nil), fallbackTeam: team) == nil)
        #expect(SlackLink.mobileURL(for: session(TerminalInfo(program: "x")), fallbackTeam: team) == nil)
        #expect(SlackLink.mobileURL(for: session(TerminalInfo(slackChannel: "bad")), fallbackTeam: team) == nil)
    }

    @Test func sessionTeamBeatsTheFallback() {
        let s = session(TerminalInfo(slackChannel: channel, slackTeam: team, slackThread: ts))
        #expect(SlackLink.mobileURL(for: s, fallbackTeam: other)
            == SlackLink.mobileURL(channel: channel, team: team, thread: ts))
    }

    @Test func fallbackTeamWhenSessionHasNone() {
        let s = session(TerminalInfo(slackChannel: channel, slackThread: ts))
        #expect(SlackLink.mobileURL(for: s, fallbackTeam: other)
            == SlackLink.mobileURL(channel: channel, team: other, thread: ts))
        #expect(SlackLink.mobileURL(for: s, fallbackTeam: "")
            == URL(string: "https://slack.com/app_redirect?channel=C0ABCDEF2"))
    }
}
