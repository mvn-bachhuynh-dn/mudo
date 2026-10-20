import Foundation
import Testing
@testable import MuDoCore

@Suite struct SlackLinkTests {
    let team = "T0123456789", channel = "C0123456789"

    @Test func appWhenInstalledAndTeamKnown() {
        #expect(SlackLink.target(channel: channel, team: team, hasApp: true)
            == .app(URL(string: "slack://channel?team=T0123456789&id=C0123456789")!))
    }

    @Test func webWhenNoApp() {
        #expect(SlackLink.target(channel: channel, team: " T0123456789 ", hasApp: false)
            == .web(URL(string: "https://app.slack.com/client/T0123456789/C0123456789")!, team: "T0123456789"))
    }

    @Test func noOrBadTeamGoesThroughRedirect() {
        for team in ["", "bad"] {
            for hasApp in [true, false] {
                #expect(SlackLink.target(channel: channel, team: team, hasApp: hasApp)
                    == .web(URL(string: "https://slack.com/app_redirect?channel=C0123456789")!, team: nil), "\(team)")
            }
        }
    }

    @Test func rejectsBadChannel() {
        #expect(SlackLink.target(channel: "C01&x=1", team: team, hasApp: true) == nil)
        #expect(SlackLink.target(channel: "", team: "", hasApp: false) == nil)
    }

    func tab(_ i: Int, _ url: String) -> ChromeTab { ChromeTab(windowID: 1, tabIndex: i, url: url, title: "") }

    @Test func reusesTabAlreadyOnTheChannel() {
        let tabs = [tab(1, "https://app.slack.com/client/T0123456789/C0999999999"),
                    tab(2, "https://app.slack.com/client/T0123456789/C0123456789/thread/C0123456789-1.2")]
        let hit = SlackLink.webTab(in: tabs, team: team, channel: channel)
        #expect(hit?.tab == tabs[1] && hit?.navigate == false)
    }

    @Test func navigatesAnotherTabOfTheWorkspace() {
        let tabs = [tab(1, "https://app.slack.com/client/T0999999999/C0123456789"),
                    tab(2, "https://code.example.com/?folder=/x"),
                    tab(3, "https://app.slack.com/client/T0123456789"),
                    tab(4, "https://app.slack.com/client/T0123456789/C0999999999")]
        let hit = SlackLink.webTab(in: tabs, team: team, channel: channel)
        #expect(hit?.tab == tabs[2] && hit?.navigate == true)
    }

    @Test func noTabOfTheWorkspace() {
        let tabs = [tab(1, "https://app.slack.com/client/T0999999999/C0123456789"),
                    tab(2, "http://app.slack.com/client/T0123456789/C0123456789"),
                    tab(3, "https://evil.example.com/client/T0123456789/C0123456789")]
        #expect(SlackLink.webTab(in: tabs, team: team, channel: channel) == nil)
    }

    @Test func patterns() {
        for ok in ["C0123456789", "D012345", "G01234567890123456789"] { #expect(SlackLink.isChannel(ok), "\(ok)") }
        for bad in ["X0123456789", "C01234", "C012345678901234567890", "c0123456789", "C0123456789\n", "C01;rm"] {
            #expect(!SlackLink.isChannel(bad), "\(bad)")
        }
        for ok in ["T0123456789", "E0123456"] { #expect(SlackLink.isTeam(ok), "\(ok)") }
        for bad in ["C0123456789", "T01", "", "T0123456789 "] { #expect(!SlackLink.isTeam(bad), "\(bad)") }
    }
}
