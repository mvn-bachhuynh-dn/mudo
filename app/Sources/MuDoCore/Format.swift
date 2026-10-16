import CoreGraphics
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

    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }
}
