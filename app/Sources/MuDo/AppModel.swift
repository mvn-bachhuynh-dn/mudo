import AppKit
import MuDoCore
import Network
import Observation
import os

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let store = SessionStore()
    let localDaemon = LocalDaemon()
    private(set) var automationDenied = false
    /// Called when a clicked session's server has no code-server URL to focus.
    @ObservationIgnored var onNeedsCodeServer: (() -> Void)?
    /// Called when the widget layout setting (one per display or a single one) changes.
    @ObservationIgnored var onPanelLayoutChange: (() -> Void)?

    @ObservationIgnored private let focuser = ChromeTabFocuser()
    @ObservationIgnored private let localFocuser = LocalFocuser()
    @ObservationIgnored private let probe = InViewProbe()
    /// Sessions acknowledged because they were in view; dropped once no longer `done`.
    @ObservationIgnored private var autoAcked: Set<SessionKey> = []
    @ObservationIgnored private var places = PlaceCache()
    @ObservationIgnored private var autoAckInFlight = false
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private let api = APIClient()
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    @ObservationIgnored private var tokens: [UUID: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var pathSatisfied: Bool?
    private static let linkLog = Logger(subsystem: "dev.steve.MuDo", category: "link")
    private static let streamLog = Logger(subsystem: "dev.steve.MuDo", category: "stream")
    private static let autoAckLog = Logger(subsystem: "dev.steve.MuDo", category: "autoack")

    init(settings: AppSettings) {
        self.settings = settings
        focuser.onAutomationDenied = { [weak self] in self?.automationDenied = true }
        focuser.onAutomationAllowed = { [weak self] in self?.automationDenied = false }
        applySettings()
        startTimer()
        watchWakeAndNetwork()
        // After an app update the bundled mudod may be newer than the installed one.
        Task { [settings, localDaemon] in
            if settings.localServer != nil { await localDaemon.upgradeIfNeeded() }
        }
    }

    /// Pushes settings into the store and (re)builds connections whose config or token changed.
    func applySettings() {
        store.staleAfter = TimeInterval(settings.staleMinutes * 60)
        store.snoozeFor = TimeInterval(settings.snoozeMinutes * 60)
        store.ignoreRules = IgnoreRules(patterns: settings.ignoredPaths)
        store.setServers(settings.servers)
        let wanted = Dictionary(uniqueKeysWithValues: settings.servers.map { ($0.id, $0) })
        // Tokens come from the settings' in-memory cache (the Keychain is read once per server).
        // nil = the Keychain read failed: keep the token we already use instead of reconnecting.
        var current: [UUID: String] = [:]
        for config in settings.servers {
            current[config.id] = settings.token(for: config.id) ?? tokens[config.id] ?? ""
        }
        for (id, connection) in connections {
            if wanted[id] != connection.config || current[id] != tokens[id] {
                connection.stop()
                connections[id] = nil
            }
        }
        for config in settings.servers where connections[config.id] == nil {
            let token = current[config.id] ?? ""
            tokens[config.id] = token
            let name = config.name
            let connection = ServerConnection(
                config: config, token: token, store: store, transport: URLSessionTransport(),
                onAckRetry: { [weak self] keys in self?.retryAcks(keys) },
                onSkip: { event, error in
                    Self.streamLog.error("Skipped \(event, privacy: .public) message from \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                })
            connections[config.id] = connection
            connection.start()
        }
        tokens = tokens.filter { wanted[$0.key] != nil }
    }

    /// Row click (spec 6.2): ack if done, clear snooze, focus per `FocusPlan` (spec 5.2).
    func open(_ row: SessionRow) {
        store.clearSnooze(row.id)
        guard let config = settings.servers.first(where: { $0.id == row.id.serverID }) else { return }
        if row.session.state == .done { ack(row.id, config: config) }
        let plan = FocusPlan.plan(server: config, session: row.session)
        switch plan {
        case let .chrome(codeServer, cwd, project):
            focuser.focus(codeServer: codeServer, cwd: cwd, project: project)
        case .local, .ssh:
            localFocuser.focus(plan)
        case let .slack(channel, team):
            if let url = SlackLink.url(channel: channel, team: team ?? settings.slackTeamID) {
                NSWorkspace.shared.open(url)
            }
        case .none:
            onNeedsCodeServer?()
        }
    }

    func snooze(_ row: SessionRow) {
        store.snooze(row.id)
    }

    func togglePause() {
        if store.isPaused {
            store.resume()
        } else {
            store.pause(for: 3600)
        }
    }

    enum LinkResult: Equatable {
        case added
        case focused
        /// A focus link that matched no session row.
        case focusMissed
        case unhandled
    }

    /// Handles `mudo://add?...` and `mudo://focus?...`.
    @discardableResult
    func handle(url: URL) -> LinkResult {
        if let draft = AddLink.parse(url) {
            settings.add(draft)
            applySettings()
            return .added
        }
        if let target = FocusLink.parse(url) {
            let row = store.rows.first {
                switch target {
                case let .session(id): $0.session.id == id
                case let .project(name): $0.session.project == name
                }
            }
            guard let row else {
                let known = store.rows.map { "\($0.session.project)#\($0.session.id)" }.joined(separator: ", ")
                Self.linkLog.info("focus link matched no row: \(url.absoluteString, privacy: .public); rows: [\(known, privacy: .public)]")
                return .focusMissed
            }
            open(row)
            return .focused
        }
        return .unhandled
    }

    private func ack(_ key: SessionKey, config: ServerConfig) {
        let token = tokens[config.id] ?? ""
        Task {
            let ok = await api.ack(daemon: config.daemonURL, token: token, sessionID: key.sessionID)
            if !ok { store.markAckFailed(key) }
        }
    }

    // MARK: - Auto-ack

    /// Every 2 s: acknowledges `done` sessions whose place is in front of a present user.
    /// With no candidate, nothing is scripted or run.
    private func autoAckTick() {
        let rows = store.rows
        autoAcked = AutoAck.keepDone(autoAcked, rows: rows)
        places.prune(rows: rows)
        guard settings.autoAckInView, !autoAckInFlight else { return }
        let candidates = AutoAck.candidates(rows, alreadyAcked: autoAcked)
        guard !candidates.isEmpty, probe.userPresent() else { return }
        autoAckInFlight = true
        Task { await autoAck(candidates) }
    }

    private func autoAck(_ rows: [SessionRow]) async {
        defer { autoAckInFlight = false }
        let now = Date()
        for row in rows where places.needsResolve(row.id, now: now) {
            guard let config = settings.servers.first(where: { $0.id == row.id.serverID }) else { continue }
            let place = await localFocuser.place(for: FocusPlan.plan(server: config, session: row.session))
            places.set(place, for: row.id, at: now)
        }
        let keys = rows.map(\.id)
        guard keys.contains(where: { places.place($0) != nil }),
              let front = await probe.frontView(tmuxSockets: places.tmuxSockets(for: keys)) else { return }
        for row in rows {
            guard let place = places.place(row.id), AutoAck.isInView(place, front: front) else { continue }
            // The probe awaited: skip a session clicked, changed or turned off meanwhile.
            guard settings.autoAckInView, !autoAcked.contains(row.id), store.session(row.id)?.state == .done,
                  let config = settings.servers.first(where: { $0.id == row.id.serverID }) else { continue }
            store.clearSnooze(row.id)
            ack(row.id, config: config)
            autoAcked.insert(row.id)
            Self.autoAckLog.info("auto-ack \(row.session.project, privacy: .public)")
        }
    }

    private func retryAcks(_ keys: [SessionKey]) {
        for key in keys {
            guard let config = settings.servers.first(where: { $0.id == key.serverID }) else { continue }
            let token = tokens[config.id] ?? ""
            Task { _ = await api.ack(daemon: config.daemonURL, token: token, sessionID: key.sessionID) }
        }
    }

    private func reconnectAll() {
        for connection in connections.values { connection.reconnectNow() }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        store.tick()
        ticks += 1
        if ticks % 2 == 0 { autoAckTick() }
    }

    private func watchWakeAndNetwork() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectAll() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: .main)
    }

    private func networkChanged(satisfied: Bool) {
        defer { pathSatisfied = satisfied }
        // The first callback reports the current state; only react to later changes.
        guard pathSatisfied != nil else { return }
        if satisfied { reconnectAll() }
    }
}
