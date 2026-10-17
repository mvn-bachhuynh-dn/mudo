# MuDo: local Mac and SSH sessions — design

Date: 2026-10-17. Extends the [MuDo design](2026-10-14-mudo-design.md).

## 1. Goal

Today MuDo watches agents on Linux servers and, on click, focuses the code-server tab in Chrome. This adds two cases:

1. **Local:** Claude Code / Kiro CLI sessions running on the Mac itself, shown in the same widget, next to remote ones.
2. **SSH:** sessions on a remote server that the user reached with plain `ssh` from a Mac terminal instead of code-server.

Monitoring (pill, rows, states) must work for both. A click on a row must bring the right place to the front:

| Session runs in | Click focuses |
|---|---|
| code-server terminal on a server | the code-server tab in Chrome (unchanged) |
| local iTerm2 / Terminal.app | the exact tab/session (by TTY) |
| local Ghostty 1.3+ | the exact terminal (by TTY on 1.4+, else by working directory) |
| local VS Code / Cursor integrated terminal | the window of that project |
| local tmux (in any of the above) | the tmux window and pane, then the terminal tab of the attached client |
| `ssh` from a local terminal tab | that terminal tab |

When the exact target cannot be found, the click activates the owning app (never opens a new window or tab).

Non-goals: Linux or Windows desktop app; focusing the exact terminal inside one VS Code window; selecting the tmux pane on a *remote* server; Warp, Alacritty, kitty, WezTerm beyond app activation; SSH ControlMaster multiplexing and mosh (they fall back to app activation).

Prior art reviewed (all MIT): claude-control, onikan27/claude-code-monitor, cc-status-bar, claude-ghostty-notify. MuDo borrows their techniques (TTY matching via AppleScript, editor window by project name, Ghostty terminal walk) but keeps its own architecture, since none of them covers remote servers, Kiro or code-server.

## 2. Overview

```
 Mac                                                   Linux server
 ┌───────────────────────────────────────────┐        ┌──────────────────────┐
 │ claude/kiro ─hook─▶ mudod (LaunchAgent)   │        │ claude/kiro ─hook─▶  │
 │   (terminal info:   127.0.0.1:7879        │        │   mudod (systemd)    │
 │    TERM_PROGRAM,          │ SSE            │        │   (terminal info:    │
 │    tty, iTerm id, tmux)   ▼                │  SSE   │    SSH_CONNECTION)   │
 │                 MuDo.app ◀────────────────┼────────┤                      │
 │   click ─▶ Focuser: Chrome │ Local │ SSH   │        └──────────────────────┘
 └───────────────────────────────────────────┘
```

The hook already runs inside the agent's process tree, so it inherits the agent's environment. It records where the agent runs (`terminal`), the daemon stores it on the session, and the app picks a focus strategy from it.

## 3. mudod on macOS

### 3.1 Process inspection (`internal/proc`)

Split by build tag. `proc_linux.go` holds today's `/proc` code unchanged. `proc_darwin.go` implements the same `FS` methods (`Stat`, `Cwd`, `FindAgent`, `Alive`, `cmdline`) with `Root` ignored:

- `Stat(pid)`: `unix.SysctlKinfoProc("kern.proc.pid", pid)` from `golang.org/x/sys/unix` (no cgo). `Comm` = `P_comm`, `PPID` = `Eproc.Ppid`, `StartTime` = `P_starttime` as microseconds since the epoch, `State` = `"Z"` when `P_stat == 5` (SZOMB), else `"R"`.
- `cmdline(pid)`: `unix.SysctlRaw("kern.procargs2", pid)`; skip the leading argc and exec path, join the NUL-separated args with spaces.
- `Cwd(pid)`: run `lsof -a -p <pid> -d cwd -Fn` and take the `n` line. Parsing lives in a pure function `parseLsofCwd(out string) (string, error)` shared by both builds so it is tested on Linux.
- `FindAgent`, `Alive`, `isAgent` stay in a shared file; they only call the methods above.

`fake.go` keeps working for tests. Sweep (every `sweepEvery`, unchanged) calls `Cwd` once per live session; `lsof` costs ~30–80 ms, acceptable for the handful of sessions a Mac runs.

### 3.2 Install on darwin (`internal/install`)

`install.Run` picks a service manager by `runtime.GOOS` through an injectable `Options.GOOS` (tests set it):

- **linux:** unchanged (systemd unit, linger warning).
- **darwin:** write `~/Library/LaunchAgents/dev.mudo.mudod.plist` (mode 0644):
  - `Label` `dev.mudo.mudod`, `ProgramArguments` `[<bin>, "serve"]`, `RunAtLoad` true, `KeepAlive` true, `StandardOutPath`/`StandardErrorPath` `~/Library/Logs/mudod.log`.
  - Then `launchctl bootout gui/<uid>/dev.mudo.mudod` (error ignored: not loaded yet) and `launchctl bootstrap gui/<uid> <plist>`.
  - No linger check.
  - New config defaults `api_addr` to `127.0.0.1:7879` (an existing config is kept as on Linux). The link uses it as is.
  - The link `name` is `This Mac`.
- `Uninstall` on darwin: `launchctl bootout`, remove the plist, remove hooks (same hook code as Linux).

`paths.Paths` gains `LaunchAgent` and `LaunchLog`. The binary is still copied to `~/.local/bin/mudod`, so hook commands keep a stable path when MuDo.app moves.

New flag `mudod install --link-only`: prints only the `mudo://add?...` link on stdout (warnings go to stderr). The app parses this.

### 3.3 Build

`server/Makefile` `build` also produces `dist/mudod-darwin-arm64` (`CGO_ENABLED=0 GOOS=darwin GOARCH=arm64`). CI-free check: `GOOS=darwin go vet ./...` runs in `make test`.

## 4. Terminal info from the hook

### 4.1 Model

```go
// Terminal records where the agent runs, as seen by its hook.
type Terminal struct {
	Program       string `json:"program,omitempty"`        // TERM_PROGRAM: iTerm.app, Apple_Terminal, ghostty, vscode, tmux
	TTY           string `json:"tty,omitempty"`            // agent's controlling tty, e.g. /dev/ttys004 (darwin only)
	ITermSession  string `json:"iterm_session,omitempty"`  // ITERM_SESSION_ID, part after ':' (the unique id)
	TmuxSocket    string `json:"tmux_socket,omitempty"`    // first field of TMUX
	TmuxPane      string `json:"tmux_pane,omitempty"`      // TMUX_PANE, e.g. %3
	SSHClientPort int    `json:"ssh_client_port,omitempty"` // client port from SSH_CONNECTION
	SSHClientIP   string `json:"ssh_client_ip,omitempty"`
}
```

`Event` and `Session` gain `Terminal *Terminal \`json:"terminal,omitempty"\``. The machine copies a non-nil event `Terminal` onto the session (latest wins). Older app builds ignore the field.

### 4.2 Capture (`internal/hook/terminal.go`)

`CaptureTerminal(env func(string) string, tty func(pid int) string, sshFromTmux func(socket string) string, agentPID int) *Terminal`. All inputs injected for tests. Returns nil when nothing is known.

- `Program`, `ITermSession`, `TmuxSocket`, `TmuxPane` straight from the environment.
- `TTY` (darwin): `ps -o tty= -p <agentPID>`, prefixed with `/dev/` when not `??`. On Linux it is left empty.
- SSH: parse `SSH_CONNECTION` (`clientIP clientPort serverIP serverPort`). Inside tmux on a server this value is stale (from when the tmux server started), so when `TMUX` is set the hook asks tmux for the most recently active client: `tmux -S <socket> list-clients -F '#{client_activity} #{client_pid}'`, takes the highest activity, and reads `SSH_CONNECTION` from `/proc/<client_pid>/environ` (Linux). If that fails, SSH fields stay empty.

Capture errors are ignored (logged only with `MUDO_HOOK_DUMP`), as with the rest of the hook.

## 5. App

### 5.1 Wire

`Session` decodes an optional `terminal` (`TerminalInfo`, same fields, snake_case keys). `ServerConfig.isLocal` is true when the daemon URL host is `127.0.0.1`, `::1` or `localhost`.

### 5.2 Choosing a focus strategy (`MuDoCore/FocusPlan.swift`, pure)

```swift
enum FocusPlan: Equatable {
    case chrome(codeServer: URL, cwd: String, project: String)
    case local(TerminalInfo, cwd: String, project: String)
    case ssh(port: Int, cwd: String, project: String)
    case none
}
static func plan(server: ServerConfig, session: Session) -> FocusPlan
```

Rules, first match wins:
1. Server is local → `.local` (terminal may be nil: then the app activation fallback in 5.3 has nothing to go on and returns not-found).
2. `terminal.program == "vscode"` and the server has a code-server URL → `.chrome` (code-server terminals report `vscode`).
3. `terminal.sshClientPort > 0` → `.ssh`.
4. Server has a code-server URL → `.chrome`.
5. `.none`.

### 5.3 Local focus (`MuDo/LocalFocuser.swift`)

Input: a TTY (or terminal info) plus cwd and project. Steps:

1. **tmux first.** If `tmuxPane` is set: `tmux -S <socket> select-window -t <pane>` and `select-pane -t <pane>`. Then the TTY to focus becomes the most recently active client's: `tmux -S <socket> list-clients -F '#{client_activity} #{client_tty}'`.
2. **Find the owning app** of the TTY: `ps -t <tty> -o pid=,ppid=,comm=` gives the processes on it. Walk parents with `ps -o ppid=,comm= -p` until a path contains `.app/Contents/MacOS/`. Map the bundle to a kind: `iTerm2`, `Terminal`, `Ghostty`, `VSCodeLike` (Visual Studio Code, Cursor, Windsurf, VSCodium), `Other`. Pure parsing helpers in `MuDoCore/ProcessTree.swift` (tested).
3. **Focus by kind** (AppleScript via `NSAppleScript`, off the main thread, with the same in-flight guard as `ChromeTabFocuser`):
   - iTerm2: walk windows → tabs → sessions; match `unique id` = `iTermSession`, else `tty` = TTY; `select` the session and its tab and window, `activate`.
   - Terminal.app: walk windows → tabs; match `tty`; set `selected tab`, set the window `index` to 1, `activate`.
   - Ghostty: walk windows → tabs → terminals; match `tty` if the property exists (1.4+), else `working directory` = cwd; `focus` the terminal, `activate`. A script error on `tty` falls back to the cwd script.
   - VSCodeLike: System Events, process of the app; pick the window whose title matches the project using `TabMatcher`'s title rules (deepest path component of cwd first); `AXRaise` it, activate the app. Needs the Accessibility permission; without it, activate the app only.
   - Other / no match: activate the app.
4. Scripts are generated by pure functions in `MuDoCore/TerminalScripts.swift` so they are unit tested (escaping, fields).

Permissions: macOS asks once per app for Automation (iTerm2, Terminal, Ghostty, System Events) and once for Accessibility (VS Code windows). Denials are logged and fall back to activation, like the Chrome focuser.

### 5.4 SSH focus

`.ssh(port:)`: `lsof -nP -a -c ssh -iTCP -sTCP:ESTABLISHED -F pn` lists local ssh processes with their connections; pick the one whose **local** port equals `port` (parse `n<local>-><remote>`, pure function in `ProcessTree.swift`). Its TTY (`ps -o tty= -p <pid>`) then goes through 5.3 steps 2–3. No match (NAT changed the port, ControlMaster, mosh): if exactly one local `ssh` process is connected to the server's host, use it; otherwise activate the frontmost terminal app among iTerm2/Terminal/Ghostty that is running.

### 5.5 "Monitor this Mac"

- `make app` cross-builds `mudod-darwin-arm64` (on the Linux side or the Mac, whichever runs `make`; Go is only needed where it runs) into `MuDo.app/Contents/Resources/mudod` and signs it with the same identity before the app is signed.
- Settings gains a toggle **Monitor this Mac**.
  - On: run `Resources/mudod install --link-only`, parse the link with the existing `AddLink`, add (or update) the server named `This Mac`. Errors are shown in Settings with the command output.
  - Off: run `~/.local/bin/mudod uninstall` and remove the `This Mac` server.
  - The toggle state is derived from whether a local server exists.
- On app launch, if a local server exists and the bundled `mudod` is newer than `~/.local/bin/mudod` (compare `mudod version`), re-run install to upgrade.

## 6. Error handling

- Hook capture never blocks or fails the hook; missing fields just mean weaker focus.
- Focus never opens new windows or tabs. Every failed step ends in app activation, and a log line under the `focus` category records which step failed.
- `launchctl` failures surface as install errors with output, like `systemctl` today.

## 7. Testing

Go (all run on Linux):
- `parseLsofCwd`, kinfo-to-`Stat` conversion (pure function over the struct fields), `procargs2` parsing.
- Plist content; darwin install/uninstall with fake exec (`launchctl` calls in order, no systemd calls); `--link-only` output.
- `CaptureTerminal` with fake env/tty/tmux: iTerm, Terminal, Ghostty, vscode, tmux, ssh, stale ssh inside tmux, nothing.
- Machine copies `Terminal` onto the session; JSON round trip.
- `GOOS=darwin go vet ./...`.

Swift (`swift test` on the Mac):
- `TerminalInfo` decoding, `ServerConfig.isLocal`.
- `FocusPlan.plan` for each rule.
- `ProcessTree` parsing (`ps` output, app bundle detection, `lsof -F` local-port match).
- `TerminalScripts` output for each terminal.

Manual on the Mac, via `mudo://focus?session=<id>`: one session in each of iTerm2, Terminal.app, Ghostty, VS Code, tmux-in-iTerm2, and `ssh devbox` from iTerm2 with and without tmux on the server.

## 8. Rollout order

1. proc darwin + build (server).
2. install darwin + `--link-only` (server).
3. Terminal capture in hook + model + machine (server).
4. Wire + `FocusPlan` + `ProcessTree` + `TerminalScripts` (MuDoCore).
5. `LocalFocuser` + SSH focus wired into `AppModel` (app).
6. Bundled mudod + Monitor this Mac toggle + Makefile (app).
7. README updates and manual verification.
