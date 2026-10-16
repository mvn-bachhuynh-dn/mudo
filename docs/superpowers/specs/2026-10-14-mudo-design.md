# MuDo — Design Spec

Date: 2026-10-14
Status: Approved in brainstorming, pending written-spec review

## 1. Goal

Personal tool. Show, in a small always-on-top widget on a MacBook, the state of every Claude Code and Kiro CLI session running on remote Linux servers, so the user never forgets a finished agent while working on something else.

Success criteria:

- A session that finishes is visible in the widget within 1 second.
- A session finished and untouched for N minutes (default 5) blinks until the user acts on it.
- Dead sessions (crash, closed terminal) never linger as "running".
- Mac sleep/wake and server restarts do not lose or corrupt state.

Non-goals (YAGNI): macOS notifications, sounds, repeated reminders, iOS app, history/analytics, controlling agents remotely, Kiro IDE support.

## 2. Context and constraints

- Mac app: macOS 26.5.1 (25F80) and later. App name: **MuDo**.
- Agents run on Linux servers inside the integrated terminal of **code-server** (VS Code in the browser). No tmux.
- Agents: Claude Code CLI and **Kiro CLI** (`kiro-cli`, V3 hook format).
- Network: Mac and servers share a private network or Tailscale.
- Today one server (`devbox`, the machine where the agents and code-server run, Tailscale `100.64.0.10`); more will be added later. The app supports a list of servers from day one.

## 3. Architecture

```
Server (each one)                                         MacBook
┌───────────────────────────────────────────┐
│ claude / kiro-cli                          │
│   └─ hook: `mudod hook --agent X`          │
│        └─ POST 127.0.0.1:7878/event        │
│                    ▼                       │
│ mudod serve  (systemd --user)              │
│   - session map + state machine            │
│   - PID liveness check every 10s           │
│   - persist ~/.local/state/mudo/state.json │      ┌──────────────────────┐
│   - API on <tailscale-ip>:7879 (token) ────┼─SSE─▶│ MuDo.app (SwiftUI)   │
└───────────────────────────────────────────┘      │  one connection per  │
                                                    │  configured server   │
                                                    └──────────────────────┘
```

Two deliverables:

1. `mudod` — single static Go binary (linux/amd64), no runtime dependencies.
2. `MuDo.app` — SwiftUI macOS app, no third-party dependencies.

## 4. Server: `mudod`

One binary, four subcommands.

### 4.1 `mudod hook --agent claude|kiro`

Invoked by the agent's hook system on each relevant event.

1. Read the hook JSON from stdin (bounded to 1 MB).
2. Normalize into an event: `agent`, `session_id`, `cwd`, `event` (normalized name), `prompt` (truncated to 80 chars, only for prompt-submit), `pid`.
3. Find the agent PID by walking up the process tree from `getppid()` via `/proc/<pid>/stat` and `/proc/<pid>/comm` until a process named `claude`, `node` running claude, or `kiro-cli` is found. Fallback: direct parent PID.
4. POST the event to `http://127.0.0.1:7878/event` with a 500 ms total timeout.
5. **Always exit 0 and print nothing to stdout or stderr.** Reason: Kiro adds hook stdout to the agent context and treats non-zero exit on prompt-submit as "block the prompt". Errors go to `~/.local/state/mudo/hook.log` (rotated at 1 MB).

Debug aid: `MUDO_HOOK_DUMP=1` appends the raw stdin payload to `hook.log`. Used once during implementation to confirm Kiro's real field names (Kiro docs do not publish the stdin schema; expected fields mirror Claude: `hook_event_name`, `session_id`, `cwd`, `prompt`).

Event mapping:

| Normalized event | Claude Code hook | Kiro CLI V3 trigger |
|---|---|---|
| `session_start` | `SessionStart` | `SessionStart` |
| `prompt` | `UserPromptSubmit` | `UserPromptSubmit` |
| `tool` | `PreToolUse` | `PreToolUse` |
| `waiting` | `Notification` (`notification_type` = `permission_prompt` or `elicitation_dialog`) | — (not available) |
| `stop` | `Stop` | `Stop` |
| `session_end` | `SessionEnd` | — (not available; PID check covers it) |

`PreToolUse` is included so a session resumes `running` after a permission prompt is approved. To keep it cheap the hook does the same work as for other events; the daemon drops it when the state is already `running`.

Missing `session_id` (should not happen): use `"<agent>-<pid>"`.

### 4.2 `mudod serve`

Long-running daemon, installed as a systemd user unit (`mudod.service`, `Restart=always`).

Listeners:

- `127.0.0.1:7878` — ingest only (`POST /event`). Not reachable from the network.
- `<bind-addr>:7879` — client API, default bind = the host's Tailscale IPv4 (`tailscale ip -4` at install time), configurable in `~/.config/mudo/config.toml`.

Session record:

```
id, agent ("claude"|"kiro"), host, cwd, project (basename of cwd),
state, state_since (UTC), pid, last_prompt (≤80 chars), updated_at
```

State machine:

| From | Event | To |
|---|---|---|
| any | `session_start` | `idle` |
| any | `prompt` | `running` (also sets `last_prompt`) |
| `waiting`, `idle`, `done` | `tool` | `running` |
| `running` | `waiting` | `waiting` |
| `running`, `waiting` | `stop` | `done` |
| `done` | ack (API) | `idle` |
| any | `session_end` | `ended` |
| any | PID not alive | `ended` |

Notes:

- Unknown session receiving any event is created on the fly (covers daemon started after the agent), starting in the event's natural state: `session_start` → `idle`, `prompt`/`tool` → `running`, `waiting` → `waiting`, `stop` → `done`, `session_end` → `ended`.
- `state_since` changes only when `state` changes.
- Liveness: every 10 s check `/proc/<pid>` exists and its start time matches the one recorded at first sight (guards against PID reuse).
- `ended` sessions are deleted after 1 h.
- Persistence: write `state.json` atomically (temp file + rename) on every change, debounced 200 ms. Load on start, then run one liveness pass immediately.

Concurrency: the session map is guarded by one mutex; every mutation broadcasts to subscribers while holding it, so the order of updates is the same for every subscriber. SSE subscribers each have a buffered channel; a slow subscriber whose buffer fills is disconnected (it will reconnect and get a fresh snapshot).

### 4.3 `mudod install`

Idempotent, one-time setup on a server:

1. Copy the binary to `~/.local/bin/mudod`.
2. Generate a 32-byte random token, write `~/.config/mudo/config.toml` (mode 0600) with token, bind address, ports.
3. Write and enable `~/.config/systemd/user/mudod.service`; run `loginctl enable-linger` hint if lingering is off (print the command, do not run sudo).
4. Merge hooks into `~/.claude/settings.json` (back up to `settings.json.mudo-bak-<timestamp>` first). Entries for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Notification`, `Stop`, `SessionEnd`, each `{"type":"command","command":"<abs-home>/.local/bin/mudod hook --agent claude"}` (absolute path; `~` is not guaranteed to expand in every hook runner). Existing hooks are preserved; re-running does not duplicate.
5. Write `~/.kiro/hooks/mudo.json` (V3 format, `"version": "v1"`) with hooks for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`, command `<abs-home>/.local/bin/mudod hook --agent kiro`, timeout 2 s.
6. Print the connection line for the Mac app: `mudo://add?name=<hostname>&url=http://<ip>:7879&token=<token>`.

`mudod uninstall` reverses steps 3–5 (removes only MuDo's own hook entries).

### 4.4 `mudod fake`

Development aid: runs a server on the API port that emits scripted fake sessions cycling through all states. Lets the Mac UI be built without real agents.

## 5. Protocol (app ↔ daemon)

- Transport: plain HTTP over Tailscale/private network (Tailscale already encrypts). All requests carry `Authorization: Bearer <token>`; mismatch → 401.
- Versioned under `/v1`.

Endpoints:

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/stream` | SSE stream |
| POST | `/v1/sessions/{id}/ack` | `done` → `idle`; 204, or 404 if unknown, 409 if not `done` |
| GET | `/v1/health` | `{"version":"x.y.z","uptime_s":123}` |

SSE events (each `data:` is one JSON object, every message includes `server_now`):

- `snapshot` — sent first on every connect: `{"server_now": "...", "host": "...", "sessions": [Session, ...]}`
- `upsert` — `{"server_now": "...", "session": Session}`
- `remove` — `{"server_now": "...", "id": "..."}`
- `ping` — every 15 s, `{"server_now": "..."}`

Session JSON:

```json
{"id":"a1b2","agent":"claude","host":"devbox","project":"api-gateway",
 "cwd":"/home/steve/code/api-gateway","state":"done",
 "state_since":"2026-10-14T09:12:03Z","last_prompt":"refactor auth middleware..."}
```

`state` ∈ `idle | running | waiting | done | ended`. `stale` is not a server state; the app derives it.

Clock skew: the app stores `offset = server_now − local_now` per server on each message and converts `state_since` to local time with it.

## 6. Mac app: MuDo

### 6.1 Window

- `NSPanel` with `.nonactivatingPanel`, level `.floating`, collection behavior `canJoinAllSpaces` + `fullScreenAuxiliary`, hosting SwiftUI content. Clicking it never steals focus.
- Draggable anywhere on the panel background; position saved in `UserDefaults`. On launch / screen change, if the saved frame is off all screens, move it to the main screen's top-right corner.
- `LSUIElement = YES` (no Dock icon). Menu bar item with: Settings…, Pause blinking (1 h), Quit.
- Liquid Glass background (macOS 26 `glassEffect`).

### 6.2 Views

Collapsed (default): a pill with counts per bucket — running, waiting, done. Pill blinks if any session is stale and not snoozed. Pill turns grey with "offline" when all servers are disconnected.

Expanded (on hover, collapses 1.5 s after the pointer leaves; click on pill pins it open until clicked again): one row per session.

```
╭───────────────────────────────────╮
│ ◐ api-gateway   claude  2m        │  waiting (orange)
│   refactor auth middle…           │
│ ● web-ui        kiro    12s       │  running (blue, animated)
│ ✱ infra-tf      claude  7m     ⏸  │  stale (green, blinking)
│ ✓ billing       claude  1m        │  done (green)
│ ○ docs          claude  idle      │  idle (dim)
│ ─ devbox2 offline ─────────────── │
╰───────────────────────────────────╯
```

- Row: state icon, project, agent, elapsed time in current state, second line `last_prompt` (one line, truncated). Host shown as a small suffix only when more than one server is configured.
- Sort: waiting → stale → done → running → idle; within a bucket, oldest `state_since` first.
- `ended` sessions are hidden.
- Click a row: POST ack (if `done`), clear local snooze, then bring the session's code-server tab to front (see 6.4).
- ⏸ button (only on blinking rows): snooze that session for the configured snooze duration.
- Blinking: opacity pulse at 1 Hz; respects "Reduce Motion" (falls back to a steady bright outline).

### 6.3 Stale and snooze rules (in `SessionStore`)

- `stale(s) = s.state == done && now − s.state_since ≥ N` (N default 5 min).
- A session blinks when `stale(s)` and not `snoozedUntil[s.id] > now` and global pause is off.
- Snooze expiry makes it blink again if still stale.
- Snooze entries are dropped when the session leaves `done` or disappears.
- A 1 s timer drives re-evaluation of elapsed times and stale state.

### 6.4 Focus the session's Chrome window

Goal: clicking a session brings to front the Chrome window (and tab) already showing that session's code-server workspace; if it was closed, reopen it automatically.

User setup: each project is opened in its own regular Chrome window (normal tabs, not a PWA).

Mechanism: AppleScript (Apple Events) to Google Chrome, run from a `ChromeTabFocuser` component via `NSAppleScript` off the main thread.

Steps:

1. Build the target URL `<code-server-url>/?folder=<cwd>` (cwd percent-encoded the way code-server does).
2. Enumerate `every window` → `every tab` of Chrome, match in order:
   a. tab URL starts with the configured code-server URL and its `folder` query parameter (decoded) equals the session's `cwd`;
   b. otherwise, tab URL starts with the code-server URL and the tab title contains ` — <project> — ` (code-server title format `<file> — <folder name> — code-server`).
   First match wins.
3. On match: set the window's `active tab index` to that tab, set the window `index` to 1, then `activate` Chrome.
4. No match (window was closed): via AppleScript `make new window`, set its active tab URL to the target URL, then `activate` Chrome. A new window, not a tab, matches the one-window-per-project habit. Chrome not running: `open -na "Google Chrome" --args --new-window <url>`. Chrome not installed: open in the default browser.

Requirements and behavior:

- `Info.plist` declares `NSAppleEventsUsageDescription`; app is not sandboxed. macOS asks for Automation permission once on first use.
- If permission is denied (error -1743), fall back to step 4 and show a one-time hint in the menu bar item pointing to System Settings → Privacy & Security → Automation.
- No JavaScript is executed in pages, so Chrome's "Allow JavaScript from Apple Events" is not needed.
- Works across Chrome profiles (all windows are visible to AppleScript).
- Two sessions in the same folder resolve to the same tab; focusing the specific terminal inside code-server is out of scope for v1 (possible v2: a code-server extension that matches the agent PID to `terminal.processId` and calls `terminal.show()`).
- Only regular Chrome windows/tabs are targeted; PWA windows are out of scope.
- If the matched window is minimized, un-minimize it (`set minimized of window to false`) before raising.

### 6.5 Settings

- Servers list: name, daemon URL, token (stored in Keychain, keyed by server id), code-server URL. Add manually, or paste/open a `mudo://add?...` link.
- Stale after: N minutes (default 5).
- Snooze duration: minutes (default 10).
- Launch at login (`SMAppService.mainApp`).

### 6.6 Code structure

- `ServerConnection` (one per server): SSE client on `URLSession.bytes(for:)`, parses events, exponential reconnect 1 s → 30 s max, immediate reconnect on `NSWorkspace.didWakeNotification` and on network path change (`NWPathMonitor`). Publishes `connected/disconnected` and session updates.
- `SessionStore` (`@Observable`, main actor): merges sessions from all servers keyed by `(serverId, sessionId)`, applies snapshot (replace all for that server) / upsert / remove, holds clock offsets, snooze map, computes buckets, sort order, blink flags. Takes an injectable `Clock` for tests.
- `APIClient`: ack call.
- `ChromeTabFocuser`: AppleScript tab lookup and focus with fallbacks (6.4); tab-matching logic is a pure function over `[(windowIndex, tabIndex, url, title)]` so it is unit-testable.
- `Views`: `PillView`, `SessionListView`, `SessionRowView`, `SettingsView` — rendering only, no logic.
- `PanelController`: NSPanel setup, drag, position persistence, hover expand/collapse.

### 6.7 Error handling

- Server unreachable: keep its last known sessions, render them dimmed with a "?" marker, show an "<name> offline" row; no blinking for sessions of an offline server (state may be outdated).
- 401: mark server "token invalid" in the offline row; stop reconnecting until settings change.
- Ack fails: still open code-server; retry ack once on next snapshot if the session is still `done`.
- Malformed SSE message: log and skip.

## 7. Testing

Go (`mudod`):

- Unit: state machine transition table (every row in 4.2), hook payload normalization for Claude and Kiro samples, PID tree walk against a fake `/proc` directory.
- Integration: start `serve` on random ports, send hook events through `mudod hook`, assert SSE `snapshot`/`upsert` sequence; restart the daemon and assert persisted state reloads; kill a child process and assert it goes `ended`.
- Install: run `install` against a temp `$HOME` with an existing `settings.json`, assert merge, backup, idempotency, and `uninstall` cleanup.

Swift (`MuDo`):

- `SessionStore` unit tests with a fake clock: stale threshold, snooze/expiry, pause, sort order, snapshot replace, offline behavior, clock-offset conversion.
- SSE parser unit tests (multi-line data, keep-alive, partial chunks).
- Tab-matching unit tests: folder query match, percent-encoded paths, title fallback, no match, code-server URL prefix mismatch.
- Manual check: Automation permission prompt, denied-permission fallback, tab focus across two Chrome windows.
- Manual UI check against `mudod fake`.

## 8. Distribution

- `mudod`: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build`, then `scp` to the server and run `mudod install`.
- `MuDo.app`: Xcode project, ad-hoc signed, no notarization. First launch via right-click → Open.

## 9. Repository layout

```
must-do/
  server/            Go module for mudod
  app/               Xcode project for MuDo
  docs/superpowers/specs/
```

## 10. Open items to verify during implementation

- ~~Kiro CLI stdin field names~~ Verified 2026-10-16 (kiro-cli 2.22.0, KAS 0.66.0) with `MUDO_HOOK_DUMP=1`: payload is snake_case like Claude: `session_id` (`sess_<uuid>`), `hook_event_name`, `cwd`, `prompt` (UserPromptSubmit), `tool_name` (PreToolUse, e.g. `read_file`). All four triggers fire from `~/.kiro/hooks/mudo.json`; PreToolUse needs no matcher. Hooks do NOT fire with `kiro-cli chat --no-interactive`, only in the interactive TUI, so headless Kiro runs are invisible to MuDo.
- Install on a host where the user is not logged in through PAM (e.g. code-server run as a system service) needs `sudo loginctl enable-linger <user>` and `XDG_RUNTIME_DIR=/run/user/<uid>`, or `systemctl --user` fails with "Failed to connect to bus". Claude end to end verified the same day: idle, running, done, ended; already-running Claude sessions picked up the new hooks without a restart.
- ~~Process name of the Claude Code CLI~~ Verified 2026-10-16 on `devbox`: `comm` = `claude`. Kiro V3 runs as `kiro-cli` → `kiro-cli-chat`.
- ~~Whether code-server keeps `?folder=`~~ Verified 2026-10-16: code-server tabs keep `?folder=<cwd>` (sometimes percent-encoded). Titles use ` — ` but newer VS Code defaults to ` - `; the matcher accepts both, and also matches the deepest ancestor folder of the session cwd.
- Session cwd: Claude hook `cwd` is the agent's *current* directory and drifts when it runs `cd`. mudod now takes the cwd from `/proc/<agent pid>/cwd` (the launch directory) when the agent process is found by name.
- Network (devbox): org-managed Cloudflare WARP drops all IPv4 `100.64.0.0/10` traffic off its tunnel (nft table `inet cloudflare-warp`), so Tailscale IPv4 is unusable from that host. Tailscale IPv6 (`fd7a:115c:a1e0::/48`) works; mudod listens on `[::]:7879` (ufw allows 7879 on tailscale0 and the LAN NIC) and the Mac uses `http://[fd7a:115c:a1e0::10]:7879`.
- Chrome with ~200 tabs: per-tab AppleScript property reads took ~5 s; reading `URL of every tab`/`title of every tab` per window takes ~200 ms.
- Background agents without a code-server window (KiroCrew `*/kirocrew-workspace/_bg*`, `/tmp/*`) are hidden by default via Settings → Hidden sessions.
- Testing aid: `mudo://focus?project=<name>` or `?session=<id>` triggers the same action as clicking a row (used to test over SSH).
