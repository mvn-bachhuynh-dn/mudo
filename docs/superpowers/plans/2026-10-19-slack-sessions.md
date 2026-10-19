# Slack sessions (KiroCrew) Implementation Plan

> **For agentic workers:** executed with `/mudo-task` (one task at a time). Steps use checkbox (`- [ ]`) syntax.

**Goal:** A session started by KiroCrew from a Slack channel opens that Slack channel when clicked, instead of a code-server tab. KiroCrew background sessions without a channel are not tracked.

**Architecture:** KiroCrew runs each agent with `KIROCREW_SPAWNED=1` and, for Slack conversations, `KIROCREW_CHANNEL_ID=<Slack channel ID>` in its environment; the agent's hooks inherit it. The `mudod` hook records the channel in `Terminal.SlackChannel` (`slack_channel` on the wire) and drops events from spawned agents that have no channel. The app adds `FocusPlan.slack(channel:)`, checked first, and opens a Slack URL built in MuDoCore. Auto-acknowledge never applies to Slack sessions (their place is nil).

**Tech Stack:** Go (server/internal/hook), Swift 6 + swift-testing (MuDoCore), SwiftUI/AppKit (MuDo).

## Global Constraints

- Env vars, exact names: `KIROCREW_SPAWNED` (value `1` = spawned by KiroCrew), `KIROCREW_CHANNEL_ID`.
- Slack channel ID is valid only if it matches `^[CDG][A-Z0-9]{6,20}$`. Workspace (team) ID is valid only if it matches `^[TE][A-Z0-9]{6,20}$`. Invalid values are dropped (Go: not recorded; Swift: `validated()` drops it; a bad team ID setting is treated as empty).
- Wire field: `slack_channel` (Go `json:"slack_channel,omitempty"`), Swift `TerminalInfo.slackChannel: String?`.
- URLs, exact shape: with team `slack://channel?team=<TEAM>&id=<CHANNEL>`; without team `https://slack.com/app_redirect?channel=<CHANNEL>`.
- Setting `slackTeamID` (UserDefaults key `"slackTeamID"`), default `""`. Settings section titled `Slack`, placed after `Alerts`, with a `TextField("Workspace ID", text:)` (prompt `T0123456789`) and caption `Opens KiroCrew sessions straight in the Slack app. Empty: through slack.com in the browser.`
- Use only placeholder IDs in tests and docs (`C0123456789`, `T0123456789`), never real ones.
- Tests never touch the real environment, `$HOME` or Slack; inject env and openers.

---

### Task 1: mudod hook records the Slack channel and skips channel-less KiroCrew agents

**Files:**
- Modify: `server/internal/model/*.go` (`Terminal`: add `SlackChannel string \`json:"slack_channel,omitempty"\`` with comment `// KIROCREW_CHANNEL_ID: Slack channel of a KiroCrew session`)
- Modify: `server/internal/hook/terminal.go` (`CaptureTerminal` sets `SlackChannel` from `KIROCREW_CHANNEL_ID` when valid; add `validSlackChannel(string) bool`)
- Modify: `server/internal/hook/run.go` (`Run`: when `o.Env != nil`, `o.Env("KIROCREW_SPAWNED") == "1"` and `!validSlackChannel(o.Env("KIROCREW_CHANNEL_ID"))`, return right after reading stdin and the optional dump, before `Normalize`; no log line, no POST)
- Test: `server/internal/hook/terminal_test.go`, `server/internal/hook/run_test.go`
- Modify: `README.md` (one sentence where agents/terminals are described: KiroCrew Slack sessions open their Slack channel; KiroCrew background sessions are not shown)

- [ ] **Step 1: Failing tests.** In `TestCaptureTerminal` add cases: `KIROCREW_CHANNEL_ID=C0123456789` only gives `&model.Terminal{SlackChannel: "C0123456789"}`; `KIROCREW_CHANNEL_ID=c0123; rm` gives nil. In `run_test.go` add `TestRunSkipsKiroCrewAgentsWithoutChannel`: with `Env` returning `KIROCREW_SPAWNED=1` and no channel, the capture server receives nothing (use the existing helpers; assert no event within 200 ms); with `KIROCREW_SPAWNED=1` and `KIROCREW_CHANNEL_ID=C0123456789`, the event arrives with `Terminal.SlackChannel == "C0123456789"`.
- [ ] **Step 2:** `make -C server test`, expect the new tests to fail.
- [ ] **Step 3:** Implement per Files.
- [ ] **Step 4:** `make -C server test`, expect PASS.
- [ ] **Step 5: Commit** `feat(mudod): record the Slack channel of KiroCrew sessions`.

### Task 2: App opens the Slack channel

**Files:**
- Modify: `app/Sources/MuDoCore/TerminalInfo.swift` (`slackChannel: String?` stored property, init parameter `slackChannel: String? = nil` last; `validated()` keeps it only if it matches the channel pattern)
- Create: `app/Sources/MuDoCore/SlackLink.swift`
- Modify: `app/Sources/MuDoCore/FocusPlan.swift` (`case slack(channel: String)`, checked FIRST, before the local server: `if let ch = terminal?.slackChannel { return .slack(channel: ch) }`)
- Modify: `app/Sources/MuDo/AppModel.swift` (`open`: `.slack(channel)` opens `SlackLink.url(channel:team:)` with `settings.slackTeamID` via `NSWorkspace.shared.open`)
- Modify: `app/Sources/MuDo/LocalFocuser.swift` (`.slack` handled like `.chrome`/`.none` in `focus` and returns nil in `place(for:)`)
- Modify: `app/Sources/MuDo/AppSettings.swift`, `app/Sources/MuDo/SettingsView.swift` (setting and section per Global Constraints)
- Test: `app/Tests/MuDoCoreTests/TerminalInfoTests.swift`, `FocusPlanTests.swift`, new `SlackLinkTests.swift`, `WireTests.swift` if it decodes terminal JSON

**Interfaces (MuDoCore):**
- `public enum SlackLink { public static func url(channel: String, team: String) -> URL? }`: nil if the channel is invalid; team used only if valid (after trimming whitespace), else the `app_redirect` URL.
- `SlackLink.isChannel(_:) -> Bool`, `SlackLink.isTeam(_:) -> Bool` (patterns from Global Constraints), used by `TerminalInfo.validated()`.

- [ ] **Step 1: Failing tests.**
  - `SlackLinkTests`: `url(channel: "C0123456789", team: "T0123456789")` == `slack://channel?team=T0123456789&id=C0123456789`; `team: ""` and `team: "bad"` give `https://slack.com/app_redirect?channel=C0123456789`; `team: " T0123456789 "` uses the trimmed team; `channel: "C01&x=1"` gives nil.
  - `FocusPlanTests`: a session with `TerminalInfo(codeServer: true, slackChannel: "C0123456789")` plans `.slack(channel: "C0123456789")` on a local server and on a remote server with code-server; with `slackChannel: "nope"` it falls back to today's plan.
  - `TerminalInfoTests`: decoding `{"slack_channel":"C0123456789"}` with the decoder the app uses gives `slackChannel == "C0123456789"`; `validated()` drops `"C01;rm"`.
- [ ] **Step 2:** Run on the Mac (`MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test'`), expect failures.
- [ ] **Step 3:** Implement per Files and Interfaces.
- [ ] **Step 4:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`, expect PASS.
- [ ] **Step 5: Commit** `feat(app): open the Slack channel of KiroCrew sessions`.
