import Foundation

/// Display order of one machine's cswap accounts.
public enum CswapOrder {
    /// `usableFirst == false` keeps the order of `cswap list`. Otherwise:
    /// 1. the active account (even if it needs a new login);
    /// 2. usable accounts with usage, the weekly (7d) reset that comes soonest first, then the 5h reset;
    /// 3. usable accounts without usage (API keys);
    /// 4. `unavailable` ones, then 5. `relogin_required` ones.
    /// Ties keep the input order. Reset times are compared to the minute, because cswap reports them
    /// with a few microseconds of jitter.
    public static func sorted(_ accounts: [CswapAccount], usableFirst: Bool) -> [CswapAccount] {
        guard usableFirst else { return accounts }
        func rank(_ a: CswapAccount) -> Int {
            if a.active { return 0 }
            switch a.status {
            case .ok: return hasUsage(a) ? 1 : 2
            case .unavailable: return isAPIKey(a) ? 2 : 3
            case .reloginRequired: return 4
            }
        }
        return accounts.enumerated()
            .sorted { l, r in
                let (a, b) = (rank(l.element), rank(r.element))
                if a != b { return a < b }
                if a == 1 {
                    let (x, y) = (resetKey(l.element, "7d"), resetKey(r.element, "7d"))
                    if x != y { return x < y }
                    let (p, q) = (resetKey(l.element, "5h"), resetKey(r.element, "5h"))
                    if p != q { return p < q }
                }
                return l.offset < r.offset
            }
            .map(\.element)
    }

    private static func hasUsage(_ a: CswapAccount) -> Bool { !a.windows.isEmpty }

    /// cswap registers API keys as `api-key-<slot>@token.local`; they have no usage to read.
    private static func isAPIKey(_ a: CswapAccount) -> Bool { a.email.hasSuffix("@token.local") }

    /// Minutes since 1970 of the window's reset; accounts that do not report it sort last.
    private static func resetKey(_ a: CswapAccount, _ window: String) -> Int {
        guard let d = a.windows.first(where: { $0.name == window })?.resetsAt else { return Int.max }
        return Int((d.timeIntervalSince1970 / 60).rounded(.down))
    }
}
