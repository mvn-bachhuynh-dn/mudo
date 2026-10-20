import Foundation

/// A release version: `MAJOR.MINOR.PATCH` integers with an optional leading `v`.
/// Anything else (a pre-release suffix, a missing part, `dev`) is not a version.
public struct AppVersion: Comparable, Sendable {
    let parts: [Int]

    public init?(_ text: String) {
        let body = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let fields = body.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var parts: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(field) else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}

/// The newest GitHub release: its version (no `v`) and the page to open.
public struct LatestRelease: Equatable, Sendable {
    public var version: String
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Update notice logic: MuDo only tells the user about a newer release, it never installs one.
public enum UpdateCheck {
    public static let endpoint = URL(string: "https://api.github.com/repos/mvn-bachhuynh-dn/mudo/releases/latest")!
    public static let releasesPrefix = "https://github.com/mvn-bachhuynh-dn/mudo/releases/"
    public static let fallbackURL = URL(string: "https://github.com/mvn-bachhuynh-dn/mudo/releases/latest")!
    public static let interval: TimeInterval = 24 * 3600
    public static let brewCommand = "brew upgrade --cask mudo"
    /// A Homebrew cask install leaves one of these behind.
    public static let caskrooms = ["/opt/homebrew/Caskroom/mudo", "/usr/local/Caskroom/mudo"]

    public enum UpgradeAction: Equatable, Sendable {
        case copyBrewCommand
        case openRelease(URL)
    }

    /// The GitHub "latest release" body; nil when `tag_name` is not a version.
    /// `html_url` is used only when it points at MuDo's own releases.
    public static func parse(_ data: Data) -> LatestRelease? {
        struct Body: Decodable {
            let tag_name: String?
            let html_url: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let tag = body.tag_name, AppVersion(tag) != nil else { return nil }
        var url = fallbackURL
        if let html = body.html_url, html.hasPrefix(releasesPrefix), let parsed = URL(string: html) {
            url = parsed
        }
        return LatestRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url)
    }

    /// True when there was no successful check yet, or the last one is at least 24 h old.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// The version to announce, or nil: checks on, both versions valid, latest newer, not skipped.
    public static func notice(current: String, latest: String?, skipped: String?, enabled: Bool) -> String? {
        guard enabled, let latest, latest != skipped,
              let have = AppVersion(current), let new = AppVersion(latest), new > have else { return nil }
        return latest
    }

    /// Homebrew installs get the upgrade command; anything else opens the release page.
    public static func action(releaseURL: URL, exists: (String) -> Bool) -> UpgradeAction {
        caskrooms.contains(where: exists) ? .copyBrewCommand : .openRelease(releaseURL)
    }
}
