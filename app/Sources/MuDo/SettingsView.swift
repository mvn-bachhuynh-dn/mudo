import AppKit
import MuDoCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            // A grouped Form has almost no intrinsic height, so size the window explicitly.
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "MuDo Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 480, height: 460)
            w.setContentSize(NSSize(width: 480, height: 560))
            // MuDo is an accessory app: keep Settings above other apps' windows.
            w.level = .floating
            w.center()
            window = w
        }
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var link = ""
    @State private var linkError = false
    @State private var ignoredText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var localError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("This Mac") {
                HStack {
                    Toggle("Monitor this Mac", isOn: Binding(
                        get: { model.settings.localServer != nil },
                        set: { on in setMonitorLocal(on) }))
                        .disabled(model.localDaemon.isBusy)
                    if model.localDaemon.isBusy {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Runs the bundled mudod here so local agent sessions show up.")
                    .font(.caption).foregroundStyle(.secondary)
                if let localError {
                    Text(localError).font(.caption.monospaced()).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("Servers") {
                if let keychainError = settings.keychainError {
                    Text(keychainError).font(.caption).foregroundStyle(.red)
                }
                ForEach(settings.servers) { server in
                    ServerEditor(model: model, server: server)
                }
                HStack {
                    TextField("Paste a mudo://add?… link", text: $link)
                    Button("Add") { addLink() }
                }
                if linkError {
                    Text("Not a valid mudo://add link").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Widget") {
                Toggle("Show on all displays", isOn: $settings.showOnAllDisplays)
                Text("One widget per display. Off: a single widget you can move between displays.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Move aside when the pointer arrives", isOn: $settings.dodgeOnHover)
                Stepper("Reach it again within \(settings.dodgeWindowMs) ms to use it",
                        value: $settings.dodgeWindowMs, in: 200...2000, step: 100)
                    .disabled(!settings.dodgeOnHover)
                Text("The collapsed widget slides aside so you can click what is under it. Reach it again quickly to open it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerts") {
                Stepper("Blink after \(settings.staleMinutes) min", value: $settings.staleMinutes, in: 1...120)
                Stepper("Snooze for \(settings.snoozeMinutes) min", value: $settings.snoozeMinutes, in: 1...240)
                Toggle("Auto-acknowledge when already in view", isOn: $settings.autoAckInView)
                Text("A finished session you are already looking at is marked seen without a click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Slack") {
                TextField("Workspace ID", text: $settings.slackTeamID, prompt: Text("T0123456789"))
                Text("Used when a KiroCrew session does not carry its own. Opens the Slack app, or Slack web in Chrome. Empty: through slack.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hidden sessions") {
                TextEditor(text: $ignoredText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70)
                Text("Sessions whose folder matches are hidden. * matches anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Check for updates", isOn: $settings.checkForUpdates)
            } footer: {
                Text("MuDo \(model.updater.current)" + (model.updater.notice.map { " · \($0) available" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 460, idealHeight: 560)
        .onChange(of: settings.staleMinutes) { model.applySettings() }
        .onChange(of: settings.snoozeMinutes) { model.applySettings() }
        .onChange(of: settings.showOnAllDisplays) { model.onPanelLayoutChange?() }
        .onChange(of: settings.dodgeOnHover) { model.onDodgeSettingChange?() }
        .onAppear { ignoredText = settings.ignoredPaths.joined(separator: "\n") }
        .onChange(of: ignoredText) { _, text in
            settings.ignoredPaths = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            model.applySettings()
        }
        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
    }

    private func addLink() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              model.handle(url: url) == .added else {
            linkError = true
            return
        }
        linkError = false
        link = ""
    }

    /// On installs the bundled mudod and adds its server; off uninstalls it and removes the server.
    private func setMonitorLocal(_ on: Bool) {
        guard !model.localDaemon.isBusy else { return }
        localError = nil
        Task {
            if on {
                switch await model.localDaemon.enable() {
                case let .success(draft):
                    model.settings.add(draft, managedLocal: true)
                    model.applySettings()
                case let .failure(error):
                    localError = error.output.isEmpty ? "mudod install failed" : error.output
                }
            } else {
                switch await model.localDaemon.disable() {
                case .success:
                    if let local = model.settings.localServer {
                        model.settings.remove(local.id)
                        model.applySettings()
                    }
                case let .failure(error):
                    localError = error.output.isEmpty ? "mudod uninstall failed" : error.output
                }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Edits one server. Changes apply on Save so typing does not reconnect on every key.
struct ServerEditor: View {
    let model: AppModel
    let server: ServerConfig
    @State private var name = ""
    @State private var daemon = ""
    @State private var codeServer = ""
    @State private var token = ""
    @State private var error: String?
    /// The stored token could not be read; an empty field then means "keep the stored token".
    @State private var tokenUnreadable = false
    @State private var testing = false
    /// Result lines of the last Test, and whether the daemon check passed.
    @State private var testResult: (lines: [String], ok: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name)
            TextField("Daemon URL", text: $daemon, prompt: Text("http://100.x.y.z:7879"))
            TextField("code-server URL", text: $codeServer, prompt: Text("http://100.x.y.z:8080"))
            SecureField("Token", text: $token,
                        prompt: tokenUnreadable ? Text("Unreadable — type a new token to replace it") : nil)
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Test") { test() }.disabled(testing)
                Button("Remove", role: .destructive) {
                    model.settings.remove(server.id)
                    model.applySettings()
                }
                Button("Save") { save() }
            }
            if let testResult {
                Text(testResult.lines.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(testResult.ok ? .green : .red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: load)
        .onChange(of: server) { load() }
    }

    private func load() {
        name = server.name
        daemon = server.daemonURL.absoluteString
        codeServer = server.codeServerURL?.absoluteString ?? ""
        let stored = model.settings.reloadToken(for: server.id)
        tokenUnreadable = stored == nil
        token = stored ?? ""
        error = nil
        testResult = nil
    }

    /// Checks the values in the fields, saved or not: the daemon's health with the token,
    /// and that the code-server URL answers.
    private func test() {
        guard let daemonURL = AddLink.httpURL(daemon) else {
            error = "Daemon URL must be http(s)://host:port"
            return
        }
        let codeServerText = codeServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeServerURL = codeServerText.isEmpty ? nil : AddLink.httpURL(codeServerText)
        if !codeServerText.isEmpty, codeServerURL == nil {
            error = "code-server URL must be http(s)://host[:port]"
            return
        }
        error = nil
        testing = true
        testResult = nil
        let token = token
        Task {
            let api = APIClient()
            async let d = api.health(daemon: daemonURL, token: token)
            async let c = api.probe(codeServer: codeServerURL)
            let (daemonResult, codeResult) = await (d, c)
            var lines = [ServerCheck.message(daemonResult)]
            if let line = ServerCheck.message(codeResult) { lines.append(line) }
            var ok = ServerCheck.isOK(daemonResult)
            if case .unreachable = codeResult { ok = false }
            testResult = (lines, ok)
            testing = false
        }
    }

    private func save() {
        guard let daemonURL = AddLink.httpURL(daemon) else {
            error = "Daemon URL must be http(s)://host:port"
            return
        }
        let codeServerText = codeServer.trimmingCharacters(in: .whitespacesAndNewlines)
        var codeServerURL: URL?
        if !codeServerText.isEmpty {
            guard let url = AddLink.httpURL(codeServerText) else {
                error = "code-server URL must be http(s)://host[:port]"
                return
            }
            codeServerURL = url
        }
        error = nil
        var updated = server
        updated.name = name.isEmpty ? server.name : name
        // Pointing the managed local server elsewhere makes it an ordinary server,
        // so "Monitor this Mac" Off never uninstalls on behalf of a remote one.
        if daemonURL != server.daemonURL { updated.managedLocal = false }
        updated.daemonURL = daemonURL
        updated.codeServerURL = codeServerURL
        let keepStoredToken = tokenUnreadable && token.isEmpty
        model.settings.update(updated, token: keepStoredToken ? nil : token)
        if !keepStoredToken { tokenUnreadable = false }
        model.applySettings()
    }
}
