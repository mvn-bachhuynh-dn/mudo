import CoreGraphics

/// When a press on the widget becomes a drag of the widget rather than a click.
public enum PanelDrag {
    /// Points the pointer must travel with the button down.
    public static let threshold: CGFloat = 3

    public static func started(from down: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - down.x, current.y - down.y) > threshold
    }
}
