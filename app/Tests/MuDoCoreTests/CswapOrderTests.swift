import Foundation
import Testing
@testable import MuDoCore

@Suite struct CswapOrderTests {
    private func account(_ number: Int, _ status: CswapAccount.Status = .ok, active: Bool = false) -> CswapAccount {
        CswapAccount(number: number, email: "a\(number)@example.com", organization: "", alias: nil,
                     active: active, status: status, windows: [], stale: false)
    }

    private func used(_ number: Int, week: Double?, five: Double?, email: String? = nil) -> CswapAccount {
        var a = account(number)
        if let email { a.email = email }
        func date(_ m: Double?) -> Date? { m.map { Date(timeIntervalSince1970: 1_800_000_000 + $0 * 60) } }
        a.windows = [CswapWindow(name: "5h", pct: 10, clock: nil, countdown: nil, resetsAt: date(five)),
                     CswapWindow(name: "7d", pct: 10, clock: nil, countdown: nil, resetsAt: date(week))]
        return a
    }

    private func numbers(_ list: [CswapAccount]) -> [Int] { list.map(\.number) }

    @Test func groupsAreOkThenUnavailableThenRelogin() {
        let input = [account(1, .reloginRequired), account(2, .unavailable), account(3), account(4, .reloginRequired), account(5)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [3, 5, 2, 1, 4])
    }

    @Test func activeAccountComesFirst() {
        let input = [account(1), account(2), account(3, active: true), account(4, .reloginRequired)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [3, 1, 2, 4])
    }

    @Test func activeAccountStaysFirstEvenWhenItNeedsANewLogin() {
        let input = [account(1), account(2, .reloginRequired, active: true), account(3, .unavailable)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [2, 1, 3])
    }

    @Test func listOrderIsKeptInsideAGroup() {
        let input = [account(7), account(2), account(5)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [7, 2, 5])
    }

    @Test func offKeepsTheInputOrder() {
        let input = [account(1, .reloginRequired), account(2, active: true), account(3, .unavailable)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: false)) == [1, 2, 3])
    }

    @Test func emptyAndSingleLists() {
        #expect(CswapOrder.sorted([], usableFirst: true).isEmpty)
        #expect(numbers(CswapOrder.sorted([account(9, .reloginRequired)], usableFirst: true)) == [9])
    }

    @Test func usableAccountsSortByWeeklyResetThenFiveHourReset() {
        let input = [used(1, week: 500, five: 10), used(2, week: 100, five: 90), used(3, week: 100, five: 30), used(4, week: 300, five: 5)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [3, 2, 4, 1])
    }

    @Test func resetTimesThatDifferByLessThanAMinuteCountAsEqual() {
        var a = used(1, week: 100, five: 90)
        a.windows[1].resetsAt = a.windows[1].resetsAt!.addingTimeInterval(0.3)
        let b = used(2, week: 100, five: 30)
        #expect(numbers(CswapOrder.sorted([a, b], usableFirst: true)) == [2, 1])
    }

    @Test func activeStaysFirstAndAccountsWithoutAResetTimeGoLastInTheirGroup() {
        let input = [used(1, week: nil, five: nil), used(2, week: 200, five: 1), used(3, week: 900, five: 1, email: "x@example.com")]
        var active = used(4, week: 999, five: 999); active.active = true
        #expect(numbers(CswapOrder.sorted(input + [active], usableFirst: true)) == [4, 2, 3, 1])
    }

    @Test func apiKeyAccountsComeAfterUsageAccountsAndBeforeUnavailableOnes() {
        let key = CswapAccount(number: 1, email: "api-key-1@token.local", organization: "", alias: nil,
                               active: false, status: .unavailable, windows: [], stale: false)
        let input = [account(2, .unavailable), key, used(3, week: 100, five: 1), account(4, .reloginRequired)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [3, 1, 2, 4])
    }
}
