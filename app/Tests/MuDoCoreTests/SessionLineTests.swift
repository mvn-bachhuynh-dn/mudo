import Foundation
import Testing
@testable import MuDoCore

@Suite struct SessionLineTests {
    func session(_ state: SessionState, output: String? = nil, notice: String? = nil) -> Session {
        Session(id: "a", agent: "claude", host: "devbox", cwd: "/w/api", project: "api", state: state,
                stateSince: Date(timeIntervalSince1970: 0), lastPrompt: "fix the bug",
                lastOutput: output, notice: notice)
    }

    @Test func waitingShowsNotice() {
        #expect(SessionLine.text(for: session(.waiting, output: "Done", notice: "Needs permission")) == "Needs permission")
    }

    @Test func waitingWithoutNoticeShowsPrompt() {
        #expect(SessionLine.text(for: session(.waiting)) == "fix the bug")
        #expect(SessionLine.text(for: session(.waiting, notice: "")) == "fix the bug")
    }

    @Test func finishedStatesShowOutput() {
        for state in [SessionState.done, .idle, .ended] {
            #expect(SessionLine.text(for: session(state, output: "Pushed the fix")) == "Pushed the fix")
        }
    }

    @Test func runningShowsPrompt() {
        #expect(SessionLine.text(for: session(.running, output: "Pushed the fix", notice: "Needs permission")) == "fix the bug")
    }

    @Test func emptyOutputShowsPrompt() {
        #expect(SessionLine.text(for: session(.done, output: "")) == "fix the bug")
        #expect(SessionLine.text(for: session(.done)) == "fix the bug")
    }
}
