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

    var body: some View {
        @Bindable var settings = model.settings
        Form {
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
            Section("Alerts") {
                Stepper("Blink after \(settings.staleMinutes) min", value: $settings.staleMinutes, in: 1...120)
                Stepper("Snooze for \(settings.snoozeMinutes) min", value: $settings.snoozeMinutes, in: 1...240)
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
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 460, idealHeight: 560)
        .onChange(of: settings.staleMinutes) { model.applySettings() }
        .onChange(of: settings.snoozeMinutes) { model.applySettings() }
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
                Button("Remove", role: .destructive) {
                    model.settings.remove(server.id)
                    model.applySettings()
                }
                Button("Save") { save() }
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
        updated.daemonURL = daemonURL
        updated.codeServerURL = codeServerURL
        let keepStoredToken = tokenUnreadable && token.isEmpty
        model.settings.update(updated, token: keepStoredToken ? nil : token)
        if !keepStoredToken { tokenUnreadable = false }
        model.applySettings()
    }
}
