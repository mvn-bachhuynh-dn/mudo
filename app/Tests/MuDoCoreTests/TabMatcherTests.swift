import Foundation
import Testing
@testable import MuDoCore

@Suite struct TabMatcherTests {
    let cs = URL(string: "http://100.64.0.10:8080")!

    private func tab(_ w: Int, _ t: Int, _ url: String, _ title: String = "") -> ChromeTab {
        ChromeTab(windowID: w, tabIndex: t, url: url, title: title)
    }

    @Test func targetURLEncodesSpacesKeepsSlashes() {
        #expect(TabMatcher.targetURL(codeServer: cs, cwd: "/home/steve/My Proj").absoluteString
                == "http://100.64.0.10:8080/?folder=/home/steve/My%20Proj")
    }

    @Test func targetURLKeepsBasePath() {
        let base = URL(string: "https://h/cs/")!
        #expect(TabMatcher.targetURL(codeServer: base, cwd: "/x").absoluteString == "https://h/cs/?folder=/x")
    }

    @Test func matchesFolderQuery() {
        let tabs = [
            tab(1, 1, "https://mail.google.com/"),
            tab(2, 1, "http://100.64.0.10:8080/?folder=/home/steve/other"),
            tab(2, 2, "http://100.64.0.10:8080/?folder=/home/steve/api"),
        ]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/api", project: "api") == tabs[2])
    }

    @Test func matchesPercentEncodedFolderAndTrailingSlash() {
        let tabs = [tab(3, 1, "http://100.64.0.10:8080/?folder=%2Fhome%2Fsteve%2FMy%20Proj%2F")]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/My Proj", project: "My Proj") == tabs[0])
    }

    @Test func folderMatchBeatsEarlierTitleMatch() {
        let tabs = [
            tab(1, 1, "http://100.64.0.10:8080/?folder=/elsewhere", "main.go — api — code-server"),
            tab(2, 1, "http://100.64.0.10:8080/?folder=/home/steve/api", "x"),
        ]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/api", project: "api") == tabs[1])
    }

    @Test func titleFallback() {
        let tabs = [
            tab(1, 1, "http://100.64.0.10:8080/", "README.md — web — code-server"),
            tab(1, 2, "http://100.64.0.10:8080/", "main.go — api — code-server"),
        ]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/api", project: "api") == tabs[1])
    }

    @Test func titleFallbackWithoutOpenEditor() {
        let tabs = [tab(1, 1, "http://100.64.0.10:8080/", "api — code-server")]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/api", project: "api") == tabs[0])
    }

    @Test func titleOnTabOutsideCodeServerIgnored() {
        let tabs = [tab(1, 1, "https://github.com/x/api", "main.go — api — code-server")]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/api", project: "api") == nil)
    }

    @Test func otherPortOrHostIgnored() {
        let tabs = [
            tab(1, 1, "http://100.64.0.10:9090/?folder=/home/steve/api"),
            tab(1, 2, "http://10.0.0.1:8080/?folder=/home/steve/api"),
        ]
        #expect(TabMatcher.match(tabs: tabs, codeServer: cs, cwd: "/home/steve/api", project: "api") == nil)
    }

    @Test func basePathBoundary() {
        let base = URL(string: "http://h/cs")!
        let ok = tab(1, 1, "http://h/cs/?folder=/x")
        let bad = tab(1, 2, "http://h/csx/?folder=/x")
        #expect(TabMatcher.match(tabs: [bad, ok], codeServer: base, cwd: "/x", project: "x") == ok)
        #expect(TabMatcher.match(tabs: [bad], codeServer: base, cwd: "/x", project: "x") == nil)
    }

    @Test func defaultPortsAreEquivalent() {
        let base = URL(string: "https://code.example.com")!
        let tabs = [tab(1, 1, "https://code.example.com:443/?folder=/x")]
        #expect(TabMatcher.match(tabs: tabs, codeServer: base, cwd: "/x", project: "x") == tabs[0])
    }

    @Test func noTabs() {
        #expect(TabMatcher.match(tabs: [], codeServer: cs, cwd: "/x", project: "x") == nil)
    }
}

@Suite struct ChromeScriptsTests {
    @Test func quotesBackslashAndQuote() {
        #expect(ChromeScripts.quoted(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func focusScriptTargetsWindowAndTab() {
        let s = ChromeScripts.focus(ChromeTab(windowID: 1234, tabIndex: 3, url: "", title: ""))
        #expect(s.contains("window id 1234"))
        #expect(s.contains("set active tab index of w to 3"))
        #expect(s.contains("set minimized of w to false"))
        #expect(s.contains("set index of w to 1"))
        #expect(s.contains("activate"))
    }

    @Test func newWindowScriptQuotesURL() {
        let s = ChromeScripts.newWindow(URL(string: "http://h:8080/?folder=/a%20b")!)
        #expect(s.contains(#"set URL of active tab of w to "http://h:8080/?folder=/a%20b""#))
        #expect(s.contains("make new window"))
    }

    @Test func listScriptReturnsWindowIDs() {
        #expect(ChromeScripts.listTabs.contains("id of w"))
        #expect(ChromeScripts.listTabs.contains(#"tell application id "com.google.Chrome""#))
    }
}
