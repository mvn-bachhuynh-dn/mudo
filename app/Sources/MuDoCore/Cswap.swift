import Foundation

/// One usage window of an account ("5h", "7d" or a model-scoped one).
public struct CswapWindow: Equatable, Sendable {
    public var name: String
    public var pct: Double
    /// Local reset time as cswap prints it ("22:49", "Nov 14 05:59"); nil when not reported.
    public var clock: String?
    public var countdown: String?
}

public struct CswapAccount: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        case ok
        case reloginRequired
        case unavailable
    }

    public var number: Int
    public var email: String
    public var organization: String
    public var alias: String?
    public var active: Bool
    public var status: Status
    /// Usage to show: live when `status == .ok`, else the last good reading, else empty.
    public var windows: [CswapWindow]
    /// `windows` come from `lastGoodUsage`, not a live fetch.
    public var stale: Bool

    public var id: Int { number }
}

public enum CswapParseError: Error, Equatable {
    case notJSON
    case unsupportedSchema(Int)
}

public enum CswapList {
    public struct Result: Equatable, Sendable {
        public var accounts: [CswapAccount]
        public var activeNumber: Int?
    }

    /// Parses `cswap list --json`. Unknown fields are ignored; an account without a number is skipped.
    public static func parse(_ data: Data) throws -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CswapParseError.notJSON
        }
        let schema = root["schemaVersion"] as? Int ?? 1
        guard schema == 1 else { throw CswapParseError.unsupportedSchema(schema) }
        let raw = root["accounts"] as? [[String: Any]] ?? []
        let accounts = raw.compactMap(account)
        return Result(accounts: accounts.sorted { $0.number < $1.number },
                      activeNumber: root["activeAccountNumber"] as? Int)
    }

    private static func account(_ o: [String: Any]) -> CswapAccount? {
        guard let number = o["number"] as? Int else { return nil }
        let status: CswapAccount.Status
        switch o["usageStatus"] as? String {
        case "ok": status = .ok
        case "relogin_required": status = .reloginRequired
        default: status = .unavailable
        }
        let live = o["usage"] as? [String: Any]
        let lastGood = o["lastGoodUsage"] as? [String: Any]
        let source = live ?? lastGood
        return CswapAccount(
            number: number,
            email: o["email"] as? String ?? "",
            organization: o["organizationName"] as? String ?? "",
            alias: (o["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            active: o["active"] as? Bool ?? false,
            status: status,
            windows: source.map(windows) ?? [],
            stale: live == nil && lastGood != nil)
    }

    private static func windows(_ usage: [String: Any]) -> [CswapWindow] {
        var out: [CswapWindow] = []
        if let w = usage["fiveHour"] as? [String: Any], let x = window("5h", w) { out.append(x) }
        if let w = usage["sevenDay"] as? [String: Any], let x = window("7d", w) { out.append(x) }
        for case let w as [String: Any] in usage["scoped"] as? [Any] ?? [] {
            if let name = w["name"] as? String, let x = window(name, w) { out.append(x) }
        }
        return out
    }

    private static func window(_ name: String, _ o: [String: Any]) -> CswapWindow? {
        guard let pct = (o["pct"] as? NSNumber)?.doubleValue else { return nil }
        return CswapWindow(name: name, pct: pct, clock: o["clock"] as? String, countdown: o["countdown"] as? String)
    }
}

public enum CswapSeverity: Equatable, Sendable {
    case low, medium, high

    public init(pct: Double) {
        self = pct >= 90 ? .high : pct >= 70 ? .medium : .low
    }
}

/// Display decisions for one account row, kept out of the view so they are testable.
public struct CswapRowModel: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var detail: String?
    public var windows: [CswapWindow]
    public var active: Bool
    public var stale: Bool
    public var switchable: Bool

    public init(_ a: CswapAccount) {
        title = a.alias ?? (a.email.isEmpty ? "Account \(a.number)" : a.email)
        var sub = [a.organization]
        if a.alias != nil, !a.email.isEmpty { sub.insert(a.email, at: 0) }
        subtitle = sub.filter { !$0.isEmpty }.joined(separator: " · ")
        windows = a.windows
        active = a.active
        stale = a.stale
        switch a.status {
        case .ok: detail = nil
        case .reloginRequired: detail = "Log in again with Claude Code, then run cswap add"
        case .unavailable: detail = a.windows.isEmpty ? "Usage unavailable" : "Usage out of date"
        }
        switchable = !a.active && a.status != .reloginRequired
    }

    /// "5h 26%" style text for the small summary line of a window.
    public static func percent(_ pct: Double) -> String { "\(Int(pct.rounded()))%" }
}

public enum CswapPaths {
    /// The only places the app will run `cswap` from.
    public static func candidates(home: String) -> [String] {
        ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
    }

    public static func firstExecutable(home: String, isExecutable: (String) -> Bool) -> String? {
        candidates(home: home).first(where: isExecutable)
    }
}

public enum CswapCommand {
    public static let list = ["list", "--json"]

    public static func switchTo(_ number: Int) -> [String] { ["switch", String(number)] }

    /// First non-empty stderr/stdout line, for an error shown in the widget. cswap prints an
    /// upgrade notice first on some runs; that line is skipped.
    public static func errorLine(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("A newer version") }
        return lines.first ?? "cswap failed"
    }
}
