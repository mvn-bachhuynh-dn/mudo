import MuDoCore
import SwiftUI
import UIKit

struct ServersView: View {
    @Bindable var model: PhoneModel
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.store.servers.isEmpty {
                    Text("Add a server: paste a mudo://add link from `mudod install`, or fill in the address and token. The iPhone must be on the same Tailscale network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.store.servers) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(model.servers.first { $0.id == row.id }?.daemonURL.absoluteString ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.label(row.status)).font(.caption)
                            .foregroundStyle(row.status == .connected ? .green : .secondary)
                    }
                }
                .onDelete { offsets in
                    let rows = model.store.servers
                    for i in offsets { model.remove(rows[i].id) }
                }
            }
            .navigationTitle("Servers")
            .toolbar { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showingAdd) { AddServerView(model: model) }
            .onChange(of: model.pendingDraft != nil) { _, has in if has { showingAdd = false } }
            .sheet(item: $model.pendingDraft) { draft in AddServerView(model: model, draft: draft) }
        }
    }

    private static func label(_ s: ConnectionStatus) -> String {
        switch s {
        case .connecting: "connecting"
        case .connected: "online"
        case .offline: "offline"
        case .unauthorized: "token invalid"
        }
    }
}

extension ServerDraft: @retroactive Identifiable {
    public var id: String { "\(name)|\(daemonURL.absoluteString)" }
}

struct AddServerView: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var token: String
    @State private var error: String?

    init(model: PhoneModel, draft: ServerDraft? = nil) {
        self.model = model
        _name = State(initialValue: draft?.name ?? "")
        _url = State(initialValue: draft?.daemonURL.absoluteString ?? "")
        _token = State(initialValue: draft?.token ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Paste mudo://add link") {
                        guard let text = UIPasteboard.general.string, let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                              let d = AddLink.parse(u) else { error = "The clipboard has no mudo://add link"; return }
                        name = d.name; url = d.daemonURL.absoluteString; token = d.token; error = nil
                    }
                }
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("http://100.64.0.10:7879", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    // A server token is not a password: oneTimeCode keeps iOS from offering to save it.
                    SecureField("Token", text: $token)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let daemon = AddLink.httpURL(url) else { error = "Enter a valid http(s) address"; return }
                        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { error = "The token is empty"; return }
                        let host = URLComponents(url: daemon, resolvingAgainstBaseURL: false)?.host ?? "server"
                        if model.add(ServerDraft(name: name.isEmpty ? host : name, daemonURL: daemon, token: trimmed, codeServerURL: nil)) {
                            dismiss()
                        } else {
                            error = "Could not save the token to the Keychain"
                        }
                    }
                }
            }
        }
    }
}
