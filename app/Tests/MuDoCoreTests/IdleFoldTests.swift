import Foundation
import Testing
@testable import MuDoCore

@Suite struct IdleFoldTests {
    private let server = UUID()
    private let t0 = utc(2026, 10, 16, 10, 0, 0)

    private func row(_ id: String, _ bucket: Bucket) -> SessionRow {
        let state: SessionState = bucket == .idle ? .idle : .running
        return SessionRow(id: SessionKey(serverID: server, sessionID: id),
                          session: makeSession(id, state, since: t0), serverName: "a", bucket: bucket,
                          since: t0, elapsed: 0, blinking: false, offline: false)
    }

    private var mixed: [SessionRow] {
        [row("r1", .running), row("r2", .running),
         row("i1", .idle), row("i2", .idle), row("i3", .idle), row("i4", .idle), row("i5", .idle)]
    }

    @Test func foldKeepsNonIdleAndFirstThreeIdle() {
        let fold = IdleFold.split(mixed, showAll: false)
        #expect(fold.rows.map(\.id.sessionID) == ["r1", "r2", "i1", "i2", "i3"])
        #expect(fold.hidden == 2)
    }

    @Test func showAllKeepsEverything() {
        let fold = IdleFold.split(mixed, showAll: true)
        #expect(fold.rows == mixed)
        #expect(fold.hidden == 0)
    }

    @Test func exactlyThreeIdleHidesNothing() {
        let rows = [row("i1", .idle), row("i2", .idle), row("i3", .idle)]
        let fold = IdleFold.split(rows, showAll: false)
        #expect(fold.rows == rows)
        #expect(fold.hidden == 0)
    }

    @Test func noIdleUnchanged() {
        let rows = [row("r1", .running), row("w", .waiting)]
        let fold = IdleFold.split(rows, showAll: false)
        #expect(fold.rows == rows)
        #expect(fold.hidden == 0)
    }

    @Test func clampHours() {
        #expect(IdleFold.clampHours(nil) == 168)
        #expect(IdleFold.clampHours(5) == 168)
        #expect(IdleFold.clampHours(0) == 0)
        #expect(IdleFold.clampHours(168) == 168)
    }
}
