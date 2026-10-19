import AppKit
import CoreGraphics
import MuDoCore
import os

/// Reads what is in front of the user, for auto-ack. Only scripts the app that is already frontmost
/// (a `tell` to an app that is not running would launch it) and never focuses anything.
@MainActor
final class InViewProbe {
    private static let log = Logger(subsystem: "dev.steve.MuDo", category: "autoack")
    /// Bundle ids whose script was denied or failed, so each is logged once per launch.
    private static var logged: Set<String> = []

    /// The front tab, terminal session or editor window; nil for other apps or when a script fails.
    /// `tmuxSockets` are the servers to ask for the active pane (nil = the default socket).
    func frontView(tmuxSockets: [String?]) async -> FrontView? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let id = app.bundleIdentifier ?? ""
        switch id {
        case ChromeTabFocuser.chromeBundleID:
            guard let items = await run(ChromeScripts.activeTab, id: id, parse: Self.strings) else { return nil }
            return AutoAck.chromeFront(items)
        case "com.googlecode.iterm2", "com.apple.Terminal":
            let script = id == "com.apple.Terminal" ? TerminalScripts.terminalAppFrontTTY : TerminalScripts.iTermFrontTTY
            guard let tty = await run(script, id: id, parse: { $0.stringValue ?? "" }), !tty.isEmpty else { return nil }
            return .terminal(tty: tty, tmuxPane: await activePane(clientTTY: tty, sockets: tmuxSockets))
        default:
            guard let path = app.bundleURL?.path, case .vscodeLike = ProcessTable.classify(path) else { return nil }
            let script = TerminalScripts.frontWindowTitle(appName: LocalFocuser.processName(path))
            guard let title = await run(script, id: id, parse: { $0.stringValue ?? "" }) else { return nil }
            return .editor(title: title)
        }
    }

    /// Recent mouse or keyboard input and an unlocked screen.
    func userPresent() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return AutoAck.userPresent(idleSeconds: idle, screenLocked: locked)
    }

    /// The active pane of the tmux client attached on `clientTTY`; the first server that answers wins.
    private func activePane(clientTTY: String, sockets: [String?]) async -> String? {
        guard !sockets.isEmpty,
              let bin = TmuxPick.resolveBinary(recorded: nil, exists: { FileManager.default.isExecutableFile(atPath: $0) },
                                               home: NSHomeDirectory()) else { return nil }
        for socket in sockets {
            if let socket, !LocalFocuser.socketAllowed(socket) { continue }
            let base = socket.map { ["-S", $0] } ?? []
            guard let out = await LocalFocuser.runTool(bin, base + ["display", "-p", "-c", clientTTY, "#{pane_id}"]) else {
                continue
            }
            let pane = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pane.isEmpty { return pane }
        }
        return nil
    }

    /// `.denied` and `.failed` are nil ("not in view" this tick), logged once per app.
    private func run<T: Sendable>(_ source: String, id: String,
                                  parse: @escaping @Sendable (NSAppleEventDescriptor) -> T) async -> T? {
        switch await AppleScriptRunner.run(source, parse: parse) {
        case let .ok(value):
            return value
        case .denied:
            logOnce(id, "automation denied")
        case .failed:
            logOnce(id, "script failed")
        }
        return nil
    }

    private func logOnce(_ id: String, _ what: String) {
        guard Self.logged.insert(id).inserted else { return }
        Self.log.info("in-view probe \(id, privacy: .public): \(what, privacy: .public)")
    }

    nonisolated static func strings(_ list: NSAppleEventDescriptor) -> [String] {
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).map { list.atIndex($0)?.stringValue ?? "" }
    }
}
