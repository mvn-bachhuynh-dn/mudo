import Foundation

public enum SessionState: String, Codable, Sendable {
    case idle, running, waiting, done, ended
}

/// One agent session as sent by mudod (spec 5). Extra server fields are ignored.
public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var agent: String
    public var host: String
    public var cwd: String
    public var project: String
    public var state: SessionState
    public var stateSince: Date
    public var lastPrompt: String
    /// Absent from older mudod builds and hooks.
    public var terminal: TerminalInfo?

    public init(id: String, agent: String, host: String, cwd: String, project: String,
                state: SessionState, stateSince: Date, lastPrompt: String, terminal: TerminalInfo? = nil) {
        self.id = id
        self.agent = agent
        self.host = host
        self.cwd = cwd
        self.project = project
        self.state = state
        self.stateSince = stateSince
        self.lastPrompt = lastPrompt
        self.terminal = terminal
    }
}

public enum StreamMessage: Equatable, Sendable {
    case snapshot(serverNow: Date, host: String, sessions: [Session])
    case upsert(serverNow: Date, session: Session)
    case remove(serverNow: Date, id: String)
    case ping(serverNow: Date)

    public var serverNow: Date {
        switch self {
        case let .snapshot(now, _, _), let .upsert(now, _), let .remove(now, _), let .ping(now):
            return now
        }
    }

    /// Decodes one SSE event. Returns nil for event names the app does not know.
    public static func decode(event: String, data: String) throws -> StreamMessage? {
        let bytes = Data(data.utf8)
        let decoder = WireDate.decoder()
        switch event {
        case "snapshot":
            let m = try decoder.decode(SnapshotWire.self, from: bytes)
            return .snapshot(serverNow: m.serverNow, host: m.host, sessions: m.sessions ?? [])
        case "upsert":
            let m = try decoder.decode(UpsertWire.self, from: bytes)
            return .upsert(serverNow: m.serverNow, session: m.session)
        case "remove":
            let m = try decoder.decode(RemoveWire.self, from: bytes)
            return .remove(serverNow: m.serverNow, id: m.id)
        case "ping":
            let m = try decoder.decode(PingWire.self, from: bytes)
            return .ping(serverNow: m.serverNow)
        default:
            return nil
        }
    }
}

private struct SnapshotWire: Decodable {
    let serverNow: Date
    let host: String
    let sessions: [Session]?
}

private struct UpsertWire: Decodable {
    let serverNow: Date
    let session: Session
}

private struct RemoveWire: Decodable {
    let serverNow: Date
    let id: String
}

private struct PingWire: Decodable {
    let serverNow: Date
}

public enum WireDate {
    /// Parses RFC 3339 timestamps with any number of fractional digits (Go emits up to 9).
    public static func parse(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let rest = text[text.index(after: dot)...]
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty else { return nil }
            fraction = Double("0." + digits) ?? 0
            base = String(text[..<dot]) + String(rest.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: base) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad timestamp \(text)")
            }
            return date
        }
        return decoder
    }
}
