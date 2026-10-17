import Foundation

/// A configured mudod server. The token lives in the Keychain, keyed by `id`.
public struct ServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var daemonURL: URL
    public var codeServerURL: URL?

    public init(id: UUID, name: String, daemonURL: URL, codeServerURL: URL?) {
        self.id = id
        self.name = name
        self.daemonURL = daemonURL
        self.codeServerURL = codeServerURL
    }
}

extension ServerConfig {
    /// The mudod on this Mac: the daemon URL host is a loopback name (spec 5.1).
    public var isLocal: Bool {
        guard var host = URLComponents(url: daemonURL, resolvingAgainstBaseURL: false)?.host?.lowercased() else {
            return false
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }
}

public struct ServerDraft: Equatable, Sendable {
    public var name: String
    public var daemonURL: URL
    public var token: String
    public var codeServerURL: URL?

    public init(name: String, daemonURL: URL, token: String, codeServerURL: URL?) {
        self.name = name
        self.daemonURL = daemonURL
        self.token = token
        self.codeServerURL = codeServerURL
    }
}

/// `mudo://add?name=<n>&url=<daemon url>&token=<t>[&code_server=<url>]`
public enum AddLink {
    public static func parse(_ url: URL) -> ServerDraft? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == "mudo",
              comps.host?.lowercased() == "add" else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let v = items.first(where: { $0.name == name })?.value, !v.isEmpty else { return nil }
            return v
        }
        guard let token = value("token"),
              let daemon = value("url").flatMap(httpURL) else { return nil }
        let host = URLComponents(url: daemon, resolvingAgainstBaseURL: false)?.host ?? "server"
        return ServerDraft(name: value("name") ?? host,
                           daemonURL: daemon,
                           token: token,
                           codeServerURL: value("code_server").flatMap(httpURL))
    }

    /// An http(s) URL with a host, or nil.
    public static func httpURL(_ text: String) -> URL? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return nil }
        return comps.url
    }
}
