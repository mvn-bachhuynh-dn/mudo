import Foundation

/// The sessions a widget shows: the first rows of the app's Sessions tab order (`SessionOrder`): waiting,
/// stale done (done for `staleAfter` seconds or more), done, running (each longest in state first), then
/// idle and ended sessions newest first. Idle and ended sessions older than `hideIdleAfter` are dropped.
public enum RecentSessions {
    /// `serverNow` is the server clock of the snapshot, so `stateSince` needs no clock offset.
    public static func pick(_ sessions: [Session], serverNow: Date, count: Int = 3,
                            staleAfter: TimeInterval = 300,
                            hideIdleAfter: TimeInterval = TimeInterval(IdleFold.defaultHours * 3600)) -> [Session] {
        var keyed: [(SessionOrder.Key, Session)] = []
        for s in sessions {
            let elapsed = max(0, serverNow.timeIntervalSince(s.stateSince))
            let bucket = SessionOrder.bucket(state: s.state, elapsed: elapsed, staleAfter: staleAfter)
            if SessionOrder.isHidden(bucket, elapsed: elapsed, hideIdleAfter: hideIdleAfter) { continue }
            keyed.append((SessionOrder.Key(bucket: bucket, since: s.stateSince, serverID: "", sessionID: s.id), s))
        }
        keyed.sort { SessionOrder.precedes($0.0, $1.0) }
        return keyed.prefix(max(0, count)).map(\.1)
    }
}
