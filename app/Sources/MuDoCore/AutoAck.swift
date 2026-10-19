import Foundation

/// What is in front of the user right now.
public enum FrontView: Equatable, Sendable {
    case chromeTab(url: String, title: String)
    /// iTerm2's current session or Terminal's selected tab; `tmuxPane` is the active pane
    /// (e.g. "%3") when that tty is a tmux client, else nil.
    case terminal(tty: String, tmuxPane: String?)
    case editor(title: String)
}

/// Where a session is shown, resolved without side effects.
public enum SessionPlace: Equatable, Sendable {
    case chrome(codeServer: URL, cwd: String, project: String)
    /// The terminal tab's tty: the local shell's, or the tty of the local ssh client.
    case tty(String)
    case tmux(pane: String, socket: String?)
    /// Window-title words; callers pass at most the first two title candidates.
    case editor(titles: [String])
}

/// Acknowledges a finished session whose place is already in front of a present user.
public enum AutoAck {
    public static let presenceWindow: TimeInterval = 60

    public static func isInView(_ place: SessionPlace, front: FrontView) -> Bool {
        switch (place, front) {
        case let (.chrome(codeServer, cwd, project), .chromeTab(url, title)):
            let tab = ChromeTab(windowID: 0, tabIndex: 1, url: url, title: title)
            return TabMatcher.match(tabs: [tab], codeServer: codeServer, cwd: cwd, project: project) != nil
        case let (.tty(a), .terminal(b, _)):
            return a == b
        case let (.tmux(p, _), .terminal(_, q)):
            return q == p
        case let (.editor(titles), .editor(title)):
            return titles.contains { !$0.isEmpty && title.contains($0) }
        default:
            return false
        }
    }

    /// `ChromeScripts.activeTab`'s result as strings: {URL, title}, or {} with no window.
    public static func chromeFront(_ items: [String]) -> FrontView? {
        items.count == 2 ? .chromeTab(url: items[0], title: items[1]) : nil
    }

    /// The place for a session whose terminal or editor is `app`; `outerTTY` is the tty that app knows.
    /// Ghostty and other apps are never auto-acked.
    public static func place(app: TerminalApp, outerTTY: String?, editorTitles: [String]) -> SessionPlace? {
        switch app {
        case .iTerm2, .terminal:
            return outerTTY.map { .tty($0) }
        case .vscodeLike:
            return editorTitles.isEmpty ? nil : .editor(titles: editorTitles)
        case .ghostty, .other:
            return nil
        }
    }

    /// The first two title candidates (deepest cwd folder, project), so a parent folder never matches.
    /// A remote cwd says nothing about local window titles: only the project is kept.
    public static func editorTitles(cwd: String, project: String, home: String, remote: Bool) -> [String] {
        if remote { return project.isEmpty ? [] : [project] }
        return Array(FocusHints.titleCandidates(cwd: cwd, project: project, home: home).prefix(2))
    }

    public static func userPresent(idleSeconds: TimeInterval, screenLocked: Bool) -> Bool {
        !screenLocked && idleSeconds < presenceWindow
    }

    /// Rows to check this tick: state `.done`, not offline, key not in `alreadyAcked`; in row order.
    public static func candidates(_ rows: [SessionRow], alreadyAcked: Set<SessionKey>) -> [SessionRow] {
        rows.filter { $0.session.state == .done && !$0.offline && !alreadyAcked.contains($0.id) }
    }
}
