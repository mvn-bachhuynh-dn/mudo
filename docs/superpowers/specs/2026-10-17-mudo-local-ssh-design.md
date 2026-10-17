# MuDo: local Mac and SSH sessions — design

Date: 2026-10-17. Extends the [MuDo design](2026-10-14-mudo-design.md). Revised after a `/mudo-spec-review` pass (34 confirmed findings folded in).

## 1. Goal

Today MuDo watches agents on Linux servers and, on click, focuses the code-server tab in Chrome. This adds two cases:

1. **Local:** Claude Code / Kiro CLI sessions running on the Mac itself, shown in the same widget, next to remote ones.
2. **SSH:** sessions on a remote server that the user reached with plain `ssh` from a Mac terminal instead of code-server.

Monitoring (pill, rows, states) must work for both. A click on a row brings the right place to the front:

| Session runs in | Click focuses |
|---|---|
| code-server terminal on a server | the code-server tab in Chrome (unchanged) |
| local iTerm2 / Terminal.app | the exact tab/session (by TTY) |
| local Ghostty 1.3+ | the exact terminal (by TTY on 1.4+, else by a unique working-directory match) |
| local VS Code / Cursor / Windsurf / VSCodium / Kiro IDE integrated terminal | the window of that project |
| local tmux (in any of the above) | the tmux window and pane, then the terminal of a client attached to that tmux session |
| `ssh` from a local terminal tab (with or without tmux on the server) | that terminal tab |
| VS Code / Cursor Remote-SSH terminal | the local editor window of that project |

When the exact target cannot be found, the click activates the owning app; it never opens a new window or tab.

Non-goals: Linux or Windows desktop app; focusing the exact terminal inside one VS Code window; selecting the tmux pane on a *remote* server; Warp, Alacritty, kitty, WezTerm beyond app activation; SSH ControlMaster (multiplexed) connections and mosh: a click activates the terminal app, or — when only one plain ssh connection to that server exists — may land on that tab even if it is not the session's.

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

The hook runs inside the agent's process tree, so it inherits the agent's environment. It records where the agent runs (`terminal`), the daemon stores it on the session, and the app picks a focus strategy from it.

## 3. mudod on macOS

### 3.1 Process inspection (`internal/proc`)

Split by build tag. `proc_linux.go` holds today's `/proc` code. `proc_darwin.go` implements the same `FS` methods (`Stat`, `Cwd`, `cmdline`) with `Root` ignored. `FindAgent`, `Alive` and `isAgent` move to a shared `proc.go` and only call those methods.

- Dependency: `golang.org/x/sys` pinned to **v0.10.0** (already in the module cache, works with the go 1.22 toolchain; has `SysctlKinfoProc` and `SysctlRaw`). Commit `go.sum`.
- `Stat(pid)`: `unix.SysctlKinfoProc("kern.proc.pid", pid)`. `Comm` = `P_comm`, `PPID` = `Eproc.Ppid`, `StartTime` = `P_starttime` in microseconds since the epoch, `State` = `"Z"` when `P_stat == 5` (SZOMB), else `"R"`. The conversion is a pure function over those fields so it is tested on Linux.
- `cmdline(pid)`: `unix.SysctlRaw("kern.procargs2", pid)`; parse with a pure `parseProcargs2(b []byte) (exe string, args []string)` (int32 argc, exec path, NUL padding, then argc NUL-terminated args). `cmdline` returns args joined by spaces.
- `Cwd(pid)`: `/usr/sbin/lsof -a -p <pid> -d cwd -Fn` via `exec.CommandContext` with a **500 ms** timeout; take the `n` line with a pure `parseLsofCwd(out string) (string, error)`.
- `isAgent("claude")` (shared): true when `comm == "claude"`; or `comm == "node"` and the cmdline contains `claude`; or the basename of argv[0] is `claude`; or the exec path contains `/claude/versions/`. The last two cover the native installer, where `P_comm` is the version string (e.g. `2.1.144`). `isAgent("kiro")` is unchanged (`kiro` prefix).

Cost control:
- `Store.Sweep` takes a snapshot of live sessions' PIDs under `s.mu`, calls `Alive`/`Cwd` **without** the lock, then re-locks and applies each result only if the session still has the same PID and start time. This keeps ingest and SSE unblocked while `lsof` runs (applies to both OSes).
- The hook calls `Proc.Cwd` only on `session_start` events on darwin (`runtime.GOOS` check in `cmd/mudod/hook.go`, passed as an option); the sweep corrects drift within one interval. Linux keeps calling it on every event.

### 3.2 Listener

`cmd/mudod/listen_linux.go` keeps `listenFreebind`. New `cmd/mudod/listen_other.go` (`//go:build !linux`) defines `listenFreebind` as a plain `net.ListenConfig{}.Listen(ctx, "tcp", addr)`. `make test` runs `GOOS=darwin GOARCH=arm64 go build ./...` and `GOOS=darwin go vet ./...`.

### 3.3 Ingest hardening

On the Mac, a web page in the user's browser can reach `127.0.0.1:7878`. The ingest handler therefore rejects (403) any request that has an `Origin` header, a `Content-Type` other than `application/json`, or a `Host` that is not the ingest's own loopback address. `mudod hook` already sends `application/json` and no `Origin`. Applies on both OSes.

### 3.4 Install on darwin (`internal/install`)

`install.Run` picks a service manager by `Options.GOOS` (defaults to `runtime.GOOS`; tests set it):

- **linux:** unchanged (systemd unit, linger warning, Tailscale-aware link).
- **darwin:**
  - `ensureConfig` does not call `tailscale`; a new config gets `api_addr = "127.0.0.1:7879"`. An existing config is kept; if its `api_addr` is not loopback, add a warning.
  - Write `~/Library/LaunchAgents/dev.mudo.mudod.plist` (0644): `Label` `dev.mudo.mudod`, `ProgramArguments` `[<bin>, "serve"]`, `RunAtLoad` true, `KeepAlive` true, `StandardOutPath`/`StandardErrorPath` `~/Library/Logs/mudod.log`. Plist content comes from a pure function with XML-escaped paths.
  - `launchctl bootout gui/<uid>/dev.mudo.mudod` (error ignored), then `launchctl bootstrap gui/<uid> <plist>`; if bootstrap fails, retry up to 5 times, 300 ms apart (sleep injected for tests).
  - No linger check.
  - The link is always `url=http://127.0.0.1:<port>` (port from `api_addr`), `name=This Mac`.
- `Uninstall` on darwin: `launchctl bootout`, remove the plist, remove hooks (shared hook code).

`paths.Paths` gains `LaunchAgent` and `LaunchLog`. The binary is still copied to `~/.local/bin/mudod`, so hook commands keep a stable path when MuDo.app moves.

New flag `mudod install --link-only`: prints only the `mudo://add?...` link on stdout; warnings go to stderr.

### 3.5 Build hand-off

The Mac has no Go toolchain and `scripts/on-mac` syncs only `app/`. So:
- `server/Makefile` `build` also produces `dist/mudod-darwin-arm64` (`CGO_ENABLED=0 GOOS=darwin GOARCH=arm64`) and a target `app-resource` copies it to `app/Resources/mudod` (gitignored).
- `app/Makefile` `app` copies `Resources/mudod` to `MuDo.app/Contents/Resources/mudod`, codesigns it with `$(SIGN_ID)` (`--options runtime`), then signs the app as today. It fails with a clear message if `Resources/mudod` is missing.

## 4. Terminal info from the hook

### 4.1 Model

```go
// Terminal records where the agent runs, as seen by its hook.
type Terminal struct {
	Program       string `json:"program,omitempty"`         // TERM_PROGRAM: iTerm.app, Apple_Terminal, ghostty, vscode, tmux
	CodeServer    bool   `json:"code_server,omitempty"`     // VSCODE_PROXY_URI is set (code-server terminal)
	TTY           string `json:"tty,omitempty"`             // agent's controlling tty, e.g. /dev/ttys004 (darwin only)
	ITermSession  string `json:"iterm_session,omitempty"`   // ITERM_SESSION_ID, part after ':' (the unique id)
	TmuxSocket    string `json:"tmux_socket,omitempty"`     // first field of TMUX
	TmuxPane      string `json:"tmux_pane,omitempty"`       // TMUX_PANE, e.g. %3
	TmuxBin       string `json:"tmux_bin,omitempty"`        // exec.LookPath("tmux") in the agent's env (darwin only)
	SSHClientIP   string `json:"ssh_client_ip,omitempty"`   // SSH_CONNECTION field 1
	SSHClientPort int    `json:"ssh_client_port,omitempty"` // field 2
	SSHServerIP   string `json:"ssh_server_ip,omitempty"`   // field 3
	SSHServerPort int    `json:"ssh_server_port,omitempty"` // field 4
}
```

`Event` and `Session` gain `Terminal *Terminal \`json:"terminal,omitempty"\``. In `machine.Apply`:
- a new session (`prev == nil`) copies `ev.Terminal`;
- an existing session takes `ev.Terminal` when it is non-nil and differs **by value** from the stored one, and that sets `changed = true` (so it is persisted and broadcast).

Older app builds ignore the field.

### 4.2 Capture (`internal/hook/terminal.go`)

`CaptureTerminal(env func(string) string, deps TerminalDeps, agentPID int) *Terminal`, where `TerminalDeps` holds injectable `TTY func(pid int) string`, `LookPath func(string) (string, error)` and `TmuxClientSSH func(bin, socket string) string`. Returns nil when nothing is known. Errors are ignored (logged only with `MUDO_HOOK_DUMP`).

- `Program`, `ITermSession`, `TmuxSocket`, `TmuxPane` from the environment; `CodeServer = VSCODE_PROXY_URI != ""`.
- darwin only: `TTY` via `/bin/ps -o tty= -p <agentPID>`, prefixed with `/dev/` unless `??`; `TmuxBin` via `LookPath` when `TMUX` is set.
- SSH: parse `SSH_CONNECTION` (`clientIP clientPort serverIP serverPort`) with a pure function. Inside tmux on a server the value is stale, so when `TMUX` is set (Linux): `tmux -S <socket> list-clients -t <pane's session> -F '#{client_activity} #{client_pid}'`, take the highest activity, read `SSH_CONNECTION` from `/proc/<client_pid>/environ`. If that fails, the SSH fields stay empty.

## 5. App

### 5.1 Wire

`Session` decodes an optional `terminal` into `TerminalInfo`. Because the decoder uses `.convertFromSnakeCase`, the Swift property names are exactly: `program`, `codeServer`, `tty`, `itermSession`, `tmuxSocket`, `tmuxPane`, `tmuxBin`, `sshClientIp`, `sshClientPort`, `sshServerIp`, `sshServerPort`. A decoding test asserts every field comes through non-nil.

`ServerConfig.isLocal` is true when the daemon URL host is `127.0.0.1`, `::1` or `localhost`. It is the only way the app identifies the local server (toggle state, Off, upgrade, FocusPlan).

**Validation before use** (`TerminalInfo.validated()` in MuDoCore, pure): drop any field that fails — `tty` `^/dev/ttys[0-9]+$`, `tmuxPane` `^%[0-9]+$`, `itermSession` `^[0-9A-Fa-f-]{36}$`, `tmuxSocket` and `tmuxBin` absolute paths without `..` or a leading `-`, ports 1–65535, IPs parseable. All subprocesses get argv arrays (never a shell), and every value inserted into AppleScript goes through `TabMatcher.quoted`.

### 5.2 Choosing a focus strategy (`MuDoCore/FocusPlan.swift`, pure)

```swift
enum FocusPlan: Equatable {
    case chrome(codeServer: URL, cwd: String, project: String)
    case local(TerminalInfo?, cwd: String, project: String)
    case ssh(TerminalInfo, cwd: String, project: String)
    case none
}
static func plan(server: ServerConfig, session: Session) -> FocusPlan
```

Rules, first match wins:
1. `server.isLocal` → `.local`.
2. `terminal.codeServer` and the server has a code-server URL → `.chrome`.
3. `terminal.sshClientPort > 0` → `.ssh`.
4. Server has a code-server URL → `.chrome` (sessions from older hooks without terminal info).
5. `.none` (existing behaviour: open Settings to ask for a code-server URL).

### 5.3 Process tree helpers (`MuDoCore/ProcessTree.swift`, pure, tested)

- Parse `/bin/ps -A -o pid=,ppid=,tty=,comm=` into a table (one `ps` call per click).
- `owningApp(of pid)`: walk parents; for each process take the **outermost** bundle (path up to the first `.app/`). Map by bundle name: `iTerm` → iTerm2, `Terminal` → Terminal, `Ghostty` → Ghostty, `Visual Studio Code`/`Cursor`/`Windsurf`/`VSCodium`/`Kiro` → VSCodeLike, else Other. A process whose comm starts with `iTermServer` maps to iTerm2 (iTerm2 3.4+ runs shells under a daemonized iTermServer). Stops with `.tmux` when it reaches a `tmux` process, and with `nil` at launchd.
- `outerTTY(of pid)`: the tty of the **topmost** ancestor that still has a tty (e.g. `login` on `ttys000` above `zsh (kiro-cli-term)` on `ttys000` above the shell on `ttys001`). That is the TTY the terminal app knows. Test with the real kiro-cli-term / qterm chain.
- Parse `/usr/sbin/lsof -nP -a -iTCP -sTCP:ESTABLISHED -F pcn` (`p` pid, `c` command, `n` `local->remote`; ignore `f` lines; keep only `c == "ssh"`; split on `->`, then host:port with IPv6 brackets stripped).

### 5.4 Local focus (`MuDo/LocalFocuser.swift`)

All subprocesses run off the main thread with absolute paths: `/bin/ps`, `/usr/sbin/lsof`, and tmux from `tmuxBin`, else the first existing of `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `~/.local/bin/tmux`, `/usr/bin/tmux`. The same in-flight guard as `ChromeTabFocuser` applies.

Steps for `.local(terminal, cwd, project)`:

1. **tmux.** If `tmuxPane` is set: get the pane's session (`display -p -t <pane> '#{session_name}'`), `select-window -t <pane>`, `select-pane -t <pane>`. Pick the most recently active client attached to that session (`list-clients -F '#{client_activity} #{client_session} #{client_tty}'`). If there is none, skip to activating the app found from the pane's process (or the captured `program`). Never `switch-client` (it would hijack a client on another session). After tmux, the target is that client's TTY and `itermSession` is ignored (it is stale inside tmux).
2. **Find the terminal.** From a process on the target TTY (the agent's pid when no tmux), compute `owningApp` and `outerTTY`. If `owningApp` returns `.tmux` (e.g. an ssh running inside local tmux), find its pane with `tmux list-panes -a -F '#{pane_tty} #{pane_id} #{socket_path}'` and run step 1 for it. If no app is found, use the captured `program`.
3. **Focus by app** (AppleScript via `NSAppleScript`; scripts are generated by pure functions in `MuDoCore/TerminalScripts.swift`):
   - iTerm2: walk windows → tabs → sessions; match `unique id` = `itermSession` (only when not from tmux), else `tty` = outer TTY; select session, tab and window; `activate`.
   - Terminal.app: match tab `tty` = outer TTY; set `selected tab`, window `index` 1; `activate`.
   - Ghostty: match terminal `tty` = outer TTY (1.4+; a script error on `tty` means older Ghostty). If no tty match and no tmux step ran, match `working directory` against cwd after resolving both with `realpath`; focus only when **exactly one** terminal matches. `focus` the terminal; `activate`.
   - VSCodeLike: System Events, process of the app; pick the window whose title matches the project using `TabMatcher`'s title rules (deepest cwd path component first); `AXRaise`; activate. Without the Accessibility permission, activate only.
   - Other / no match: activate the app.

Permissions: macOS asks once per app for Automation (iTerm2, Terminal, Ghostty, System Events) and once for Accessibility (editor windows). Denials are logged and fall back to activation, like the Chrome focuser.

### 5.5 SSH focus

For `.ssh(terminal, cwd, project)`, list local ssh connections (5.3 lsof parser), then:
1. **Exact:** the ssh whose local port == `sshClientPort` and remote port == `sshServerPort`.
2. **Fallback:** exactly one ssh whose remote address:port == `sshServerIp`:`sshServerPort` (numeric compare, no DNS).
3. A candidate is discarded when its argv contains `[mux]` (ControlMaster) or its TTY is `??` **and** `owningApp` is not VSCodeLike.
4. If the candidate's TTY is `??` and its `owningApp` is VSCodeLike (Remote-SSH), raise that editor's project window (5.4 step 3 VSCodeLike).
5. Otherwise continue with 5.4 step 2 from the ssh process.
6. No candidate: activate the frontmost running app among iTerm2, Terminal, Ghostty.

### 5.6 "Monitor this Mac"

- Settings gains a toggle **Monitor this Mac**; its state is "a server with `isLocal` exists".
  - On: run `Contents/Resources/mudod install --link-only`, parse the link with the existing `AddLink`, add it through the existing upsert-by-daemon-URL. Errors are shown in Settings with the command output.
  - Off: run `Contents/Resources/mudod uninstall` (the bundled binary always exists; uninstall matches hooks by the `~/.local/bin/mudod` path string). Remove the local server only when it succeeds; otherwise show the output.
- On app launch, if a local server exists and the SHA-256 of `Contents/Resources/mudod` differs from `~/.local/bin/mudod`, re-run install to upgrade (version strings are constant across builds, so they cannot be used).

## 6. Error handling

- Hook capture never blocks or fails the hook; missing fields only mean weaker focus.
- Focus never opens new windows or tabs. Every failed step ends in app activation, and a log line under the `focus` category records which step failed.
- `launchctl` failures (after retries) surface as install errors with output, like `systemctl` today.

## 7. Testing

Go (all run on Linux):
- `parseLsofCwd`, kinfo-to-`Stat`, `parseProcargs2`, `isAgent` with `P_comm = "2.1.144"` and argv0 `claude`.
- `Sweep` does not hold the lock while calling `Cwd` (a fake `Cwd` that blocks while a concurrent `Apply` must complete).
- Ingest rejects `Origin`, wrong `Content-Type` and a foreign `Host`; accepts the hook's request.
- Plist content and escaping; darwin install/uninstall with fake exec (`launchctl` order, bootstrap retry, no systemd or tailscale calls, link `http://127.0.0.1:<port>`, `This Mac`); `--link-only` output.
- `CaptureTerminal` with fake env/deps: iTerm, Terminal, Ghostty, vscode, code-server, tmux (with TmuxBin), ssh, stale ssh inside tmux, nothing.
- `machine.Apply` stores Terminal on new sessions, updates and broadcasts on a value change, not on an equal value; JSON round trip.
- `GOOS=darwin GOARCH=arm64 go build ./...` and `GOOS=darwin go vet ./...`.

Swift (`swift test` on the Mac):
- `TerminalInfo` decoding of every field, `validated()` rejects bad values, `ServerConfig.isLocal`.
- `FocusPlan.plan` for each rule, including Remote-SSH (`program=vscode`, no `codeServer`, ssh port set) and tmux with a stale `itermSession`.
- `ProcessTree`: ps parsing, outermost bundle (VS Code helper path, Kiro), iTermServer, kiro-cli-term outer TTY, tmux stop, lsof `-F pcn` parsing with IPv6 brackets, `sshd` and `f` lines.
- `TerminalScripts` output for each terminal, with a quote, a backslash and a newline in values.

Manual on the build Mac, via `mudo://focus?session=<id>`: iTerm2, Terminal.app, VS Code, Cursor, tmux-in-iTerm2, `ssh devbox` from iTerm2 with and without tmux on the server. Ghostty is not installed on the build Mac, so it is covered by unit tests only.

## 8. Rollout order

1. proc darwin + listener + Sweep lock change + build targets (server).
2. Ingest hardening + install darwin + `--link-only` (server).
3. Terminal capture in hook + model + machine (server).
4. Wire + validation + `FocusPlan` + `ProcessTree` + `TerminalScripts` (MuDoCore).
5. `LocalFocuser` + SSH focus wired into `AppModel` (app).
6. Bundled mudod + Monitor this Mac toggle + Makefile hand-off (app).
7. README updates and manual verification.
