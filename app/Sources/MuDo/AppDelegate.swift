import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var panel: PanelController?
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        model = AppModel(settings: AppSettings())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let panel = PanelController(model: model)
        panel.show()
        self.panel = panel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "MuDo")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model?.handle(url: url) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paused = model?.store.isPaused ?? false
        let pause = menu.addItem(withTitle: paused ? "Resume blinking" : "Pause blinking (1 h)",
                                 action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MuDo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func togglePause() {
        model?.togglePause()
    }
}
