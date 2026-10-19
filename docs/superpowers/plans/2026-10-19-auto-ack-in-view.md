# Auto-acknowledge sessions already in view: Implementation Plan

> **For agentic workers:** executed with `/mudo-task`, one task per run. Steps use checkbox (`- [ ]`) syntax.

**Goal:** When a session is `done` and its place (Chrome code-server tab, terminal tab, tmux pane, ssh tab, editor window) is the one in front of a user who is at the Mac, MuDo acknowledges it by itself, as if the row had been clicked: no blinking, no click needed.

**Architecture:** Pure matching, presence and candidate logic plus the AppleScript sources live in MuDoCore (unit-tested). The MuDo target gets a probe that reads what is in front (frontmost app, one AppleScript for its active tab/session, tmux active pane), a side-effect-free "where is this session shown" resolver built from LocalFocuser's existing steps, and an AppModel loop that runs every 2 s only while unacknowledged `done` sessions exist.

**Tech Stack:** Swift 6, AppKit, AppleScript (NSAppleScript via the existing `AppleScriptRunner`), swift-testing (MuDoCore only).

## Global Constraints

- Auto-ack happens only when BOTH hold: (1) the session's place is in front (rules in Task 1); (2) the user is present: seconds since the last mouse/keyboard event `< 60` and the screen is not locked.
- Checks run once per 2 s tick, only while at least one row is `done`, not offline, and not already auto-acked; with none, no AppleScript, `ps`, `lsof` or `tmux` runs at all.
- Acknowledging = the same ack the row click sends (`APIClient.ack`, `markAckFailed` on failure) plus `store.clearSnooze`; it never focuses, activates, selects or raises anything.
- The probe only scripts the app that is already frontmost (never `tell` an app that is not running: that would launch it).
- Supported: Chrome (`com.google.Chrome`) code-server tabs, iTerm2, Terminal.app, tmux (local and around ssh), ssh tabs, VS Code-like editors (`TerminalApp.vscodeLike`). Ghostty and other apps: never auto-acked.
- Editor matching uses only the first two `FocusHints.titleCandidates` (deepest cwd folder, project), so a parent folder name never matches.
- Setting `autoAckInView` (UserDefaults key `"autoAckInView"`), default `true`; Settings toggle label `Auto-acknowledge when already in view` in the `Alerts` section, caption `A finished session you are already looking at is marked seen without a click.`
- No new permissions: the same Automation (Chrome, iTerm2, Terminal, System Events) and Accessibility grants the click focus uses. A denied or failed script means "not in view" for that tick, logged at most once per app per launch.
- Tests never touch the real `$HOME`, `~/.claude`, `launchctl` or `systemctl`.

---

### Task 1: MuDoCore matching, presence, candidates and probe scripts

**Files:**
- Create: `app/Sources/MuDoCore/AutoAck.swift`
- Modify: `app/Sources/MuDoCore/TerminalScripts.swift`, `app/Sources/MuDoCore/TabMatcher.swift` (`ChromeScripts`)
- Create: `app/Tests/MuDoCoreTests/AutoAckTests.swift`
- Modify: `app/Tests/MuDoCoreTests/TerminalScriptsTests.swift`

**Interfaces (produces):**

```swift
/// What is in front of the user right now.
public enum FrontView: Equatable, Sendable {
    case chromeTab(url: String, title: String)
    /// iTerm2's current session or Terminal's selected tab; `tmuxPane` is the active pane
    /// (e.g. "%3") when that tty is a tmux client, else nil.
    case terminal(tty: String, tmuxPane: String?)
    case editor(title: String)
}

/// Where a session is shown, resolved without side effects.
public enum SessionPlace: Equatable, Sendable {
    case chrome(codeServer: URL, cwd: String, project: String)
    /// The terminal tab's tty: the local shell's, or the tty of the local ssh client.
    case tty(String)
    case tmux(pane: String, socket: String?)
    /// Window-title words; callers pass at most the first two title candidates.
    case editor(titles: [String])
}

public enum AutoAck {
    public static let presenceWindow: TimeInterval = 60
    public static func isInView(_ place: SessionPlace, front: FrontView) -> Bool
    public static func userPresent(idleSeconds: TimeInterval, screenLocked: Bool) -> Bool
    /// Rows to check this tick: state `.done`, not offline, key not in `alreadyAcked`; in row order.
    public static func candidates(_ rows: [SessionRow], alreadyAcked: Set<SessionKey>) -> [SessionRow]
}
```

Rules for `isInView`:
- `.chrome` with `.chromeTab(url, title)`: `TabMatcher.match(tabs: [ChromeTab(windowID: 0, tabIndex: 1, url: url, title: title)], codeServer:cwd:project:) != nil`.
- `.tty(a)` with `.terminal(tty: b, _)`: `a == b`.
- `.tmux(pane: p, _)` with `.terminal(_, tmuxPane: q)`: `q == p`.
- `.editor(titles)` with `.editor(title)`: some non-empty candidate is contained in `title`.
- Every other pairing: `false`.

`SessionRow` has no public init today; add `public init(id:session:serverName:bucket:since:elapsed:blinking:offline:)` (memberwise) so tests can build rows.

Scripts (each returns plain values; never activates or selects):
- `ChromeScripts.activeTab`: `tell application id "com.google.Chrome"` / `if (count of windows) is 0 then return {}` / `return {URL of active tab of front window, title of active tab of front window}`.
- `TerminalScripts.iTermFrontTTY`: `tell application "iTerm2"` / `if (count of windows) is 0 then return ""` / `return tty of current session of current window`.
- `TerminalScripts.terminalAppFrontTTY`: `tell application "Terminal"` / `if (count of windows) is 0 then return ""` / `return tty of selected tab of front window`.
- `TerminalScripts.frontWindowTitle(appName:)`: `tell application "System Events"` / `tell process <quoted appName>` / `if (count of windows) is 0 then return ""` / `return (name of front window) as text`.

- [ ] **Step 1: Write the failing tests** in `AutoAckTests.swift`:

```swift
import Foundation
import Testing
@testable import MuDoCore

@Suite struct AutoAckTests {
    let cs = URL(string: "https://code.example.com")!

    @Test func chromeTabOfTheFolderIsInView() {
        let place = SessionPlace.chrome(codeServer: cs, cwd: "/home/user/proj", project: "proj")
        #expect(AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/?folder=/home/user/proj", title: "x")))
        #expect(!AutoAck.isInView(place, front: .chromeTab(url: "https://code.example.com/?folder=/home/user/other", title: "x")))
        #expect(!AutoAck.isInView(place, front: .chromeTab(url: "https://example.org/?folder=/home/user/proj", title: "x")))
    }

    @Test func ttyMatchesExactly() {
        #expect(AutoAck.isInView(.tty("/dev/ttys004"), front: .terminal(tty: "/dev/ttys004", tmuxPane: nil)))
        #expect(!AutoAck.isInView(.tty("/dev/ttys004"), front: .terminal(tty: "/dev/ttys005", tmuxPane: nil)))
    }

    @Test func tmuxNeedsTheActivePane() {
        let place = SessionPlace.tmux(pane: "%3", socket: nil)
        #expect(AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%3")))
        #expect(!AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: "%4")))
        #expect(!AutoAck.isInView(place, front: .terminal(tty: "/dev/ttys001", tmuxPane: nil)))
    }

    @Test func editorTitleContainsACandidate() {
        let place = SessionPlace.editor(titles: ["api", "proj"])
        #expect(AutoAck.isInView(place, front: .editor(title: "main.go — proj")))
        #expect(!AutoAck.isInView(place, front: .editor(title: "main.go — other")))
        #expect(!AutoAck.isInView(.editor(titles: [""]), front: .editor(title: "anything")))
    }

    @Test func mismatchedKindsAreNotInView() {
        #expect(!AutoAck.isInView(.tty("/dev/ttys004"), front: .editor(title: "/dev/ttys004")))
        #expect(!AutoAck.isInView(.editor(titles: ["proj"]), front: .chromeTab(url: "x", title: "proj")))
    }

    @Test func presence() {
        #expect(AutoAck.userPresent(idleSeconds: 5, screenLocked: false))
        #expect(!AutoAck.userPresent(idleSeconds: 60, screenLocked: false))
        #expect(!AutoAck.userPresent(idleSeconds: 1, screenLocked: true))
    }

    @Test func candidatesAreDoneOnlineAndNotYetAcked() {
        let server = UUID()
        func row(_ id: String, _ state: SessionState, offline: Bool = false) -> SessionRow {
            let s = Session(id: id, agent: .claude, cwd: "/w/\(id)", project: id, state: state,
                            stateSince: Date(timeIntervalSince1970: 0), lastPrompt: nil, terminal: nil)
            return SessionRow(id: SessionKey(serverID: server, sessionID: id), session: s, serverName: "devbox",
                              bucket: .done, since: Date(timeIntervalSince1970: 0), elapsed: 0,
                              blinking: false, offline: offline)
        }
        let rows = [row("a", .done), row("b", .running), row("c", .done, offline: true), row("d", .done)]
        let acked: Set = [SessionKey(serverID: server, sessionID: "d")]
        #expect(AutoAck.candidates(rows, alreadyAcked: acked).map(\.session.id) == ["a"])
    }
}
```

(Adjust the `Session(...)` initializer call to the real one in `Wire.swift`; keep the values.)

In `TerminalScriptsTests.swift` add tests that each new script: names the right app (`application id "com.google.Chrome"`, `"iTerm2"`, `"Terminal"`, `"System Events"`), contains the `count of windows` guard, and contains none of `activate`, `select`, `set index`, `AXRaise`, `set frontmost`; and that `frontWindowTitle(appName:)` escapes its argument (`onlyEscaped`).

- [ ] **Step 2: Run, expect compile failure**: `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test'`.
- [ ] **Step 3: Implement** per Interfaces and rules.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(app): match a session's place against what is in front`.

---

### Task 2: Probe what is in front, and resolve a session's place

**Files:**
- Create: `app/Sources/MuDo/InViewProbe.swift`
- Modify: `app/Sources/MuDo/LocalFocuser.swift` (add a side-effect-free resolver; reuse its helpers)

**Interfaces:**
- Consumes (Task 1): `FrontView`, `SessionPlace`, the four probe scripts.
- Produces:
  - `@MainActor final class InViewProbe` with `func frontView(tmuxSockets: [String?]) async -> FrontView?` and `func userPresent() -> Bool`.
  - `LocalFocuser.place(for plan: FocusPlan) async -> SessionPlace?`.

`InViewProbe.frontView`:
- `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`:
  - `com.google.Chrome`: run `ChromeScripts.activeTab`; a 2-item list gives `.chromeTab(url:title:)`.
  - `com.googlecode.iterm2` / `com.apple.Terminal`: run the matching front-tty script; empty means nil. Then, if a tmux client is attached on that tty, the active pane: for each socket in `tmuxSockets` (nil = default socket), run `tmux [-S socket] display -p -c <tty> '#{pane_id}'` with the binary from `TmuxPick.resolveBinary` (socket checked with `TmuxPick.socketAllowed`, as `tmuxStep` does); first non-empty answer wins. Gives `.terminal(tty:tmuxPane:)`.
  - A running app whose bundle path classifies as `TerminalApp.vscodeLike` (same classification the process table uses): run `TerminalScripts.frontWindowTitle(appName:)` with the same process name `LocalFocuser.processName` uses; gives `.editor(title:)`.
  - Anything else: nil.
- Script results `.denied`/`.failed`: nil, logged once per bundle id per launch.

`InViewProbe.userPresent`: `AutoAck.userPresent(idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!), screenLocked: <CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"] as? Bool ?? false>)`.

`LocalFocuser.place(for:)`: mirrors the focus steps but never runs `select-window`, `select-pane`, `activate` or any focusing script:
- `.chrome(cs, cwd, project)`: `.chrome(codeServer: cs, cwd: cwd, project: project)`.
- `.local(t, ...)` with `t.tmuxPane`: `.tmux(pane:socket:)`.
- `.local(t, ...)` with `t.tty`: owner of the first non-tmux process on that tty (`ProcessTable.owner(of:)`): `.app(.iTerm2)`/`.app(.terminal)` give `.tty(outerTTY)`; `.app(.vscodeLike)` gives `.editor(titles: Array(titleCandidates.prefix(2)))`; `.tmux` gives `.tmux` for the pane found with `list-panes` (as in `focus(pid:)`); others nil.
- `.ssh(t, ...)`: the lsof + `SSHPick.choose` steps of `focusSSH`, then the same owner rules for the chosen pid (with the cwd-based editor titles left out: the cwd is remote).
- `.none`: nil.
Factor shared lookups (process table, ssh pick, tmux pane for a tty) into private helpers used by both the focus path and `place(for:)`; the focus behavior must not change.

- [ ] **Step 1:** Implement; keep logic that can be pure in MuDoCore with tests (e.g. parsing the `activeTab` list result) if any new pure helper appears.
- [ ] **Step 2:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`, expect success.
- [ ] **Step 3: Commit** `feat(app): probe the front tab and resolve where a session is shown`.

---

### Task 3: Auto-ack loop, setting and docs

**Files:**
- Modify: `app/Sources/MuDo/AppModel.swift`, `app/Sources/MuDo/AppSettings.swift`, `app/Sources/MuDo/SettingsView.swift`, `README.md`

**Interfaces:**
- Consumes: `AutoAck.candidates/isInView`, `InViewProbe`, `LocalFocuser.place(for:)`.
- Produces: `AppSettings.autoAckInView: Bool`.

Behavior:
- `AppModel` gets a private `ack(_ key: SessionKey, config: ServerConfig)` used by both `open(_:)` (unchanged behavior) and auto-ack.
- In the existing 1 s timer, every second tick (2 s), when `settings.autoAckInView` and no check is in flight: `let rows = AutoAck.candidates(store.rows, alreadyAcked: autoAcked)`; empty: return. `probe.userPresent()` false: return. Resolve each candidate's place once and cache it by `SessionKey`, a nil result included (retry a nil place at most every 30 s, so `ps`/`lsof` do not run every tick for a session with no local place); drop cache entries whose session is gone or no longer `done`. On this periodic path `LocalFocuser.place(for:)` must not log at `.info` per call (pass a no-op step logger or log at `.debug`); `FocusPlan.plan(server:session:)` gives the plan. Get `probe.frontView(tmuxSockets:)` once per tick, with the sockets of the cached `.tmux` places. For each candidate in view: `store.clearSnooze(key)`, `ack`, insert into `autoAcked`, log `auto-ack <project>`.
- `autoAcked` entries are removed when the session is no longer `done` (so a later `done` can be auto-acked again).
- `AppSettings.autoAckInView` persisted under `"autoAckInView"`, default `true` when absent.
- Settings: toggle and caption from Global Constraints, in `Alerts`.
- README Usage: one short paragraph: what auto-ack does, the two conditions, the supported places, the setting.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`, expect success.
- [ ] **Step 3: Commit** `feat(app): acknowledge finished sessions already in view`.
