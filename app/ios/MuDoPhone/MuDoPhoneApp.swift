import SwiftUI

@main
struct MuDoPhoneApp: App {
    @State private var model: PhoneModel
    @State private var cswap: PhoneCswap
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let m = PhoneModel()
        _model = State(initialValue: m)
        _cswap = State(initialValue: PhoneCswap(servers: { m.cswapServers }))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, cswap: cswap)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // .inactive (Notification Center, app switcher) keeps the connections.
                    if phase == .active {
                        model.setActive(true)
                        Task { await cswap.refresh() }
                    } else if phase == .background {
                        model.setActive(false)
                    }
                }
        }
    }
}
