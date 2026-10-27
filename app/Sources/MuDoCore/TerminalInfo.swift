import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where an agent runs, as captured by its hook (spec 4.1). Untrusted: call `validated()` before use.
public struct TerminalInfo: Codable, Equatable, Sendable {
    public var program: String?
    public var codeServer: Bool?
    public var tty: String?
    public var itermSession: String?
    public var tmuxSocket: String?
    public var tmuxPane: String?
    public var tmuxBin: String?
    public var sshClientIp: String?
    public var sshClientPort: Int?
    public var sshServerIp: String?
    public var sshServerPort: Int?
    /// KiroCrew's Slack channel ID, when the agent was spawned from Slack.
    public var slackChannel: String?
    /// Its Slack workspace ID, when KiroCrew passes it.
    public var slackTeam: String?
    /// The Slack thread (message ts) the KiroCrew bot answers in.
    public var slackThread: String?

    public init(program: String? = nil, codeServer: Bool? = nil, tty: String? = nil,
                itermSession: String? = nil, tmuxSocket: String? = nil, tmuxPane: String? = nil,
                tmuxBin: String? = nil, sshClientIp: String? = nil, sshClientPort: Int? = nil,
                sshServerIp: String? = nil, sshServerPort: Int? = nil, slackChannel: String? = nil, slackTeam: String? = nil,
                slackThread: String? = nil) {
        self.program = program
        self.codeServer = codeServer
        self.tty = tty
        self.itermSession = itermSession
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.tmuxBin = tmuxBin
        self.sshClientIp = sshClientIp
        self.sshClientPort = sshClientPort
        self.sshServerIp = sshServerIp
        self.sshServerPort = sshServerPort
        self.slackChannel = slackChannel
        self.slackTeam = slackTeam
        self.slackThread = slackThread
    }

    /// Drops fields that fail spec 5.1's validation.
    public func validated() -> TerminalInfo {
        var t = self
        t.tty = keep(tty) { Self.matches($0, prefix: "/dev/ttys", rest: Self.digits) }
        t.tmuxPane = keep(tmuxPane) { Self.matches($0, prefix: "%", rest: Self.digits) }
        t.itermSession = keep(itermSession) { $0.count == 36 && $0.allSatisfy { $0.isHexDigit || $0 == "-" } }
        t.tmuxSocket = keep(tmuxSocket, Self.safePath)
        t.tmuxBin = keep(tmuxBin, Self.safePath)
        t.sshClientIp = keep(sshClientIp, Self.isIP)
        t.sshServerIp = keep(sshServerIp, Self.isIP)
        t.sshClientPort = keep(sshClientPort, Self.isPort)
        t.sshServerPort = keep(sshServerPort, Self.isPort)
        t.slackChannel = keep(slackChannel, SlackLink.isChannel)
        t.slackTeam = keep(slackTeam, SlackLink.isTeam)
        t.slackThread = keep(slackThread, SlackLink.isThread)
        return t
    }

    private func keep<T>(_ value: T?, _ ok: (T) -> Bool) -> T? {
        value.flatMap { ok($0) ? $0 : nil }
    }

    static func digits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func matches(_ s: String, prefix: String, rest: (Substring) -> Bool) -> Bool {
        s.hasPrefix(prefix) && rest(s.dropFirst(prefix.count))
    }

    /// Absolute, no `..` component, no control characters.
    static func safePath(_ p: String) -> Bool {
        p.hasPrefix("/") && !p.split(separator: "/").contains("..")
            && !p.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func isPort(_ p: Int) -> Bool { (1...65535).contains(p) }

    static func isIP(_ s: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}
