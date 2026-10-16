import Foundation

/// Hides sessions by working directory. Patterns are globs where `*` matches any
/// characters (including `/`); every other character is literal. Matching is against the full cwd.
public struct IgnoreRules: Equatable, Sendable {
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func ignores(cwd: String) -> Bool {
        patterns.contains { Self.matches(pattern: $0, text: cwd) }
    }

    static func matches(pattern: String, text: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == text }
        guard text.hasPrefix(parts[0]) else { return false }
        var rest = Substring(text.dropFirst(parts[0].count))
        let last = parts[parts.count - 1]
        for part in parts[1..<(parts.count - 1)] where !part.isEmpty {
            guard let r = rest.range(of: part) else { return false }
            rest = rest[r.upperBound...]
        }
        return rest.hasSuffix(last)
    }
}
