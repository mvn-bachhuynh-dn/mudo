#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

public enum ElapsedFormat {
    /// "12s", "7m", "1h", "1h 5m".
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

public enum PanelPlacement {
    /// Where to put the panel's top-left corner (AppKit coordinates).
    /// Keeps `saved` while a point just inside it is on some screen; otherwise the main
    /// screen's top-right corner, inset by `margin`.
    public static func topLeft(saved: CGPoint?, screens: [CGRect], main: CGRect?,
                               width: CGFloat, margin: CGFloat = 12) -> CGPoint? {
        if let p = saved {
            let probe = CGPoint(x: p.x + 10, y: p.y - 10)
            if screens.contains(where: { contains($0, probe) }) { return p }
        }
        guard let m = main else { return saved }
        return CGPoint(x: m.maxX - width - margin, y: m.maxY - margin)
    }

    /// Like `topLeft(saved:screens:main:width:margin:)`, for a panel confined to one screen:
    /// keeps `saved` while a point just inside it is on `screen`; otherwise `screen`'s
    /// top-right corner, inset by `margin`.
    public static func topLeft(saved: CGPoint?, in screen: CGRect, width: CGFloat,
                               margin: CGFloat = 12) -> CGPoint {
        if let p = saved, contains(screen, CGPoint(x: p.x + 10, y: p.y - 10)) { return p }
        return CGPoint(x: screen.maxX - width - margin, y: screen.maxY - margin)
    }

    /// Moves (and if needed shrinks) `frame` so it lies fully inside `visible`.
    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// The visible frame a panel at `frame` belongs to: the screen containing its center,
    /// else the screen it overlaps most, else `main`.
    public static func visibleFrame(for frame: CGRect, screens: [CGRect], main: CGRect?) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let s = screens.first(where: { contains($0, center) }) { return s }
        let overlaps = screens.map { s -> (CGRect, CGFloat) in
            let i = s.intersection(frame)
            return (s, i.isNull ? 0 : i.width * i.height)
        }
        if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return main
    }

    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }
}
