import Foundation
import Testing
@testable import MuDoCore

@Suite struct FocusLinkTests {
    @Test func parsesProject() throws {
        let url = try #require(URL(string: "mudo://focus?project=must-do"))
        #expect(FocusLink.parse(url) == .project("must-do"))
    }

    @Test func parsesSession() throws {
        let url = try #require(URL(string: "mudo://focus?session=abc-123"))
        #expect(FocusLink.parse(url) == .session("abc-123"))
    }

    @Test func decodesPercentEncoding() throws {
        let url = try #require(URL(string: "mudo://focus?project=my%20proj"))
        #expect(FocusLink.parse(url) == .project("my proj"))
    }

    @Test func sessionWinsWhenBothGiven() throws {
        let url = try #require(URL(string: "mudo://focus?project=p&session=s"))
        #expect(FocusLink.parse(url) == .session("s"))
    }

    @Test func rejectsMissingOrEmptyQuery() throws {
        for s in ["mudo://focus", "mudo://focus?project=", "mudo://focus?other=x"] {
            #expect(FocusLink.parse(try #require(URL(string: s))) == nil)
        }
    }

    @Test func rejectsOtherHostsAndSchemes() throws {
        for s in ["mudo://add?project=x", "http://focus?project=x"] {
            #expect(FocusLink.parse(try #require(URL(string: s))) == nil)
        }
    }
}
