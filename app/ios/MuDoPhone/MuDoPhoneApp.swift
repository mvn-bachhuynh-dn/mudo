import SwiftUI
import WidgetKit

@main
struct MuDoPhoneApp: App {
    @State private var model: PhoneModel
    @State private var cswap: PhoneCswap
    @State private var widgetTask: Task<Void, Never>?
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
                        WidgetCenter.shared.reloadAllTimelines()
                        startWidgetReloads()
                    } else {
                        widgetTask?.cancel()
                        widgetTask = nil
                        if phase == .background {
                            model.setActive(false)
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                    }
                }
        }
    }

    /// While the app is in the foreground, reload the widgets about every minute.
    private func startWidgetReloads() {
        widgetTask?.cancel()
        widgetTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
