import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var panel: PanelController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let model = AppModel(settings: AppSettings())
        self.model = model
        settingsWindow = SettingsWindowController(model: model)
        model.onNeedsCodeServer = { [weak self] in self?.settingsWindow?.show() }
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

        if model.settings.servers.isEmpty { settingsWindow?.show() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var added = false
        for url in urls where model?.handle(url: url) == .added { added = true }
        if added { settingsWindow?.show() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let paused = model?.store.isPaused ?? false
        let pause = menu.addItem(withTitle: paused ? "Resume blinking" : "Pause blinking (1 h)",
                                 action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        if model?.automationDenied == true {
            let hint = menu.addItem(withTitle: "Allow MuDo to control Chrome…",
                                    action: #selector(openAutomationSettings), keyEquivalent: "")
            hint.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MuDo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    @objc private func togglePause() {
        model?.togglePause()
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
