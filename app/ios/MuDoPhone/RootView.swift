import SwiftUI

struct RootView: View {
    let model: PhoneModel
    let cswap: PhoneCswap
    @State private var tab = "sessions"

    var body: some View {
        TabView(selection: $tab) {
            SessionsView(model: model).tag("sessions")
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
            if !cswap.sources.isEmpty {
                AccountsView(cswap: cswap).tag("accounts")
                    .tabItem { Label("Accounts", systemImage: "person.2") }
            }
            ServersView(model: model).tag("servers")
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .onAppear { if model.servers.isEmpty { tab = "servers" } }
    }
}
