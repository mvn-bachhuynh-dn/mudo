import Foundation

/// The ordering rules of the Sessions tab, shared by `SessionStore.rows` and the widget (`RecentSessions`).
public enum SessionOrder {
    /// Everything the order depends on for one session.
    public struct Key: Equatable, Sendable {
        public var bucket: Bucket
        /// When the session entered its state, on any clock as long as all keys compared share it.
        public var since: Date
        public var serverID: String
        public var sessionID: String

        public init(bucket: Bucket, since: Date, serverID: String, sessionID: String) {
            self.bucket = bucket
            self.since = since
            self.serverID = serverID
            self.sessionID = sessionID
        }
    }

    /// `ended` sessions are shown as idle; a `done` session turns stale after `staleAfter` seconds.
    public static func bucket(state: SessionState, elapsed: TimeInterval, staleAfter: TimeInterval) -> Bucket {
        switch state {
        case .waiting: .waiting
        case .done: elapsed >= staleAfter ? .stale : .done
        case .running: .running
        case .idle, .ended: .idle
        }
    }

    /// Whether an idle row is old enough to be hidden.
    public static func isHidden(_ bucket: Bucket, elapsed: TimeInterval, hideIdleAfter: TimeInterval?) -> Bool {
        guard bucket == .idle, let limit = hideIdleAfter else { return false }
        return elapsed >= limit
    }

    /// Bucket order, then longest in state first (idle: newest first), then server id, then session id.
    public static func precedes(_ a: Key, _ b: Key) -> Bool {
        if a.bucket != b.bucket { return a.bucket < b.bucket }
        if a.since != b.since { return a.bucket == .idle ? a.since > b.since : a.since < b.since }
        if a.serverID != b.serverID { return a.serverID < b.serverID }
        return a.sessionID < b.sessionID
    }
}
