import Foundation
import Testing
@testable import MuDoCore

@Suite struct WireDateTests {
    @Test func parsesWholeSeconds() {
        #expect(WireDate.parse("2026-10-16T09:49:45Z") == utc(2026, 10, 16, 9, 49, 45))
    }

    @Test func parsesNanoseconds() throws {
        let d = try #require(WireDate.parse("2026-10-16T09:49:45.39360749Z"))
        #expect(abs(d.timeIntervalSince(utc(2026, 10, 16, 9, 49, 45)) - 0.39360749) < 1e-6)
    }

    @Test func parsesOffset() {
        #expect(WireDate.parse("2026-10-16T16:49:45+07:00") == utc(2026, 10, 16, 9, 49, 45))
    }

    @Test func rejectsGarbage() {
        #expect(WireDate.parse("yesterday") == nil)
        #expect(WireDate.parse("2026-10-16T09:49:45.Z") == nil)
    }
}

@Suite struct StreamMessageTests {
    // Copied from a real mudod 0.1.0 stream; includes fields the app ignores.
    static let snapshotJSON = """
    {"server_now":"2026-10-16T09:49:45.39360749Z","host":"devbox","sessions":[{"id":"67d9a4b6","agent":"claude","host":"devbox","cwd":"/home/steve/Projects/must-do","project":"must-do","state":"running","state_since":"2026-10-16T09:49:24.416146735Z","pid":2730410,"pid_start":425562870,"last_prompt":"fix it","updated_at":"2026-10-16T09:49:24.416146735Z"}]}
    """

    @Test func decodesSnapshot() throws {
        let msg = try #require(try StreamMessage.decode(event: "snapshot", data: Self.snapshotJSON))
        guard case let .snapshot(serverNow, host, sessions) = msg else {
            Issue.record("expected snapshot, got \(msg)")
            return
        }
        #expect(host == "devbox")
        #expect(abs(serverNow.timeIntervalSince(utc(2026, 10, 16, 9, 49, 45)) - 0.39360749) < 1e-6)
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.id == "67d9a4b6")
        #expect(s.agent == "claude")
        #expect(s.cwd == "/home/steve/Projects/must-do")
        #expect(s.project == "must-do")
        #expect(s.state == .running)
        #expect(s.lastPrompt == "fix it")
        #expect(abs(s.stateSince.timeIntervalSince(utc(2026, 10, 16, 9, 49, 24)) - 0.416146735) < 1e-6)
    }

    @Test func nullSessionsBecomeEmpty() throws {
        let msg = try StreamMessage.decode(event: "snapshot", data: #"{"server_now":"2026-10-16T09:49:45Z","host":"h","sessions":null}"#)
        #expect(msg == .snapshot(serverNow: utc(2026, 10, 16, 9, 49, 45), host: "h", sessions: []))
    }

    @Test func decodesUpsertRemovePing() throws {
        let now = utc(2026, 10, 16, 9, 49, 45)
        let upsert = try StreamMessage.decode(event: "upsert", data: #"{"server_now":"2026-10-16T09:49:45Z","session":{"id":"a","agent":"kiro","host":"h","cwd":"/x","project":"x","state":"done","state_since":"2026-10-16T09:49:45Z","last_prompt":""}}"#)
        #expect(upsert == .upsert(serverNow: now, session: Session(id: "a", agent: "kiro", host: "h", cwd: "/x", project: "x", state: .done, stateSince: now, lastPrompt: "")))
        #expect(try StreamMessage.decode(event: "remove", data: #"{"server_now":"2026-10-16T09:49:45Z","id":"a"}"#) == .remove(serverNow: now, id: "a"))
        #expect(try StreamMessage.decode(event: "ping", data: #"{"server_now":"2026-10-16T09:49:45Z"}"#) == .ping(serverNow: now))
        #expect(try StreamMessage.decode(event: "ping", data: #"{"server_now":"2026-10-16T09:49:45Z"}"#)?.serverNow == now)
    }

    @Test func unknownEventIsNil() throws {
        #expect(try StreamMessage.decode(event: "message", data: "{}") == nil)
    }

    @Test func malformedThrows() {
        #expect(throws: (any Error).self) { try StreamMessage.decode(event: "upsert", data: "{") }
        #expect(throws: (any Error).self) {
            try StreamMessage.decode(event: "upsert", data: #"{"server_now":"2026-10-16T09:49:45Z","session":{"id":"a","agent":"kiro","host":"h","cwd":"/x","project":"x","state":"sleeping","state_since":"2026-10-16T09:49:45Z","last_prompt":""}}"#)
        }
    }
}
