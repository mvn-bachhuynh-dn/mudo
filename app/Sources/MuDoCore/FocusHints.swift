import Foundation

/// Pure hints for local focus (spec 5.4).
public enum FocusHints {
    /// Window-title words for an editor window, best first: the deepest cwd component, the project,
    /// then the other cwd components up the tree. Components at or above `home` (and `/`) are
    /// left out: every window would match them.
    public static func titleCandidates(cwd: String, project: String, home: String) -> [String] {
        let homeParts = home.split(separator: "/")
        let parts = cwd.split(separator: "/")
        var inside: [String] = []
        for (i, part) in parts.enumerated() {
            // parts[0...i] is home or one of its parents.
            if i < homeParts.count, homeParts[0...i].elementsEqual(parts[0...i]) { continue }
            inside.append(String(part))
        }
        let deepestFirst = Array(inside.reversed())
        var out: [String] = []
        for name in Array(deepestFirst.prefix(1)) + [project] + Array(deepestFirst.dropFirst())
        where !name.isEmpty && !out.contains(name) {
            out.append(name)
        }
        return out
    }

    /// The app for a `TERM_PROGRAM` value captured by the hook.
    public static func bundleID(program: String?) -> String? {
        switch program ?? "" {
        case "iTerm.app": "com.googlecode.iterm2"
        case "Apple_Terminal": "com.apple.Terminal"
        case "ghostty": "com.mitchellh.ghostty"
        case "vscode": "com.microsoft.VSCode"
        default: nil
        }
    }
}
