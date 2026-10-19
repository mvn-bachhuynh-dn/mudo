import Foundation

public struct ProcInfo: Equatable, Sendable {
    public var pid: Int
    public var ppid: Int
    public var tty: String?
    public var comm: String

    public init(pid: Int, ppid: Int, tty: String?, comm: String) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.comm = comm
    }
}

public enum TerminalApp: Equatable, Sendable {
    case iTerm2, terminal, ghostty
    case vscodeLike(bundlePath: String)
    case other(bundlePath: String)
}

public enum Owner: Equatable, Sendable {
    case app(TerminalApp)
    case tmux(pid: Int)
}

/// One `ps` snapshot of the Mac's processes (spec 5.3).
public struct ProcessTable: Sendable {
    private var byPID: [Int: ProcInfo] = [:]
    private var order: [Int] = []

    /// Parses `/bin/ps -A -o pid=,ppid=,tty=,comm=`. `comm` may contain spaces.
    public init(psOutput: String) {
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 4, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            let comm = parts[3].trimmingCharacters(in: .whitespaces)
            guard !comm.isEmpty else { continue }
            let tty = String(parts[2])
            let info = ProcInfo(pid: pid, ppid: ppid,
                                tty: tty == "??" || tty == "-" ? nil : (tty.hasPrefix("/dev/") ? tty : "/dev/" + tty),
                                comm: comm)
            if byPID[pid] == nil { order.append(pid) }
            byPID[pid] = info
        }
    }

    public func process(_ pid: Int) -> ProcInfo? { byPID[pid] }

    /// Processes on `tty`, in `ps` order.
    public func processes(onTTY tty: String) -> [ProcInfo] {
        order.compactMap { byPID[$0] }.filter { $0.tty == tty }
    }

    /// The terminal app (or tmux server) above `pid`; nil when the walk reaches launchd.
    public func owner(of pid: Int) -> Owner? {
        for p in ancestry(of: pid) {
            if p.pid <= 1 { return nil }
            let name = (p.comm as NSString).lastPathComponent
            if name == "tmux" { return .tmux(pid: p.pid) }
            if name.hasPrefix("iTermServer") { return .app(.iTerm2) }
            if let bundle = Self.outermostBundle(p.comm) { return .app(Self.classify(bundle)) }
        }
        return nil
    }

    /// The tty of the topmost ancestor that still has one: the tty the terminal app knows.
    public func outerTTY(of pid: Int) -> String? {
        var tty: String?
        for p in ancestry(of: pid) {
            guard let t = p.tty else { break }
            tty = t
        }
        return tty
    }

    /// The path up to and including the first `.app` component.
    public static func outermostBundle(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var out = ""
        for comp in path.split(separator: "/") {
            out += "/" + comp
            if comp.hasSuffix(".app") { return out }
        }
        return nil
    }

    public static func classify(_ bundle: String) -> TerminalApp {
        switch (bundle as NSString).lastPathComponent {
        case "iTerm.app": return .iTerm2
        case "Terminal.app": return .terminal
        case "Ghostty.app": return .ghostty
        case "Visual Studio Code.app", "Cursor.app", "Windsurf.app", "VSCodium.app", "Kiro.app":
            return .vscodeLike(bundlePath: bundle)
        default: return .other(bundlePath: bundle)
        }
    }

    /// `pid` and its parents, stopping at a missing parent or a loop.
    private func ancestry(of pid: Int) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var seen: Set<Int> = []
        var cur = pid
        while let p = byPID[cur], seen.insert(cur).inserted {
            out.append(p)
            cur = p.ppid
        }
        return out
    }
}

public struct SSHConn: Equatable, Sendable {
    public var pid: Int
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(pid: Int, localPort: Int, remoteHost: String, remotePort: Int) {
        self.pid = pid
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

/// Parses `/usr/sbin/lsof -nP -a -iTCP -sTCP:ESTABLISHED -F pcn`, keeping `ssh` clients only.
public enum LsofSSH {
    public static func parse(_ out: String) -> [SSHConn] {
        var conns: [SSHConn] = []
        var pid: Int?
        var command: String?
        for line in out.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int(value)
                command = nil
            case "c":
                command = value
            case "n":
                guard let pid, command == "ssh",
                      let arrow = value.range(of: "->"),
                      let local = hostPort(value[..<arrow.lowerBound]),
                      let remote = hostPort(value[arrow.upperBound...]) else { continue }
                conns.append(SSHConn(pid: pid, localPort: local.port, remoteHost: remote.host, remotePort: remote.port))
            default:
                continue
            }
        }
        return conns
    }

    static func hostPort(_ text: Substring) -> (host: String, port: Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        var host = text[..<colon]
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        guard !host.isEmpty else { return nil }
        return (String(host), port)
    }
}
