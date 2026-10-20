import Foundation

/// The collapsed widget steps aside when the pointer reaches it, so the user can click what is
/// underneath. Reaching it again at its new spot means the user wants the widget: it expands there.
/// Pure state machine; times are monotonic seconds, frames are screen coordinates (y up).
public struct Dodge: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case home
        /// Moved aside at time `at`.
        case dodged(at: Double)
        /// Expanded at the dodged spot; goes home when it collapses.
        case engaged
    }

    public enum Action: Equatable, Sendable {
        case moveToDodge(CGRect)
        case moveHome
        case expand
    }

    public private(set) var phase: Phase = .home
    /// Seconds after dodging during which the pointer near home keeps the widget aside.
    public var window: Double

    /// Points around the home frame where the pointer still counts as "at home".
    static let homeMargin: CGFloat = 8

    public init(window: Double = 0.5) {
        self.window = window
    }

    /// The pointer entered the panel. `allowed`: setting on, panel collapsed, no button pressed.
    public mutating func pointerEntered(now: Double, home: CGRect, visible: CGRect, allowed: Bool) -> Action? {
        switch phase {
        case .home:
            guard allowed, let frame = Self.dodgeFrame(home: home, visible: visible) else { return nil }
            phase = .dodged(at: now)
            return .moveToDodge(frame)
        case .dodged:
            // Within the window: a quick second approach; after it: the pointer went there on purpose.
            phase = .engaged
            return .expand
        case .engaged:
            return nil
        }
    }

    /// Pointer poll while dodged: back home once the window is over and the pointer has left
    /// the home spot (grown by `homeMargin`); stays aside however long the pointer remains there.
    public mutating func tick(pointer: CGPoint, now: Double, home: CGRect) -> Action? {
        guard case let .dodged(at) = phase, now - at > window,
              !home.insetBy(dx: -Self.homeMargin, dy: -Self.homeMargin).contains(pointer) else { return nil }
        phase = .home
        return .moveHome
    }

    /// The panel collapsed (hover collapse or unpin).
    public mutating func collapsed() -> Action? {
        guard phase == .engaged else { return nil }
        phase = .home
        return .moveHome
    }

    /// Setting off, display change, `show()` or a user drag: home, no action.
    public mutating func reset() {
        phase = .home
    }

    /// `home` moved down by its height plus `gap`, or up when that leaves `visible` at the
    /// bottom; nil when neither fits.
    public static func dodgeFrame(home: CGRect, visible: CGRect, gap: CGFloat = 8) -> CGRect? {
        let step = home.height + gap
        let down = home.offsetBy(dx: 0, dy: -step)
        if down.minY >= visible.minY { return down }
        let up = home.offsetBy(dx: 0, dy: step)
        if up.maxY <= visible.maxY { return up }
        return nil
    }

    /// The setting in milliseconds: nil or outside 200...2000 reads as 500.
    public static func clampWindowMs(_ ms: Int?) -> Int {
        guard let ms, (200...2000).contains(ms) else { return 500 }
        return ms
    }
}
