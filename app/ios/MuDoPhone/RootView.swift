import SwiftUI

struct RootView: View {
    let model: PhoneModel
    @State private var tab = "sessions"

    var body: some View {
        TabView(selection: $tab) {
            Text("Sessions").tag("sessions")
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
            ServersView(model: model).tag("servers")
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .onAppear { if model.servers.isEmpty { tab = "servers" } }
    }
}
