import Foundation

/// Display order of one machine's cswap accounts.
public enum CswapOrder {
    /// `usableFirst == false` keeps the order of `cswap list`. Otherwise the active account comes
    /// first (even if it needs a new login), then accounts whose usage can be read, then
    /// `unavailable` ones, then `relogin_required` ones; inside a group the input order is kept.
    public static func sorted(_ accounts: [CswapAccount], usableFirst: Bool) -> [CswapAccount] {
        guard usableFirst else { return accounts }
        func rank(_ a: CswapAccount) -> Int {
            if a.active { return 0 }
            switch a.status {
            case .ok: return 1
            case .unavailable: return 2
            case .reloginRequired: return 3
            }
        }
        return accounts.enumerated()
            .sorted { l, r in
                let (a, b) = (rank(l.element), rank(r.element))
                return a != b ? a < b : l.offset < r.offset
            }
            .map(\.element)
    }
}
