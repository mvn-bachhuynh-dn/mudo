import Foundation
import Testing
@testable import MuDoCore

@Suite struct CswapTests {
    private let json = """
    {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
     {"number":2,"email":"user@example.com","organizationName":"Team A","active":true,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":26.0,"clock":"22:49","countdown":"4h 4m"},
               "sevenDay":{"pct":95.0,"clock":"Nov 14 05:59","countdown":"5d 11h"},
               "scoped":[{"name":"Fable","pct":0.0,"clock":"Nov 13 22:00","countdown":"5d 3h"}]}},
     {"number":1,"email":"old@example.com","organizationName":"","active":false,"usageStatus":"relogin_required",
      "usage":null,"lastGoodUsage":{"fiveHour":{"pct":6.0},"sevenDay":{"pct":69.0}}},
     {"number":3,"email":"setup-token-3@token.local","organizationName":"","active":false,"alias":"codex",
      "usageStatus":"unavailable","usage":null},
     {"email":"nonumber@example.com"}]}
    """

    private func parse(_ s: String) throws -> CswapList.Result { try CswapList.parse(Data(s.utf8)) }

    @Test func parsesAndSortsByNumber() throws {
        let r = try parse(json)
        #expect(r.accounts.map(\.number) == [1, 2, 3])
        #expect(r.activeNumber == 2)
    }

    @Test func liveUsageWindowsIncludeScoped() throws {
        let a = try parse(json).accounts[1]
        #expect(a.status == .ok && !a.stale)
        #expect(a.windows.map(\.name) == ["5h", "7d", "Fable"])
        #expect(a.windows[0].pct == 26 && a.windows[0].clock == "22:49")
    }

    @Test func reloginFallsBackToLastGood() throws {
        let a = try parse(json).accounts[0]
        #expect(a.status == .reloginRequired && a.stale)
        #expect(a.windows.map(\.pct) == [6, 69])
    }

    @Test func accountWithoutNumberIsSkipped() throws {
        #expect(try parse(json).accounts.count == 3)
    }

    @Test func rejectsGarbageAndNewSchema() {
        #expect(throws: CswapParseError.notJSON) { try parse("nope") }
        #expect(throws: CswapParseError.unsupportedSchema(2)) { try parse(#"{"schemaVersion":2}"#) }
    }

    @Test func toleratesMissingFields() throws {
        let r = try parse(#"{"accounts":[{"number":7}]}"#)
        #expect(r.accounts[0].status == .unavailable && r.accounts[0].windows.isEmpty)
        #expect(r.activeNumber == nil)
    }

    @Test func rowTitleUsesAliasThenEmail() throws {
        let rows = try parse(json).accounts.map(CswapRowModel.init)
        #expect(rows[0].title == "old@example.com")
        #expect(rows[2].title == "codex")
        #expect(rows[2].subtitle == "setup-token-3@token.local")
        #expect(rows[1].subtitle == "Team A")
    }

    @Test func switchableRules() throws {
        let rows = try parse(json).accounts.map(CswapRowModel.init)
        #expect(!rows[0].switchable)  // relogin required
        #expect(!rows[1].switchable)  // already active
        #expect(rows[2].switchable)
        #expect(rows[0].detail?.contains("cswap add") == true)
        #expect(rows[2].detail == "Usage unavailable")
    }

    @Test func severityThresholds() {
        #expect(CswapSeverity(pct: 69.9) == .low)
        #expect(CswapSeverity(pct: 70) == .medium)
        #expect(CswapSeverity(pct: 89) == .medium)
        #expect(CswapSeverity(pct: 90) == .high)
        #expect(CswapRowModel.percent(25.6) == "26%")
    }

    @Test func pathsAreFixed() {
        #expect(CswapPaths.candidates(home: "/Users/u").first == "/Users/u/.local/bin/cswap")
        #expect(CswapPaths.firstExecutable(home: "/h", isExecutable: { $0 == "/usr/local/bin/cswap" }) == "/usr/local/bin/cswap")
        #expect(CswapPaths.firstExecutable(home: "/h", isExecutable: { _ in false }) == nil)
    }

    @Test func commandArguments() {
        #expect(CswapCommand.switchTo(4) == ["switch", "4"])
        #expect(CswapCommand.list == ["list", "--json"])
        #expect(CswapCommand.errorLine("A newer version of x is available\n\nerror: bad account\nmore") == "error: bad account")
        #expect(CswapCommand.errorLine("") == "cswap failed")
    }
}
