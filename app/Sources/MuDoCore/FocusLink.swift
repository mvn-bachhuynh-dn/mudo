import Foundation

/// `mudo://focus?project=<name>` or `mudo://focus?session=<id>`: does what clicking that session row does.
public enum FocusLink {
    public enum Target: Equatable, Sendable {
        case project(String)
        case session(String)
    }

    public static func parse(_ url: URL) -> Target? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == "mudo",
              comps.host?.lowercased() == "focus" else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let v = items.first(where: { $0.name == name })?.value, !v.isEmpty else { return nil }
            return v
        }
        if let id = value("session") { return .session(id) }
        if let name = value("project") { return .project(name) }
        return nil
    }
}
