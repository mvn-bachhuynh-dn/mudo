import Foundation
import Testing
@testable import MuDoCore

@Suite struct TerminalScriptsTests {
    static let nasty = "a\"b\\c\nd"
    static let escaped = #""a\"b\\c\nd""#

    @Test func quotedEscapesNewlines() {
        #expect(TabMatcher.quoted(Self.nasty) == Self.escaped)
        #expect(TabMatcher.quoted("x\ry") == #""x\ry""#)
        #expect(ChromeScripts.quoted(Self.nasty) == Self.escaped)
    }

    func onlyEscaped(_ script: String) {
        #expect(script.contains(Self.escaped))
        #expect(!script.contains("a\"b"))
        #expect(!script.contains("c\nd"))
    }

    @Test func iTermMatchesIDOrTTY() {
        let s = TerminalScripts.iTerm(sessionID: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", tty: "/dev/ttys004")
        #expect(s.contains(#"tell application "iTerm2""#))
        #expect(s.contains(#"(unique id of s) is "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9""#))
        #expect(s.contains(#"(tty of s) is "/dev/ttys004""#))
        for line in ["select s", "select t", "select w", "activate", "return true", "return false"] {
            #expect(s.contains(line), "\(line)")
        }
    }

    @Test func iTermWithoutSessionMatchesTTYOnly() {
        let s = TerminalScripts.iTerm(sessionID: nil, tty: "/dev/ttys004")
        #expect(!s.contains("unique id"))
        #expect(s.contains(#"(tty of s) is "/dev/ttys004""#))
    }

    @Test func iTermEscapes() {
        onlyEscaped(TerminalScripts.iTerm(sessionID: Self.nasty, tty: nil))
        onlyEscaped(TerminalScripts.iTerm(sessionID: nil, tty: Self.nasty))
    }

    @Test func terminalApp() {
        let s = TerminalScripts.terminalApp(tty: "/dev/ttys004")
        #expect(s.contains(#"tell application "Terminal""#))
        #expect(s.contains(#"tty of t is "/dev/ttys004""#))
        #expect(s.contains("set selected tab of w to t"))
        #expect(s.contains("set index of w to 1"))
        #expect(s.contains("activate"))
        onlyEscaped(TerminalScripts.terminalApp(tty: Self.nasty))
    }

    @Test func ghostty() {
        let s = TerminalScripts.ghosttyByTTY("/dev/ttys004")
        #expect(s.contains(#"tell application "Ghostty""#))
        #expect(s.contains(#"tty of term is "/dev/ttys004""#))
        #expect(s.contains("focus term"))
        #expect(s.contains("activate"))
        onlyEscaped(TerminalScripts.ghosttyByTTY(Self.nasty))

        let list = TerminalScripts.ghosttyList()
        #expect(list.contains("{id of term, working directory of term}"))

        let f = TerminalScripts.ghosttyFocus(id: "ABC-1")
        #expect(f.contains(#"id of term is "ABC-1""#))
        #expect(f.contains("focus term"))
        onlyEscaped(TerminalScripts.ghosttyFocus(id: Self.nasty))
    }

    @Test func raiseWindowTriesCandidatesInOrder() throws {
        let s = TerminalScripts.raiseWindow(appName: "Code", titleContains: ["proj", "x"])
        #expect(s.contains(#"tell application "System Events""#))
        #expect(s.contains(#"tell process "Code""#))
        #expect(s.contains(#"perform action "AXRaise" of w"#))
        #expect(s.contains("set frontmost to true"))
        let a = try #require(s.range(of: #"contains "proj""#))
        let b = try #require(s.range(of: #"contains "x""#))
        #expect(a.lowerBound < b.lowerBound)
        onlyEscaped(TerminalScripts.raiseWindow(appName: Self.nasty, titleContains: []))
        onlyEscaped(TerminalScripts.raiseWindow(appName: "Code", titleContains: [Self.nasty]))
    }

    /// The in-view probes only read: no script may focus, select or raise anything.
    func readOnly(_ script: String, app: String) {
        #expect(script.contains(app), "\(app)")
        #expect(script.contains("count of windows) is 0 then return"))
        // "select " with a space: Terminal's read of "selected tab" is allowed, the `select` command is not.
        for word in ["activate", "select ", "set selected", "set index", "AXRaise", "set frontmost"] {
            #expect(!script.contains(word), "\(word)")
        }
    }

    @Test func frontProbesOnlyRead() {
        readOnly(ChromeScripts.activeTab, app: #"tell application id "com.google.Chrome""#)
        #expect(ChromeScripts.activeTab.contains("{URL of active tab of front window, title of active tab of front window}"))
        readOnly(TerminalScripts.iTermFrontTTY, app: #"tell application "iTerm2""#)
        #expect(TerminalScripts.iTermFrontTTY.contains("tty of current session of current window"))
        readOnly(TerminalScripts.terminalAppFrontTTY, app: #"tell application "Terminal""#)
        #expect(TerminalScripts.terminalAppFrontTTY.contains("tty of selected tab of front window"))
        let title = TerminalScripts.frontWindowTitle(appName: "Code")
        readOnly(title, app: #"tell application "System Events""#)
        #expect(title.contains(#"tell process "Code""#))
        #expect(title.contains("(name of front window) as text"))
        onlyEscaped(TerminalScripts.frontWindowTitle(appName: Self.nasty))
    }
}
