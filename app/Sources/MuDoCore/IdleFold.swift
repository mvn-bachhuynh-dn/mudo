import Foundation

/// Folds a long run of idle sessions: only the newest few show, the rest behind a "+n idle" row.
public enum IdleFold {
    public static let shown = 3
    /// Choices for "Hide idle sessions after", in hours; 0 means never.
    public static let allowedHours = [0, 1, 4, 12, 24, 72, 168]
    public static let defaultHours = 168

    /// Keeps the order of `rows` (sorted by `SessionStore.rows`, newest idle first).
    /// Non-idle rows always show; `hidden` counts the idle rows left out.
    public static func split(_ rows: [SessionRow], showAll: Bool) -> (rows: [SessionRow], hidden: Int) {
        if showAll { return (rows, 0) }
        var idle = 0
        let kept = rows.filter { row in
            guard row.bucket == .idle else { return true }
            idle += 1
            return idle <= shown
        }
        return (kept, rows.count - kept.count)
    }

    /// The stored setting, or the default when missing or not one of `allowedHours`.
    public static func clampHours(_ h: Int?) -> Int {
        guard let h, allowedHours.contains(h) else { return defaultHours }
        return h
    }
}
