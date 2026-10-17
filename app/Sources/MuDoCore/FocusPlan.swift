import Foundation

/// How a click on a session row is turned into focus (spec 5.2).
public enum FocusPlan: Equatable, Sendable {
    case chrome(codeServer: URL, cwd: String, project: String)
    case local(TerminalInfo?, cwd: String, project: String)
    case ssh(TerminalInfo, cwd: String, project: String)
    case none

    /// First match wins: local server, code-server terminal, SSH, code-server fallback, nothing.
    public static func plan(server: ServerConfig, session: Session) -> FocusPlan {
        let terminal = session.terminal?.validated()
        let cwd = session.cwd, project = session.project
        if server.isLocal { return .local(terminal, cwd: cwd, project: project) }
        if terminal?.codeServer == true, let cs = server.codeServerURL {
            return .chrome(codeServer: cs, cwd: cwd, project: project)
        }
        if let terminal, (terminal.sshClientPort ?? 0) > 0 {
            return .ssh(terminal, cwd: cwd, project: project)
        }
        if let cs = server.codeServerURL { return .chrome(codeServer: cs, cwd: cwd, project: project) }
        return .none
    }
}
