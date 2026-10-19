import AppKit
import MuDoCore
import Observation
import SwiftUI

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
    }
}

/// Hosting view that reports the pointer entering even when MuDo is not the active app,
/// accepts the first click, and lets the background drag the panel.
/// The always-active tracking area also delivers `mouseMoved`, which NSHostingView turns
/// into SwiftUI hover updates, so `.onContinuousHover` works while MuDo is inactive.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onPointerEntered: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }
}

@MainActor
@Observable
final class PanelState {
    private(set) var hovering = false
    private(set) var pinned = false
    @ObservationIgnored var onSizeChange: ((CGSize) -> Void)?
    /// Whether the pointer is over the panel right now (screen coordinates, not tracking areas).
    @ObservationIgnored var pointerInside: () -> Bool = { false }
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    private static let pollInterval = Duration.milliseconds(200)
    private static let collapseDelay = Duration.milliseconds(1500)

    var isExpanded: Bool { hovering || pinned }

    func pointerEntered() {
        hovering = true
        watchPointer()
    }

    func togglePinned() {
        pinned.toggle()
        watchPointer()
    }

    /// A click outside the panel (in another app) collapses it, pinned or not.
    func clickedOutside() {
        guard isExpanded, !pointerInside() else { return }
        pinned = false
        hovering = false
    }

    /// While expanded, polls the pointer instead of trusting `mouseExited`, which AppKit does not
    /// deliver when the window resizes or moves under the pointer. Collapses a hover expansion once
    /// the pointer has been outside for `collapseDelay`; a pinned panel stays open.
    private func watchPointer() {
        guard watchTask == nil, isExpanded else { return }
        watchTask = Task { [weak self] in
            let clock = ContinuousClock()
            var outsideSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, self.isExpanded else { break }
                if self.pointerInside() {
                    self.hovering = true
                    outsideSince = nil
                } else if self.pinned {
                    outsideSince = nil
                } else if let since = outsideSince {
                    if clock.now - since >= Self.collapseDelay {
                        self.hovering = false
                        break
                    }
                } else {
                    outsideSince = clock.now
                }
            }
            self?.watchTask = nil
        }
    }

    func contentSizeChanged(_ size: CGSize) {
        onSizeChange?(size)
    }
}

@MainActor
final class PanelController {
    private static let positionKey = "panelTopLeft"
    private static let screenPositionsKey = "panelTopLeftByScreen"

    private let panel = FloatingPanel()
    private let state = PanelState()
    private let defaults: UserDefaults
    /// The display this panel is confined to (`NSScreen.mudoKey`); nil = a single panel free
    /// to move between displays.
    private let screenKey: String?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    /// True while we move the panel ourselves, so the move is not saved as the user's choice.
    private var movingProgrammatically = false
    /// Debounces `didMove` so a user drag is handled once, after it ends.
    private var moveSettleTask: Task<Void, Never>?

    init(model: AppModel, screenKey: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.screenKey = screenKey
        let host = HoverHostingView(rootView: RootView(model: model, panel: state))
        host.sizingOptions = []
        host.onPointerEntered = { [weak state] in state?.pointerEntered() }
        panel.contentView = host
        state.pointerInside = { [weak panel] in
            guard let panel else { return false }
            return NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
        }
        state.onSizeChange = { [weak self] size in self?.resize(to: size) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        })
        // A per-display panel is re-placed by PanelsController when screens change.
        if screenKey == nil {
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        // MuDo is never the active app, so focus loss is not observable; a global monitor
        // sees clicks delivered to other apps (no Accessibility permission needed for mouse events).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak state] _ in
            MainActor.assumeIsolated { state?.clickedOutside() }
        }
    }

    func show() {
        place()
        panel.orderFrontRegardless()
    }

    /// Hides the panel and stops observing; the controller can then be released.
    func close() {
        moveSettleTask?.cancel()
        panel.orderOut(nil)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// The screen a per-display panel belongs to; nil for a free panel or a display that is gone.
    private var ownScreen: NSScreen? {
        guard let screenKey else { return nil }
        return NSScreen.screens.first { $0.mudoKey == screenKey }
    }

    /// The visible frame the panel is kept inside: its own display's, or for a free panel
    /// the display it is on.
    private var confiningFrame: NSRect? {
        if screenKey != nil { return ownScreen?.visibleFrame }
        return (panel.screen ?? NSScreen.main)?.visibleFrame
    }

    /// Keeps the top edge, and the edge nearer the screen side (right edge in the right half),
    /// fixed; then keeps the whole panel inside the screen's visible frame.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let old = panel.frame
        var frame = old
        frame.size = size
        frame.origin.y = old.maxY - size.height
        if let visible = confiningFrame {
            if old.midX > visible.midX {
                frame.origin.x = old.maxX - size.width
            }
            frame = PanelPlacement.clamp(frame, to: visible)
        }
        setFrame(frame)
        if !state.isExpanded { saveTopLeft() }
    }

    /// `frame` moved fully inside the visible frame of the screen it belongs to.
    private static func onScreen(_ frame: NSRect) -> NSRect {
        guard let visible = PanelPlacement.visibleFrame(
            for: frame, screens: NSScreen.screens.map(\.visibleFrame),
            main: NSScreen.main?.visibleFrame) else { return frame }
        return PanelPlacement.clamp(frame, to: visible)
    }

    private func setFrame(_ frame: NSRect) {
        movingProgrammatically = true
        defer { movingProgrammatically = false }
        panel.setFrame(frame, display: true)
    }

    /// A user drag: once it settles, pull the panel back on screen and remember the collapsed
    /// pill's position (our own moves are not saved).
    private func panelMoved() {
        guard !movingProgrammatically else { return }
        moveSettleTask?.cancel()
        moveSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.userMoveEnded()
        }
    }

    private func userMoveEnded() {
        // Still dragging (the pointer just paused): wait for the button to be released.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            panelMoved()
            return
        }
        let frame: NSRect
        if screenKey != nil {
            guard let visible = ownScreen?.visibleFrame else { return }
            frame = PanelPlacement.clamp(panel.frame, to: visible)
        } else {
            frame = Self.onScreen(panel.frame)
        }
        if frame != panel.frame { setFrame(frame) }
        if !state.isExpanded { saveTopLeft() }
    }

    private func saveTopLeft() {
        let xy = [Double(panel.frame.minX), Double(panel.frame.maxY)]
        if let screenKey {
            var all = defaults.dictionary(forKey: Self.screenPositionsKey) ?? [:]
            all[screenKey] = xy
            defaults.set(all, forKey: Self.screenPositionsKey)
        } else {
            defaults.set(xy, forKey: Self.positionKey)
        }
    }

    private static func point(_ value: Any?) -> CGPoint? {
        guard let xy = value as? [Double], xy.count == 2 else { return nil }
        return CGPoint(x: xy[0], y: xy[1])
    }

    func place() {
        if screenKey != nil {
            placeOnOwnScreen()
            return
        }
        let saved = Self.point(defaults.array(forKey: Self.positionKey))
        guard let topLeft = PanelPlacement.topLeft(
            saved: saved,
            screens: NSScreen.screens.map(\.visibleFrame),
            main: NSScreen.main?.visibleFrame,
            width: max(panel.frame.width, 160)) else { return }
        let size = panel.frame.size
        let frame = Self.onScreen(NSRect(x: topLeft.x, y: topLeft.y - size.height,
                                         width: size.width, height: size.height))
        setFrame(frame)
        // A saved position that was (partly) off screen is replaced by the corrected one.
        if let saved, saved != CGPoint(x: frame.minX, y: frame.maxY), !state.isExpanded {
            saveTopLeft()
        }
    }

    /// A per-display panel: its saved position on that display, else the legacy single-panel
    /// position if it is on that display, else the display's top-right corner.
    private func placeOnOwnScreen() {
        guard let screenKey, let visible = ownScreen?.visibleFrame else { return }
        let own = Self.point(defaults.dictionary(forKey: Self.screenPositionsKey)?[screenKey])
        let saved = own ?? Self.point(defaults.array(forKey: Self.positionKey))
        let topLeft = PanelPlacement.topLeft(saved: saved, in: visible, width: max(panel.frame.width, 160))
        let size = panel.frame.size
        let frame = PanelPlacement.clamp(NSRect(x: topLeft.x, y: topLeft.y - size.height,
                                                width: size.width, height: size.height), to: visible)
        setFrame(frame)
        if let own, own != CGPoint(x: frame.minX, y: frame.maxY), !state.isExpanded {
            saveTopLeft()
        }
    }
}
