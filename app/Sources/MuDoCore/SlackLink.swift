import Foundation

/// Where a KiroCrew session's Slack channel opens: the Slack app when the workspace ID is known,
/// else slack.com's redirect in the browser.
public enum SlackLink {
    /// `slack://channel?team=<TEAM>&id=<CHANNEL>`, or `https://slack.com/app_redirect?channel=<CHANNEL>`
    /// when `team` (trimmed) is not a valid workspace ID. Nil if `channel` is not a valid channel ID.
    public static func url(channel: String, team: String) -> URL? {
        guard isChannel(channel) else { return nil }
        let team = team.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTeam(team) { return URL(string: "slack://channel?team=\(team)&id=\(channel)") }
        return URL(string: "https://slack.com/app_redirect?channel=\(channel)")
    }

    /// `^[CDG][A-Z0-9]{6,20}$`
    public static func isChannel(_ s: String) -> Bool { id(s, first: "CDG") }

    /// `^[TE][A-Z0-9]{6,20}$`
    public static func isTeam(_ s: String) -> Bool { id(s, first: "TE") }

    private static func id(_ s: String, first: String) -> Bool {
        guard let head = s.first, first.contains(head) else { return false }
        let rest = s.unicodeScalars.dropFirst()
        return (6...20).contains(rest.count)
            && rest.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
