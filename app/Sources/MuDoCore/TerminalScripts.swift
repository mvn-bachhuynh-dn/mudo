import Foundation

/// AppleScript sources for focusing local terminals (spec 5.4). Every value goes through `TabMatcher.quoted`.
public enum TerminalScripts {
    /// Matches by iTerm2 unique id or tty; the id test is omitted when `sessionID` is nil.
    public static func iTerm(sessionID: String?, tty: String?) -> String {
        var tests: [String] = []
        if let sessionID { tests.append("(unique id of s) is \(q(sessionID))") }
        if let tty { tests.append("(tty of s) is \(q(tty))") }
        let test = tests.isEmpty ? "false" : tests.joined(separator: " or ")
        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(test) then
                            select s
                            select t
                            select w
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    public static func terminalApp(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(q(tty)) then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """
    }

    /// Errors on Ghostty before 1.4 (no `tty` property); the caller treats that as "no tty support".
    public static func ghosttyByTTY(_ tty: String) -> String {
        ghosttyFind("tty of term is \(q(tty))")
    }

    /// Returns a list of {id, working directory} for every terminal, for the cwd fallback.
    public static func ghosttyList() -> String {
        """
        tell application "Ghostty"
            set out to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        set end of out to {id of term, working directory of term}
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
    }

    public static func ghosttyFocus(id: String) -> String {
        ghosttyFind("id of term is \(q(id))")
    }

    /// Raises the first window of `appName` whose title contains a candidate, trying candidates in order.
    public static func raiseWindow(appName: String, titleContains: [String]) -> String {
        let loops = titleContains.map { candidate in
            """
                    repeat with w in windows
                        set n to ""
                        try
                            set n to (name of w) as text
                        end try
                        if n contains \(q(candidate)) then
                            perform action "AXRaise" of w
                            set frontmost to true
                            return true
                        end if
                    end repeat
            """
        }.joined(separator: "\n")
        return """
        tell application "System Events"
            tell process \(q(appName))
        \(loops)
            end tell
        end tell
        return false
        """
    }

    /// The tty of iTerm2's current session, or "" with no window. Read-only, like the three below.
    public static let iTermFrontTTY = """
    tell application "iTerm2"
        if (count of windows) is 0 then return ""
        return tty of current session of current window
    end tell
    """

    public static let terminalAppFrontTTY = """
    tell application "Terminal"
        if (count of windows) is 0 then return ""
        return tty of selected tab of front window
    end tell
    """

    public static func frontWindowTitle(appName: String) -> String {
        """
        tell application "System Events"
            tell process \(q(appName))
                if (count of windows) is 0 then return ""
                return (name of front window) as text
            end tell
        end tell
        """
    }

    private static func ghosttyFind(_ test: String) -> String {
        """
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        if \(test) then
                            focus term
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    private static func q(_ text: String) -> String { TabMatcher.quoted(text) }
}
