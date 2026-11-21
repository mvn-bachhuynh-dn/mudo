import MuDoCore
import WidgetKit

struct MuDoEntry: TimelineEntry {
    let date: Date
    var serverName: String?
    /// Accounts of the server, already sorted for display.
    var accounts: [CswapAccount] = []
    var accountsError: String?
    /// The first 3 sessions in the same order as the Sessions tab.
    var sessions: [Session] = []
    var sessionsError: String?
    /// Shown instead of everything else (no server, no token).
    var message: String?
    /// What the lock screen rectangle shows (from the widget configuration).
    var content: ContentChoice = .account

    var active: CswapAccount? { accounts.first { $0.active } }

    static let sample = MuDoEntry(
        date: .now, serverName: "devbox",
        accounts: [
            CswapAccount(number: 1, email: "alex@example.com", organization: "Team Alpha", alias: nil, active: true, status: .ok,
                         windows: [CswapWindow(name: "5h", pct: 18, clock: nil, countdown: "4h 4m"),
                                   CswapWindow(name: "7d", pct: 41, clock: nil, countdown: "5d 11h")], stale: false),
            CswapAccount(number: 2, email: "sam@example.com", organization: "Team Beta", alias: nil, active: false, status: .ok,
                         windows: [CswapWindow(name: "5h", pct: 74, clock: nil, countdown: "4h 4m"),
                                   CswapWindow(name: "7d", pct: 63, clock: nil, countdown: "5d 11h")], stale: false),
            CswapAccount(number: 3, email: "lee@example.com", organization: "Team Gamma", alias: nil, active: false,
                         status: .reloginRequired, windows: [], stale: false),
        ],
        sessions: [
            Session(id: "a", agent: "claude", host: "devbox", cwd: "/p/api", project: "api-gateway", state: .waiting,
                    stateSince: .now.addingTimeInterval(-120), lastPrompt: "refactor auth"),
            Session(id: "b", agent: "kiro", host: "devbox", cwd: "/p/web", project: "web-ui", state: .running,
                    stateSince: .now.addingTimeInterval(-600), lastPrompt: "dark mode"),
            Session(id: "c", agent: "claude", host: "devbox", cwd: "/p/tf", project: "infra-tf", state: .done,
                    stateSince: .now.addingTimeInterval(-3600), lastPrompt: "vpc split"),
        ])
}
