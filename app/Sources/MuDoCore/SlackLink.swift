import Foundation

/// Where a click on a KiroCrew session opens its Slack channel.
public enum SlackTarget: Equatable, Sendable {
    /// `slack://` deep link, handled by the Slack app.
    case app(URL)
    /// A Slack web URL. With `team`, an existing Slack web tab of that workspace is reused.
    case web(URL, team: String?)
}

public enum SlackLink {
    /// With a valid `team` (trimmed): the Slack app if installed, else Slack web
    /// (`https://app.slack.com/client/<TEAM>/<CHANNEL>`). Without one: slack.com's redirect.
    /// Nil if `channel` is not a valid channel ID.
    public static func target(channel: String, team: String, hasApp: Bool) -> SlackTarget? {
        guard isChannel(channel) else { return nil }
        let team = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTeam(team) else {
            return URL(string: "https://slack.com/app_redirect?channel=\(channel)").map { .web($0, team: nil) }
        }
        if hasApp { return URL(string: "slack://channel?team=\(team)&id=\(channel)").map(SlackTarget.app) }
        return URL(string: "https://app.slack.com/client/\(team)/\(channel)").map { .web($0, team: team) }
    }

    /// A Slack web tab of `team` to reuse: one already on `channel` (no navigation needed),
    /// else the first tab of that workspace (navigate it to the channel).
    public static func webTab(in tabs: [ChromeTab], team: String, channel: String) -> (tab: ChromeTab, navigate: Bool)? {
        let ofTeam = tabs.compactMap { tab -> (ChromeTab, String?)? in
            guard let c = URLComponents(string: tab.url), c.scheme == "https", c.host == "app.slack.com" else { return nil }
            let parts = c.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == "client", parts[1] == team else { return nil }
            return (tab, parts.count >= 3 ? parts[2] : nil)
        }
        if let hit = ofTeam.first(where: { $0.1 == channel }) { return (hit.0, false) }
        return ofTeam.first.map { ($0.0, true) }
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
