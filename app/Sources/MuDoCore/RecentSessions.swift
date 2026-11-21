import Foundation

/// The sessions a widget shows: waiting ones first, then the rest, each group newest state change first.
public enum RecentSessions {
    public static func pick(_ sessions: [Session], count: Int = 3) -> [Session] {
        func newestFirst(_ a: Session, _ b: Session) -> Bool {
            a.stateSince != b.stateSince ? a.stateSince > b.stateSince : a.id < b.id
        }
        let live = sessions.filter { $0.state != .ended }
        let waiting = live.filter { $0.state == .waiting }.sorted(by: newestFirst)
        let others = live.filter { $0.state != .waiting }.sorted(by: newestFirst)
        return Array((waiting + others).prefix(max(0, count)))
    }
}
