# Agent output line Implementation Plan

> **For agentic workers:** executed with `/mudo-task` (one task). Steps use checkbox (`- [ ]`) syntax.

**Goal:** The dim line under a session's name says what the agent last said, not only the last prompt. A finished session shows the agent's final reply; a waiting session shows why it waits; a running session keeps showing the prompt it works on.

**Architecture:** The hook already decodes Claude Code's `Stop` and `Notification` payloads. It now also keeps `last_assistant_message` (Stop) and `message` (Notification), cleaned to one short line. The daemon stores them on the session (`last_output`, `notice`) and sends them to the app. MuDoCore picks the line to show from the state; the view only renders it.

**Tech Stack:** Go (mudod), Swift 6 + swift-testing (MuDoCore), SwiftUI (MuDo).

## Global Constraints

- Payload fields read by the hook: on `Stop`, the first non-empty of `last_assistant_message`, `assistant_response`; on a `Notification` mapped to waiting (`permission_prompt`, `elicitation_dialog`), `message`. Kiro sends neither today; nothing changes for it.
- `model.Event` gains `Output string \`json:"output,omitempty"\`` and `Notice string \`json:"notice,omitempty"\``. `model.Session` gains `LastOutput string \`json:"last_output,omitempty"\`` and `Notice string \`json:"notice,omitempty"\``.
- Cleaning (`hook.OneLine(s string, n int) string`, output limit `outputLimit = 160`, notice limit `promptLimit` = 80): drop lines that are code fences (trimmed line starts with "```"); on each remaining line strip leading Markdown markers (`#` runs, `>`, `-`, `*`, `+`, `1.`-style numbering, each followed by a space); remove `**`, `__` and backticks anywhere; then `Truncate(s, n)` (collapse whitespace, cut with "…").
- Machine rules:
  - `EvStop` with non-empty `Output` sets `LastOutput`.
  - `EvPrompt` clears `LastOutput` (a new turn; a later Stop without output must not show the previous turn's reply).
  - `EvWaiting` with non-empty `Notice` sets `Notice`.
  - Whenever the resulting state is not `waiting`, `Notice` is cleared.
  - A new session (prev nil) takes `LastOutput` from a Stop event's `Output` and `Notice` from a waiting event's `Notice`.
  - Each of these counts as a change only when the value differs.
- App: `Session` gains `lastOutput: String?` and `notice: String?` (absent from older mudod → nil), init parameters default nil. New `public enum SessionLine { public static func text(for s: Session) -> String }` in MuDoCore:
  - `.waiting` and non-empty notice → notice;
  - `.done`, `.idle` or `.ended` and non-empty lastOutput → lastOutput;
  - else `lastPrompt`.
- View (`Views.swift` session row): the dim line shows `SessionLine.text(for:)` when non-empty, same font/style/lineLimit(1) as today, plus `.help(<same text>)` so hovering shows it whole.
- README: in Usage, one sentence: the line under a session shows the agent's last reply when it is done, why it waits when it waits, and the prompt while it runs (Claude Code; Kiro shows the prompt).
- Tests never touch the real `$HOME`; no real data in fixtures (use made-up text).

---

### Task 1: Show the agent's last reply under the session

**Files:**
- Modify: `server/internal/model/model.go`, `server/internal/hook/normalize.go` (+ `normalize_test.go`), `server/internal/machine/machine.go` (+ `machine_test.go`)
- Modify: `app/Sources/MuDoCore/Wire.swift`; Create: `app/Sources/MuDoCore/SessionLine.swift`, `app/Tests/MuDoCoreTests/SessionLineTests.swift`; Modify: `app/Tests/MuDoCoreTests/WireTests.swift`
- Modify: `app/Sources/MuDo/Views.swift`, `README.md`

- [ ] **Step 1: Failing tests.**
  - Go `normalize_test.go`: Claude Stop with `last_assistant_message` "## Done\n\n**Pushed** `main`.\n```\ngit log\n```\n- PR open" → `Output` "Done Pushed main. PR open"; Stop with `assistant_response` used when the other is absent; Stop without either → empty; permission_prompt Notification with `message` "Claude needs your permission to use Bash" → `Notice` set; a 300-rune reply is cut to 160 runes ending "…".
  - Go `machine_test.go`: Stop with output sets LastOutput (changed=true), same output again → changed=false; Prompt clears it; Waiting sets Notice; Tool after waiting (→ running) clears Notice; Stop from waiting clears Notice; new session from a Stop event keeps its Output.
  - Swift `SessionLineTests`: each branch of the rule (waiting+notice, waiting without notice → prompt, done+output, idle+output, ended+output, running+output → prompt, done with empty output → prompt). `WireTests`: decoding `last_output`/`notice`, and their absence → nil.
- [ ] **Step 2:** `cd server && go test ./...` and `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test'`, expect failures.
- [ ] **Step 3:** Implement per Global Constraints.
- [ ] **Step 4:** `make -C server test` and `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`, expect PASS, no warnings.
- [ ] **Step 5: Commit** `feat: show the agent's last reply under each session`.
