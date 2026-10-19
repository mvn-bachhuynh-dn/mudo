import Foundation

/// Outcome of Settings → Test for one server: the daemon's `GET /v1/health` with the token,
/// and, when set, whether the code-server URL answers at all.
public enum ServerCheck {
    public enum Daemon: Equatable, Sendable {
        case ok(version: String)
        case unauthorized
        case http(Int)
        case unreachable(String)
    }

    public enum CodeServer: Equatable, Sendable {
        case notSet
        /// Any HTTP answer, a login page or a redirect included: the URL is reachable.
        case reachable(Int)
        case unreachable(String)
    }

    /// The daemon result from a response status and body, or the transport error message.
    public static func daemon(status: Int?, body: Data?, error: String?) -> Daemon {
        guard let status else { return .unreachable(error ?? "no response") }
        switch status {
        case 200:
            struct Health: Decodable { let version: String? }
            let version = body.flatMap { try? JSONDecoder().decode(Health.self, from: $0) }?.version
            return .ok(version: version ?? "?")
        case 401: return .unauthorized
        default: return .http(status)
        }
    }

    public static func codeServer(status: Int?, error: String?) -> CodeServer {
        guard let status else { return .unreachable(error ?? "no response") }
        return .reachable(status)
    }

    public static func message(_ d: Daemon) -> String {
        switch d {
        case let .ok(version): "Daemon OK (mudod \(version))"
        case .unauthorized: "Daemon reachable, but the token is invalid"
        case let .http(code): "Daemon answered HTTP \(code): is this a mudod URL?"
        case let .unreachable(why): "Cannot reach the daemon: \(why)"
        }
    }

    public static func message(_ c: CodeServer) -> String? {
        switch c {
        case .notSet: nil
        case let .reachable(code): "code-server reachable (HTTP \(code))"
        case let .unreachable(why): "Cannot reach code-server: \(why)"
        }
    }

    public static func isOK(_ d: Daemon) -> Bool {
        if case .ok = d { return true }
        return false
    }
}
