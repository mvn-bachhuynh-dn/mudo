import Foundation
import Observation

public struct SessionKey: Hashable, Sendable {
    public let serverID: UUID
    public let sessionID: String

    public init(serverID: UUID, sessionID: String) {
        self.serverID = serverID
        self.sessionID = sessionID
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case connecting, connected, offline, unauthorized
}

public struct ServerRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let status: ConnectionStatus

    public init(id: UUID, name: String, status: ConnectionStatus) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// Merges the session streams of every configured server (spec 6.3, 6.6).
@MainActor
@Observable
public final class SessionStore {
    struct ServerState {
        var name: String
        var status: ConnectionStatus = .connecting
        var offset: TimeInterval = 0
        var sessions: [String: Session] = [:]
    }

    public var staleAfter: TimeInterval = 300
    public var snoozeFor: TimeInterval = 600
    public var ignoreRules = IgnoreRules(patterns: [])
    public private(set) var now: Date

    var serverStates: [UUID: ServerState] = [:]
    var order: [UUID] = []
    var snoozedUntil: [SessionKey: Date] = [:]
    var pausedUntil: Date?
    private var failedAcks: Set<SessionKey> = []
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        self.now = clock()
    }

    // MARK: Servers

    public func setServers(_ configs: [ServerConfig]) {
        var next: [UUID: ServerState] = [:]
        for config in configs {
            var state = serverStates[config.id] ?? ServerState(name: config.name)
            state.name = config.name
            next[config.id] = state
        }
        serverStates = next
        order = configs.map(\.id)
        failedAcks = failedAcks.filter { next[$0.serverID] != nil }
        pruneSnoozes()
    }

    public func status(of serverID: UUID) -> ConnectionStatus? {
        serverStates[serverID]?.status
    }

    public func setStatus(_ status: ConnectionStatus, for serverID: UUID) {
        guard serverStates[serverID] != nil, serverStates[serverID]?.status != status else { return }
        serverStates[serverID]?.status = status
    }

    public func offset(of serverID: UUID) -> TimeInterval? {
        serverStates[serverID]?.offset
    }

    public var servers: [ServerRow] {
        order.compactMap { id in
            serverStates[id].map { ServerRow(id: id, name: $0.name, status: $0.status) }
        }
    }

    public var problemServers: [ServerRow] {
        servers.filter { $0.status != .connected }
    }

    public var hasMultipleServers: Bool { serverStates.count > 1 }

    // MARK: Stream messages

    @discardableResult
    public func apply(_ message: StreamMessage, from serverID: UUID) -> [SessionKey] {
        guard var server = serverStates[serverID] else { return [] }
        now = clock()
        server.offset = message.serverNow.timeIntervalSince(now)
        var retries: [SessionKey] = []
        switch message {
        case let .snapshot(_, _, sessions):
            server.sessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for key in failedAcks where key.serverID == serverID {
                if server.sessions[key.sessionID]?.state == .done { retries.append(key) }
            }
            failedAcks = failedAcks.filter { $0.serverID != serverID }
        case let .upsert(_, session):
            server.sessions[session.id] = session
        case let .remove(_, id):
            server.sessions[id] = nil
        case .ping:
            break
        }
        serverStates[serverID] = server
        pruneSnoozes()
        return retries
    }

    public func markAckFailed(_ key: SessionKey) {
        failedAcks.insert(key)
    }

    public func session(_ key: SessionKey) -> Session? {
        serverStates[key.serverID]?.sessions[key.sessionID]
    }

    // MARK: Time

    public func tick() {
        now = clock()
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        if let until = pausedUntil, until <= now { pausedUntil = nil }
    }

    /// Snoozes only make sense for sessions that are still `done`.
    func pruneSnoozes() {
        snoozedUntil = snoozedUntil.filter { session($0.key)?.state == .done }
    }
}

public enum Bucket: Int, Comparable, Sendable {
    case waiting, stale, done, running, idle

    public static func < (lhs: Bucket, rhs: Bucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SessionRow: Identifiable, Equatable, Sendable {
    public let id: SessionKey
    public let session: Session
    public let serverName: String
    public let bucket: Bucket
    /// `state_since` converted to the local clock.
    public let since: Date
    public let elapsed: TimeInterval
    public let blinking: Bool
    public let offline: Bool
}

public struct PillSummary: Equatable, Sendable {
    public let running: Int
    public let waiting: Int
    public let done: Int
    public let blinking: Bool
    public let offline: Bool

    public init(running: Int, waiting: Int, done: Int, blinking: Bool, offline: Bool) {
        self.running = running
        self.waiting = waiting
        self.done = done
        self.blinking = blinking
        self.offline = offline
    }
}

extension SessionStore {
    public var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > now
    }

    public func pause(for duration: TimeInterval) {
        tick()
        pausedUntil = now.addingTimeInterval(duration)
    }

    public func resume() {
        pausedUntil = nil
    }

    public func snooze(_ key: SessionKey) {
        guard session(key)?.state == .done else { return }
        tick()
        snoozedUntil[key] = now.addingTimeInterval(snoozeFor)
    }

    public func clearSnooze(_ key: SessionKey) {
        snoozedUntil[key] = nil
    }

    public var rows: [SessionRow] {
        let paused = isPaused
        var out: [SessionRow] = []
        for (serverID, server) in serverStates {
            let offline = server.status != .connected
            for s in server.sessions.values where s.state != .ended && !ignoreRules.ignores(cwd: s.cwd) {
                let key = SessionKey(serverID: serverID, sessionID: s.id)
                let since = s.stateSince.addingTimeInterval(-server.offset)
                let elapsed = max(0, now.timeIntervalSince(since))
                let bucket: Bucket = switch s.state {
                case .waiting: .waiting
                case .done: elapsed >= staleAfter ? .stale : .done
                case .running: .running
                case .idle, .ended: .idle
                }
                let snoozed = snoozedUntil[key].map { $0 > now } ?? false
                out.append(SessionRow(
                    id: key, session: s, serverName: server.name, bucket: bucket,
                    since: since, elapsed: elapsed,
                    blinking: bucket == .stale && !snoozed && !paused && !offline,
                    offline: offline))
            }
        }
        return out.sorted { a, b in
            if a.bucket != b.bucket { return a.bucket < b.bucket }
            if a.since != b.since { return a.since < b.since }
            if a.id.serverID != b.id.serverID { return a.id.serverID.uuidString < b.id.serverID.uuidString }
            return a.id.sessionID < b.id.sessionID
        }
    }

    public var pill: PillSummary {
        let all = rows
        return PillSummary(
            running: all.count(where: { $0.bucket == .running }),
            waiting: all.count(where: { $0.bucket == .waiting }),
            done: all.count(where: { $0.bucket == .done || $0.bucket == .stale }),
            blinking: all.contains(where: \.blinking),
            offline: serverStates.values.allSatisfy { $0.status == .offline || $0.status == .unauthorized })
    }
}
