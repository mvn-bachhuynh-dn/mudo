import Testing
@testable import MuDoCore

@Suite struct CswapOrderTests {
    private func account(_ number: Int, _ status: CswapAccount.Status = .ok, active: Bool = false) -> CswapAccount {
        CswapAccount(number: number, email: "a\(number)@example.com", organization: "", alias: nil,
                     active: active, status: status, windows: [], stale: false)
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
}
