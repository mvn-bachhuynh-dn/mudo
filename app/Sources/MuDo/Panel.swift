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

/// Hosting view that reports hover even when MuDo is not the active app,
/// accepts the first click, and lets the background drag the panel.
/// The always-active tracking area also delivers `mouseMoved`, which NSHostingView turns
/// into SwiftUI hover updates, so `.onContinuousHover` works while MuDo is inactive.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
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
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

@MainActor
@Observable
final class PanelState {
    private(set) var hovering = false
    private(set) var pinned = false
    @ObservationIgnored var onSizeChange: ((CGSize) -> Void)?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    var isExpanded: Bool { hovering || pinned }

    func pointerEntered() {
        collapseTask?.cancel()
        hovering = true
    }

    func pointerExited() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.hovering = false
        }
    }

    func togglePinned() {
        pinned.toggle()
    }

    func contentSizeChanged(_ size: CGSize) {
        onSizeChange?(size)
    }
}

@MainActor
final class PanelController {
    private static let positionKey = "panelTopLeft"

    private let panel = FloatingPanel()
    private let state = PanelState()
    private let defaults: UserDefaults
    /// True while we move the panel ourselves, so the move is not saved as the user's choice.
    private var movingProgrammatically = false

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let host = HoverHostingView(rootView: RootView(model: model, panel: state))
        host.sizingOptions = []
        host.onHover = { [weak state] inside in
            if inside { state?.pointerEntered() } else { state?.pointerExited() }
        }
        panel.contentView = host
        state.onSizeChange = { [weak self] size in self?.resize(to: size) }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func show() {
        place()
        panel.orderFrontRegardless()
    }

    /// Keeps the top edge, and the edge nearer the screen side (right edge in the right half),
    /// fixed; then keeps the whole panel inside the screen's visible frame.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let old = panel.frame
        var frame = old
        frame.size = size
        frame.origin.y = old.maxY - size.height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if old.midX > visible.midX {
                frame.origin.x = old.maxX - size.width
            }
            frame = Self.clamp(frame, to: visible)
        }
        setFrame(frame)
        if !state.isExpanded { saveTopLeft() }
    }

    private static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var f = frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    private func setFrame(_ frame: NSRect) {
        movingProgrammatically = true
        defer { movingProgrammatically = false }
        panel.setFrame(frame, display: true)
    }

    /// Only the collapsed pill's position is remembered (user drags, not our own moves).
    private func panelMoved() {
        guard !movingProgrammatically, !state.isExpanded else { return }
        saveTopLeft()
    }

    private func saveTopLeft() {
        defaults.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: Self.positionKey)
    }

    private func place() {
        var saved: CGPoint?
        if let xy = defaults.array(forKey: Self.positionKey) as? [Double], xy.count == 2 {
            saved = CGPoint(x: xy[0], y: xy[1])
        }
        guard let topLeft = PanelPlacement.topLeft(
            saved: saved,
            screens: NSScreen.screens.map(\.visibleFrame),
            main: NSScreen.main?.visibleFrame,
            width: max(panel.frame.width, 160)) else { return }
        movingProgrammatically = true
        defer { movingProgrammatically = false }
        panel.setFrameTopLeftPoint(topLeft)
    }
}
