import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var panels: PanelsController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        let model = AppModel(settings: AppSettings())
        self.model = model
        settingsWindow = SettingsWindowController(model: model)
        model.onNeedsCodeServer = { [weak self] in self?.settingsWindow?.show() }
    }

    /// An accessory app shows no menu bar, but text fields only get ⌘X/C/V/A/Z
    /// through key equivalents of the main menu, so install a hidden Edit menu.
    static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let panels = PanelsController(model: model)
        model.onPanelLayoutChange = { [weak panels] in panels?.reload() }
        panels.show()
        self.panels = panels

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
        if let version = model?.updater.notice {
            let update = menu.addItem(withTitle: "Update to MuDo \(version)…",
                                      action: #selector(upgrade), keyEquivalent: "")
            update.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MuDo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    @objc private func upgrade() {
        model?.updater.upgrade()
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
