import AppKit
import MuDoCore
import os

/// Focuses terminals, editors and ssh tabs on this Mac (spec 5.4, 5.5).
/// Focus never opens windows or tabs: every failed step logs and activates an app instead.
@MainActor
final class LocalFocuser {
    private static let log = Logger(subsystem: "dev.steve.MuDo", category: "focus")
    private static let terminalBundleIDs = ["com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty"]

    /// What the focus steps need from the session, beyond the process tree.
    private struct Target {
        /// Stale inside tmux and meaningless for ssh: nil there.
        var itermSession: String?
        var tmuxBin: String?
        var program: String?
        var cwd: String
        var project: String
        /// ssh sessions: cwd is on the server, and the fallback is the frontmost terminal.
        var remote: Bool
    }

    private var inFlight = false

    func focus(_ plan: FocusPlan) {
        guard !inFlight else {
            Self.log.info("local focus ignored (already in flight)")
            return
        }
        switch plan {
        case let .local(t, cwd, project):
            inFlight = true
            Self.log.info("local focus cwd=\(cwd, privacy: .public) tty=\(t?.tty ?? "-", privacy: .public) pane=\(t?.tmuxPane ?? "-", privacy: .public)")
            Task {
                defer { inFlight = false }
                await focusLocal(t, cwd: cwd, project: project)
            }
        case let .ssh(t, cwd, project):
            inFlight = true
            Self.log.info("ssh focus cwd=\(cwd, privacy: .public) server=\(t.sshServerIp ?? "-", privacy: .public):\(t.sshServerPort ?? 0, privacy: .public) client port=\(t.sshClientPort ?? 0, privacy: .public)")
            Task {
                defer { inFlight = false }
                await focusSSH(t, cwd: cwd, project: project)
            }
        case .chrome, .none:
            return
        }
    }

    // MARK: - Plans

    private func focusLocal(_ t: TerminalInfo?, cwd: String, project: String) async {
        var target = Target(itermSession: t?.itermSession, tmuxBin: t?.tmuxBin, program: t?.program,
                            cwd: cwd, project: project, remote: false)
        if let pane = t?.tmuxPane {
            guard let client = await tmuxStep(pane: pane, socket: t?.tmuxSocket, target: target) else {
                fallback(target, step: "tmux pane \(pane)")
                return
            }
            guard let table = await processTable() else {
                fallback(target, step: "ps")
                return
            }
            target.itermSession = nil
            await focus(tty: client, table: table, target: target, fromTmux: true)
            return
        }
        guard let tty = t?.tty else {
            fallback(target, step: "no tty")
            return
        }
        guard let table = await processTable() else {
            fallback(target, step: "ps")
            return
        }
        await focus(tty: tty, table: table, target: target, fromTmux: false)
    }

    private func focusSSH(_ t: TerminalInfo, cwd: String, project: String) async {
        let target = Target(cwd: cwd, project: project, remote: true)
        guard let table = await processTable() else {
            fallback(target, step: "ps")
            return
        }
        guard let conn = await sshClient(t, table: table, step: { fallback(target, step: $0) }) else { return }
        Self.log.info("ssh pid=\(conn.pid, privacy: .public) local port=\(conn.localPort, privacy: .public)")
        await focus(pid: conn.pid, table: table, target: target, fromTmux: false)
    }

    // MARK: - Place (no side effects)

    /// Where the session of `plan` is shown, for auto-ack. Mirrors the focus steps but never selects,
    /// raises or activates anything.
    func place(for plan: FocusPlan) async -> SessionPlace? {
        switch plan {
        case let .chrome(cs, cwd, project):
            return .chrome(codeServer: cs, cwd: cwd, project: project)
        case let .local(t, cwd, project):
            guard let t else { return nil }
            if let pane = t.tmuxPane { return .tmux(pane: pane, socket: t.tmuxSocket) }
            guard let tty = t.tty, let table = await processTable(),
                  let proc = Self.firstNonTmux(onTTY: tty, table: table) else { return nil }
            let target = Target(tmuxBin: t.tmuxBin, program: t.program, cwd: cwd, project: project, remote: false)
            return await place(pid: proc.pid, table: table, target: target)
        case let .ssh(t, cwd, project):
            guard let table = await processTable(),
                  let conn = await sshClient(t, table: table, step: { Self.log.info("place: \($0, privacy: .public)") })
            else { return nil }
            let target = Target(cwd: cwd, project: project, remote: true)
            return await place(pid: conn.pid, table: table, target: target)
        case .none:
            return nil
        }
    }

    private func place(pid: Int, table: ProcessTable, target: Target) async -> SessionPlace? {
        switch table.owner(of: pid) {
        case .tmux?:
            guard let tty = table.process(pid)?.tty, let hit = await tmuxPane(onTTY: tty, target: target) else { return nil }
            return .tmux(pane: hit.pane, socket: hit.socket)
        case let .app(app)?:
            let titles = AutoAck.editorTitles(cwd: target.cwd, project: target.project, home: NSHomeDirectory(),
                                              remote: target.remote)
            return AutoAck.place(app: app, outerTTY: table.outerTTY(of: pid), editorTitles: titles)
        case nil:
            return nil
        }
    }

    // MARK: - Steps

    /// Spec 5.4 step 2 from a tty: a process on it, skipping tmux clients so the walk finds the terminal.
    private func focus(tty: String, table: ProcessTable, target: Target, fromTmux: Bool) async {
        guard let proc = Self.firstNonTmux(onTTY: tty, table: table) else {
            fallback(target, step: "no process on \(tty)")
            return
        }
        await focus(pid: proc.pid, table: table, target: target, fromTmux: fromTmux)
    }

    private func focus(pid: Int, table: ProcessTable, target: Target, fromTmux: Bool) async {
        switch table.owner(of: pid) {
        case .tmux?:
            // e.g. an ssh inside local tmux: find its pane and run the tmux step for it.
            guard !fromTmux, let tty = table.process(pid)?.tty else {
                fallback(target, step: "nested tmux")
                return
            }
            guard let hit = await tmuxPane(onTTY: tty, target: target) else {
                fallback(target, step: "tmux pane for \(tty)")
                return
            }
            guard let client = await tmuxStep(pane: hit.pane, socket: hit.socket, target: target) else {
                fallback(target, step: "tmux pane \(hit.pane)")
                return
            }
            var target = target
            target.itermSession = nil
            await focus(tty: client, table: table, target: target, fromTmux: true)
        case let .app(app)?:
            await focus(app: app, outer: table.outerTTY(of: pid), target: target, fromTmux: fromTmux)
        case nil:
            fallback(target, step: "no app above pid \(pid)")
        }
    }

    /// Spec 5.4 step 1: selects the pane's window and pane, returns the tty of its most recent client.
    /// Never `switch-client`: that would hijack a client attached to another session.
    private func tmuxStep(pane: String, socket: String?, target: Target) async -> String? {
        guard let bin = tmuxBinary(target) else {
            Self.log.info("tmux binary not found")
            return nil
        }
        if let socket, !Self.socketAllowed(socket) {
            Self.log.info("tmux socket not owned by this user: \(socket, privacy: .public)")
            return nil
        }
        let base = socket.map { ["-S", $0] } ?? []
        guard let session = await Self.runTool(bin, base + ["display", "-p", "-t", pane, "#{session_name}"])?
            .trimmingCharacters(in: .newlines), !session.isEmpty else {
            Self.log.info("tmux display failed pane=\(pane, privacy: .public)")
            return nil
        }
        _ = await Self.runTool(bin, base + ["select-window", "-t", pane])
        _ = await Self.runTool(bin, base + ["select-pane", "-t", pane])
        let clients = await Self.runTool(bin, base + ["list-clients", "-F", "#{client_activity} #{client_session} #{client_tty}"]) ?? ""
        guard let tty = TmuxPick.client(listClients: clients, session: session) else {
            Self.log.info("tmux session \(session, privacy: .public) has no client")
            return nil
        }
        Self.log.info("tmux pane=\(pane, privacy: .public) session=\(session, privacy: .public) client=\(tty, privacy: .public)")
        return tty
    }

    /// Spec 5.4 step 3.
    private func focus(app: TerminalApp, outer: String?, target: Target, fromTmux: Bool) async {
        switch app {
        case .iTerm2:
            let sessionID = fromTmux ? nil : target.itermSession
            if await runBool(TerminalScripts.iTerm(sessionID: sessionID, tty: outer), step: "iTerm2") { return }
        case .terminal:
            if let outer, await runBool(TerminalScripts.terminalApp(tty: outer), step: "Terminal") { return }
        case .ghostty:
            if let outer, await runBool(TerminalScripts.ghosttyByTTY(outer), step: "Ghostty tty") { return }
            if !fromTmux, !target.remote, let id = await ghosttyByCWD(target.cwd),
               await runBool(TerminalScripts.ghosttyFocus(id: id), step: "Ghostty focus") { return }
        case let .vscodeLike(bundlePath):
            let titles = FocusHints.titleCandidates(cwd: target.cwd, project: target.project, home: NSHomeDirectory())
            let script = TerminalScripts.raiseWindow(appName: Self.processName(bundlePath), titleContains: titles)
            if await runBool(script, step: "editor window") { return }
        case .other:
            break
        }
        activate(app)
    }

    /// Ghostty before 1.4 has no `tty`: match `working directory`, only when exactly one terminal matches.
    private func ghosttyByCWD(_ cwd: String) async -> String? {
        guard case let .ok(terms) = await AppleScriptRunner.run(TerminalScripts.ghosttyList(), parse: Self.parseGhosttyList) else {
            Self.log.info("Ghostty list failed")
            return nil
        }
        let want = Self.realPath(cwd)
        let hits = terms.filter { Self.realPath($0.cwd) == want }
        guard hits.count == 1 else {
            Self.log.info("Ghostty cwd matches=\(hits.count, privacy: .public) of \(terms.count, privacy: .public)")
            return nil
        }
        return hits[0].id
    }

    private func runBool(_ source: String, step: String) async -> Bool {
        switch await AppleScriptRunner.run(source, parse: { $0.booleanValue }) {
        case .ok(true):
            Self.log.info("focused via \(step, privacy: .public)")
            return true
        case .ok(false):
            Self.log.info("\(step, privacy: .public): no match")
        case .denied:
            Self.log.info("\(step, privacy: .public): automation denied")
        case .failed:
            Self.log.info("\(step, privacy: .public): script failed")
        }
        return false
    }

    // MARK: - Activation

    private func fallback(_ target: Target, step: String) {
        Self.log.info("\(step, privacy: .public) failed -> activate")
        if target.remote {
            activateFrontmostTerminal()
        } else if let id = FocusHints.bundleID(program: target.program) {
            activate(bundleID: id)
        } else {
            Self.log.info("no app to activate for program=\(target.program ?? "-", privacy: .public)")
        }
    }

    private func activate(_ app: TerminalApp) {
        switch app {
        case .iTerm2: activate(bundleID: "com.googlecode.iterm2")
        case .terminal: activate(bundleID: "com.apple.Terminal")
        case .ghostty: activate(bundleID: "com.mitchellh.ghostty")
        case let .vscodeLike(path), let .other(path):
            guard let running = Self.running(bundlePath: path) else {
                Self.log.info("not running: \(path, privacy: .public)")
                return
            }
            _ = running.activate()
        }
    }

    private func activate(bundleID: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            Self.log.info("not running: \(bundleID, privacy: .public)")
            return
        }
        _ = running.activate()
    }

    /// Spec 5.5 step 6: the running terminal app with the frontmost on-screen window.
    private func activateFrontmostTerminal() {
        let running = Self.terminalBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let first = running.first else {
            Self.log.info("no terminal app running")
            return
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let front = windows.lazy
            .compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
            .compactMap { pid in running.first { $0.processIdentifier == pid } }
            .first
        _ = (front ?? first).activate()
    }

    // MARK: - Helpers

    private func processTable() async -> ProcessTable? {
        guard let out = await Self.runTool("/bin/ps", ["-A", "-o", "pid=,ppid=,tty=,comm="]) else { return nil }
        return ProcessTable(psOutput: out)
    }

    /// A process on `tty` that is not a tmux client, so the walk up finds the terminal.
    private static func firstNonTmux(onTTY tty: String, table: ProcessTable) -> ProcInfo? {
        table.processes(onTTY: tty).first { ($0.comm as NSString).lastPathComponent != "tmux" }
    }

    /// Spec 5.5: the local ssh client behind `t`, from lsof; `step` gets the reason when none matches.
    private func sshClient(_ t: TerminalInfo, table: ProcessTable, step: (String) -> Void) async -> SSHConn? {
        let lsof = await Self.runTool("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pcn"]) ?? ""
        let conns = LsofSSH.parse(lsof)
        var commandLines: [Int: String] = [:]
        for pid in Set(conns.map(\.pid)) {
            commandLines[pid] = await Self.runTool("/bin/ps", ["-o", "command=", "-p", String(pid)])
        }
        let commands = commandLines
        let discarded: (Int) -> Bool = { pid in
            SSHPick.discard(pid: pid, table: table, commandLine: commands[pid])
        }
        guard let conn = SSHPick.choose(conns: conns, terminal: t, isMux: discarded) else {
            step("no ssh match among \(conns.count) connections")
            return nil
        }
        return conn
    }

    /// The local tmux pane running on `tty` (e.g. an ssh inside local tmux), from `list-panes`.
    private func tmuxPane(onTTY tty: String, target: Target) async -> (pane: String, socket: String)? {
        guard let bin = tmuxBinary(target),
              let panes = await Self.runTool(bin, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id} #{socket_path}"])
        else { return nil }
        return TmuxPick.pane(listPanes: panes, tty: tty)
    }

    /// Only well-known installs run; the recorded path just picks among them.
    private func tmuxBinary(_ target: Target) -> String? {
        TmuxPick.resolveBinary(recorded: target.tmuxBin, exists: { FileManager.default.isExecutableFile(atPath: $0) },
                               home: NSHomeDirectory())
    }

    /// The socket path must belong to this user before tmux gets `-S` with it.
    static func socketAllowed(_ path: String) -> Bool {
        let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber
        return TmuxPick.socketAllowed(path: path, owner: owner?.uint32Value, currentUID: getuid())
    }

    /// Runs `path` with `args` (no shell) off the main actor; stdout, or nil on failure or after 2 s.
    nonisolated static func runTool(_ path: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runToolSync(path, args))
            }
        }
    }

    private nonisolated static func runToolSync(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let box = ProcessBox(process)
        let timeout = DispatchWorkItem {
            if box.process.isRunning { box.process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    struct GhosttyTerminal: Sendable {
        var id: String
        var cwd: String
    }

    /// Each item is {id, working directory}.
    nonisolated static func parseGhosttyList(_ list: NSAppleEventDescriptor) -> [GhosttyTerminal] {
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { i in
            guard let item = list.atIndex(i), item.numberOfItems == 2,
                  let id = item.atIndex(1)?.stringValue, let cwd = item.atIndex(2)?.stringValue else { return nil }
            return GhosttyTerminal(id: id, cwd: cwd)
        }
    }

    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            var p = Substring(path)
            while p.count > 1, p.hasSuffix("/") { p = p.dropLast() }
            return String(p)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The System Events process name: the running app's name ("Code" for VS Code), else the bundle name.
    static func processName(_ bundlePath: String) -> String {
        if let name = running(bundlePath: bundlePath)?.localizedName { return name }
        let file = (bundlePath as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    private static func running(bundlePath: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundlePath }
    }
}
