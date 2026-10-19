import Foundation

/// Which per-display panels to open and close when the set of screens changes.
public enum PanelScreens {
    /// `add`: keys in `screens` with no open panel, in `screens` order, without duplicates.
    /// `remove`: open keys whose screen is gone, sorted.
    public static func diff(open: Set<String>, screens: [String]) -> (add: [String], remove: [String]) {
        var seen = Set<String>()
        let add = screens.filter { !open.contains($0) && seen.insert($0).inserted }
        let remove = open.subtracting(screens).sorted()
        return (add, remove)
    }
}
