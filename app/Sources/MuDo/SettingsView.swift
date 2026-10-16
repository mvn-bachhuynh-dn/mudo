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
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "MuDo Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var link = ""
    @State private var linkError = false
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
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onChange(of: settings.staleMinutes) { model.applySettings() }
        .onChange(of: settings.snoozeMinutes) { model.applySettings() }
        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
    }

    private func addLink() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              model.handle(url: url) else {
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
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name)
            TextField("Daemon URL", text: $daemon, prompt: Text("http://100.x.y.z:7879"))
            TextField("code-server URL", text: $codeServer, prompt: Text("http://100.x.y.z:8080"))
            SecureField("Token", text: $token)
            HStack {
                if invalid {
                    Text("Daemon URL must be http(s)://host:port").font(.caption).foregroundStyle(.red)
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
    }

    private func load() {
        name = server.name
        daemon = server.daemonURL.absoluteString
        codeServer = server.codeServerURL?.absoluteString ?? ""
        token = model.settings.token(for: server.id)
    }

    private func save() {
        guard let daemonURL = AddLink.httpURL(daemon) else {
            invalid = true
            return
        }
        invalid = false
        var updated = server
        updated.name = name.isEmpty ? server.name : name
        updated.daemonURL = daemonURL
        updated.codeServerURL = AddLink.httpURL(codeServer)
        model.settings.update(updated, token: token)
        model.applySettings()
    }
}
