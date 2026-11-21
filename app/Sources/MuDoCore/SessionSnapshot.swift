import Foundation

/// A one-shot read of a server's sessions: the first `snapshot` event of `GET /v1/stream`.
public enum SessionSnapshot {
    public enum Failure: Error, Equatable, Sendable {
        case unauthorized
        case http(Int)
        case timeout
        case noSnapshot
        case other(String)

        public var message: String {
            switch self {
            case .unauthorized: "token invalid"
            case .http(let code): "HTTP \(code)"
            case .timeout: "timed out"
            case .noSnapshot: "no data"
            case .other(let text): text
            }
        }
    }

    /// The server clock and the sessions of a `snapshot` event.
    public struct Snapshot: Equatable, Sendable {
        public var serverNow: Date
        public var sessions: [Session]

        public init(serverNow: Date, sessions: [Session]) {
            self.serverNow = serverNow
            self.sessions = sessions
        }
    }

    /// The first `snapshot` event, or nil when the stream ends without one.
    public static func first(from events: AsyncThrowingStream<SSEEvent, any Error>) async throws -> Snapshot? {
        for try await event in events where event.event == "snapshot" {
            if case let .snapshot(serverNow, _, sessions)? = try StreamMessage.decode(event: event.event, data: event.data) {
                return Snapshot(serverNow: serverNow, sessions: sessions)
            }
        }
        return nil
    }

    public static func fetch(daemon: URL, token: String, transport: any EventTransport,
                             timeout: Duration = .seconds(10)) async -> Result<Snapshot, Failure> {
        let url = daemon.appending(path: "v1/stream")
        return await withTaskGroup(of: Result<Snapshot, Failure>.self) { group in
            group.addTask {
                do {
                    if let snapshot = try await first(from: transport.events(url: url, token: token)) {
                        return .success(snapshot)
                    }
                    return .failure(.noSnapshot)
                } catch StreamError.unauthorized {
                    return .failure(.unauthorized)
                } catch StreamError.http(let code) {
                    return .failure(.http(code))
                } catch let error as URLError {
                    return .failure(error.code == .timedOut ? .timeout : .other("offline"))
                } catch {
                    return .failure(.other(error.localizedDescription))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failure(.timeout)
            }
            let result = await group.next() ?? .failure(.timeout)
            group.cancelAll()
            return result
        }
    }
}
