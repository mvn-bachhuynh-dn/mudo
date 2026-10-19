import Foundation
import Testing
@testable import MuDoCore

@Suite struct SlackLinkTests {
    @Test func opensAppWithTeam() {
        #expect(SlackLink.url(channel: "C0123456789", team: "T0123456789")?.absoluteString
            == "slack://channel?team=T0123456789&id=C0123456789")
    }

    @Test func noOrBadTeamGoesThroughBrowser() {
        for team in ["", "bad"] {
            #expect(SlackLink.url(channel: "C0123456789", team: team)?.absoluteString
                == "https://slack.com/app_redirect?channel=C0123456789", "\(team)")
        }
    }

    @Test func trimsTeam() {
        #expect(SlackLink.url(channel: "C0123456789", team: " T0123456789 ")?.absoluteString
            == "slack://channel?team=T0123456789&id=C0123456789")
    }

    @Test func rejectsBadChannel() {
        #expect(SlackLink.url(channel: "C01&x=1", team: "T0123456789") == nil)
        #expect(SlackLink.url(channel: "", team: "") == nil)
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
