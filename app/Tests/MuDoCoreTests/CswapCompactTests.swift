import Foundation
import Testing
@testable import MuDoCore

@Suite struct CswapCompactTests {
    private func w(_ name: String, _ pct: Double) -> CswapWindow {
        CswapWindow(name: name, pct: pct, clock: nil, countdown: nil)
    }
    private func acc(_ n: Int, active: Bool, _ windows: [CswapWindow], stale: Bool = false) -> CswapAccount {
        CswapAccount(number: n, email: "a\(n)@example.com", organization: "", alias: nil,
                     active: active, status: .ok, windows: windows, stale: stale)
    }

    @Test func picksFiveHourAndWeekOfActiveAccount() {
        let source = CswapSource(id: "local", name: "This Mac", accounts: [
            acc(1, active: false, [w("5h", 1), w("7d", 2)]),
            acc(2, active: true, [w("5h", 30), w("7d", 60), w("Sonnet", 5)]),
        ])
        let pick = CswapCompact.pick(in: source)
        #expect(pick?.windows.map(\.name) == ["5h", "7d"])
        #expect(pick?.windows.map(\.pct) == [30, 60])
        #expect(pick?.stale == false)
    }

    @Test func nilWithoutActiveAccountOrWindows() {
        #expect(CswapCompact.pick(in: nil) == nil)
        #expect(CswapCompact.pick(in: CswapSource(id: "x", name: "x", accounts: [acc(1, active: false, [w("5h", 1)])])) == nil)
        #expect(CswapCompact.pick(in: CswapSource(id: "x", name: "x", accounts: [acc(1, active: true, [w("Sonnet", 1)])])) == nil)
    }

    @Test func keepsOnlyTheWindowThatExists() {
        let source = CswapSource(id: "x", name: "x", accounts: [acc(1, active: true, [w("7d", 40)], stale: true)])
        let pick = CswapCompact.pick(in: source)
        #expect(pick?.windows.map(\.name) == ["7d"])
        #expect(pick?.stale == true)
    }
}
