import Foundation

public struct ChromeTab: Equatable, Sendable {
    public var windowID: Int
    public var tabIndex: Int
    public var url: String
    public var title: String

    public init(windowID: Int, tabIndex: Int, url: String, title: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.url = url
        self.title = title
    }
}

/// Picks the Chrome tab showing a session's code-server workspace (spec 6.4).
public enum TabMatcher {
    public static func targetURL(codeServer: URL, cwd: String) -> URL {
        var comps = URLComponents(url: codeServer, resolvingAgainstBaseURL: false) ?? URLComponents()
        if !comps.path.hasSuffix("/") { comps.path += "/" }
        comps.queryItems = [URLQueryItem(name: "folder", value: cwd)]
        return comps.url ?? codeServer
    }

    public static func match(tabs: [ChromeTab], codeServer: URL, cwd: String, project: String) -> ChromeTab? {
        guard let base = URLComponents(url: codeServer, resolvingAgainstBaseURL: false) else { return nil }
        let candidates = tabs.filter { isUnder(base, $0.url) }
        let want = trimSlash(cwd)
        if let hit = candidates.first(where: { folder(of: $0.url).map(trimSlash) == want }) {
            return hit
        }
        let ancestors = candidates.compactMap { tab -> (ChromeTab, Int)? in
            guard let f = folder(of: tab.url).map(trimSlash), !f.isEmpty, want.hasPrefix(f + "/") else { return nil }
            return (tab, f.count)
        }
        if let deepest = ancestors.max(by: { $0.1 < $1.1 }) { return deepest.0 }
        let separators = [" - ", " \u{2014} "]
        return candidates.first { tab in
            separators.contains { sep in
                tab.title.contains("\(sep)\(project)\(sep)") || tab.title.hasPrefix("\(project)\(sep)")
            }
        }
    }

    public static func isUnder(codeServer: URL, _ tabURL: String) -> Bool {
        guard let base = URLComponents(url: codeServer, resolvingAgainstBaseURL: false) else { return false }
        return isUnder(base, tabURL)
    }

    static func isUnder(_ base: URLComponents, _ text: String) -> Bool {
        guard let u = URLComponents(string: text),
              u.scheme?.lowercased() == base.scheme?.lowercased(),
              u.host?.lowercased() == base.host?.lowercased(),
              port(u) == port(base) else { return false }
        let prefix = trimSlash(base.path)
        if prefix.isEmpty { return true }
        return u.path == prefix || u.path.hasPrefix(prefix + "/")
    }

    static func port(_ c: URLComponents) -> Int? {
        if let p = c.port { return p }
        switch c.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func folder(of text: String) -> String? {
        URLComponents(string: text)?.queryItems?.first(where: { $0.name == "folder" })?.value
    }

    static func trimSlash(_ path: String) -> String {
        var p = Substring(path)
        while p.hasSuffix("/") { p = p.dropLast() }
        return String(p)
    }
}

/// AppleScript sources sent to Google Chrome. Kept here so they are testable on any OS.
public enum ChromeScripts {
    /// Returns a list of {window id, tab index, URL, title}.
    public static let listTabs = """
    tell application id "com.google.Chrome"
        set out to {}
        repeat with w in windows
            set ti to 0
            repeat with t in tabs of w
                set ti to ti + 1
                set end of out to {id of w, ti, URL of t, title of t}
            end repeat
        end repeat
        return out
    end tell
    """

    public static func focus(_ tab: ChromeTab) -> String {
        """
        tell application id "com.google.Chrome"
            set w to window id \(tab.windowID)
            if minimized of w then set minimized of w to false
            set active tab index of w to \(tab.tabIndex)
            set index of w to 1
            activate
        end tell
        """
    }

    public static func newWindow(_ url: URL) -> String {
        """
        tell application id "com.google.Chrome"
            set w to make new window
            set URL of active tab of w to \(quoted(url.absoluteString))
            activate
        end tell
        """
    }

    public static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
