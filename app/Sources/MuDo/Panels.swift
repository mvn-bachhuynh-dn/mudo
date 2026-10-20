import AppKit
import MuDoCore

extension NSScreen {
    /// Stable key for this display: its UUID, else its decimal display ID.
    var mudoKey: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return String(id)
    }
}

/// One widget per display ("Show on all displays"), or a single free widget when off.
@MainActor
final class PanelsController {
    private let model: AppModel
    private var perScreen: [String: PanelController] = [:]
    private var single: PanelController?

    init(model: AppModel) {
        self.model = model
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func show() {
        reload()
    }

    /// Turning the dodge off sends every panel home.
    func dodgeSettingChanged() {
        single?.dodgeSettingChanged()
        for panel in perScreen.values { panel.dodgeSettingChanged() }
    }

    /// Opens and closes panels to match the setting and the connected displays.
    func reload() {
        guard model.settings.showOnAllDisplays else {
            for panel in perScreen.values { panel.close() }
            perScreen = [:]
            if single == nil {
                let panel = PanelController(model: model)
                single = panel
                panel.show()
            }
            return
        }
        single?.close()
        single = nil
        let diff = PanelScreens.diff(open: Set(perScreen.keys), screens: NSScreen.screens.compactMap(\.mudoKey))
        for key in diff.remove {
            perScreen.removeValue(forKey: key)?.close()
        }
        // Displays that stay may have changed size or arrangement.
        for panel in perScreen.values { panel.place() }
        for key in diff.add {
            let panel = PanelController(model: model, screenKey: key)
            perScreen[key] = panel
            panel.show()
        }
    }
}
