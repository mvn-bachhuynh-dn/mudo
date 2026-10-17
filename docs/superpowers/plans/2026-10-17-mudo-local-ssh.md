# MuDo local Mac and SSH sessions — Implementation Plan

> **For agentic workers:** Execute one task at a time with the `/mudo-task` workflow (`{ plan, task }`), or superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mudod runs on macOS to watch local Claude Code / Kiro CLI sessions, and the MuDo app focuses the right local terminal, editor window or SSH tab when a row is clicked.

**Architecture:** The hook records terminal context (`Terminal`) from the agent's environment; the daemon stores and streams it; the app's pure `FocusPlan` picks Chrome, local or SSH focus, and `LocalFocuser` drives tmux and AppleScript. mudod gains a darwin process backend and a LaunchAgent installer; the app bundles mudod and installs it from a Settings toggle.

**Tech Stack:** Go 1.22 (`golang.org/x/sys` v0.10.0), Swift 6 / SwiftUI / AppKit, Swift Testing, AppleScript, launchd.

Spec: `docs/superpowers/specs/2026-10-17-mudo-local-ssh-design.md` (section numbers below refer to it). Read the referenced spec sections for your task.

## Global Constraints

- Tests never touch the real `$HOME`, `~/.claude`, `~/.kiro`, `~/.config`, `~/Library`, `launchctl`, `systemctl` or `tailscale`; use `t.TempDir()` and injected fakes (`Options.Exec`, `Options.GOOS`, injected sleep).
- Never run `mudod install` / `uninstall` for real.
- Public repo: no real hostnames, IPs, tokens or emails. Placeholders only: `devbox`, `100.64.0.10`, `fd7a:115c:a1e0::10`, `192.168.1.10`, `code.example.com`, `user@`.
- Go: `golang.org/x/sys` pinned to `v0.10.0` (from the module cache; `GOFLAGS=-mod=mod GOPROXY=off go get golang.org/x/sys@v0.10.0`). Keep `go 1.22` in go.mod. Commit `go.sum`.
- Go tests: `cd server && go test -race -count=1 ./...`; darwin: `cd server && GOOS=darwin GOARCH=arm64 go build ./... && GOOS=darwin GOARCH=arm64 go vet ./...`.
- Swift tests run on the build Mac: `MUDO_MAC=mudo-mac app/scripts/on-mac swift test` (needs network; run with sandbox disabled).
- Swift property names for terminal info are exactly: `program`, `codeServer`, `tty`, `itermSession`, `tmuxSocket`, `tmuxPane`, `tmuxBin`, `sshClientIp`, `sshClientPort`, `sshServerIp`, `sshServerPort` (decoder uses `.convertFromSnakeCase`).
- The local server is identified only by `ServerConfig.isLocal` (daemon URL host `127.0.0.1`, `::1` or `localhost`).
- Subprocesses from the app: absolute paths (`/bin/ps`, `/usr/sbin/lsof`, tmux resolved per spec 5.4), argv arrays, never a shell. Values put into AppleScript go through `TabMatcher.quoted`.
- Focus never opens new windows or tabs; every failure ends in app activation plus a `focus` log line.
- Match the surrounding code style and comment density. Commit messages: conventional prefix, end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

### Task 1: mudod builds and inspects processes on macOS

Spec 3.1, 3.2, 3.5 (server part).

**Files:**
- Move: `server/internal/proc/proc.go` → keep shared logic (`FindAgent`, `Alive`, `isAgent`) in `proc.go`; move `/proc` reading (`Stat`, `Cwd`, `cmdline`) to `server/internal/proc/proc_linux.go` (`//go:build linux`).
- Create: `server/internal/proc/proc_darwin.go` (`//go:build darwin`), `server/internal/proc/parse.go` (pure parsers, no build tag), `server/internal/proc/parse_test.go`.
- Create: `server/cmd/mudod/listen_other.go` (`//go:build !linux`).
- Modify: `server/internal/store/store.go` (`Sweep`), `server/internal/store/store_test.go`.
- Modify: `server/Makefile`, `server/go.mod`, `server/go.sum`, `.gitignore` (add `app/Resources/mudod`).
- Modify: `server/internal/proc/proc_test.go` (add isAgent cases).

**Interfaces:**
- Produces (package `proc`):
  - `func parseLsofCwd(out string) (string, error)` — first line starting with `n`, without the `n`; error if none.
  - `func parseProcargs2(b []byte) (exe string, args []string, err error)` — layout: little-endian int32 argc, exec path NUL-terminated, NUL padding, then argc NUL-terminated args.
  - `func statFromKinfo(comm string, ppid int, startSec, startUsec int64, pstat int8) Stat` — `StartTime = uint64(startSec)*1e6 + uint64(startUsec)`, `State = "Z"` if `pstat == 5` else `"R"`.
  - `isAgent("claude")` true when: `comm == "claude"`; `comm == "node"` and cmdline contains `claude`; `filepath.Base(argv0) == "claude"`; or exe/cmdline contains `/claude/versions/`. darwin `cmdline` returns args joined by spaces; `isAgent` needs argv0 and exe, so add an unexported `argv(pid) (exe string, args []string)` method per OS (Linux: exe = readlink `/proc/<pid>/exe` (ignore errors), args = split cmdline on NUL).
- Store: `Sweep()` signature unchanged.

- [ ] **Step 1: Failing tests for pure parsers** in `parse_test.go`:

```go
func TestParseLsofCwd(t *testing.T) {
	got, err := parseLsofCwd("p123\nfcwd\nn/Users/dev/My Proj\n")
	if err != nil || got != "/Users/dev/My Proj" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := parseLsofCwd("p123\n"); err == nil {
		t.Fatal("want error without n line")
	}
}

func TestParseProcargs2(t *testing.T) {
	b := []byte{2, 0, 0, 0}
	b = append(b, "/opt/homebrew/bin/claude\x00\x00\x00claude\x00--resume\x00HOME=/x\x00"...)
	exe, args, err := parseProcargs2(b)
	if err != nil || exe != "/opt/homebrew/bin/claude" || !reflect.DeepEqual(args, []string{"claude", "--resume"}) {
		t.Fatalf("got %q %q %v", exe, args, err)
	}
	if _, _, err := parseProcargs2([]byte{1, 0}); err == nil {
		t.Fatal("want error on short buffer")
	}
}

func TestStatFromKinfo(t *testing.T) {
	s := statFromKinfo("claude", 42, 1700000000, 250, 2)
	if s.Comm != "claude" || s.PPID != 42 || s.StartTime != 1700000000000250 || s.State != "R" {
		t.Fatalf("got %+v", s)
	}
	if statFromKinfo("x", 1, 0, 0, 5).State != "Z" {
		t.Fatal("SZOMB must map to Z")
	}
}
```

Add to `proc_test.go` (uses the existing fake FS helpers; extend the fake with exe/argv if needed) cases: comm `2.1.144` with argv0 `claude` → claude agent; exe `/Users/x/.local/share/claude/versions/2.1.144` → claude agent; comm `zsh` → not.

- [ ] **Step 2:** Run `cd server && go test ./internal/proc/` — expect FAIL (undefined functions).
- [ ] **Step 3: Implement** `parse.go`, split `proc.go`/`proc_linux.go`, write `proc_darwin.go`:

```go
//go:build darwin

package proc

import (
	"context"
	"os/exec"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// FS on darwin reads the kernel through sysctl; Root is ignored.
func (f FS) Stat(pid int) (Stat, error) {
	k, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return Stat{}, err
	}
	comm := unix.ByteSliceToString(k.Proc.P_comm[:])
	return statFromKinfo(comm, int(k.Eproc.Ppid), k.Proc.P_starttime.Sec, int64(k.Proc.P_starttime.Usec), k.Proc.P_stat), nil
}

func (f FS) Cwd(pid int) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return "", err
	}
	return parseLsofCwd(string(out))
}

func (f FS) argv(pid int) (string, []string) {
	b, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil
	}
	exe, args, err := parseProcargs2(b)
	if err != nil {
		return "", nil
	}
	return exe, args
}

func (f FS) cmdline(pid int) string {
	_, args := f.argv(pid)
	return strings.Join(args, " ")
}
```

(Check the exact x/sys v0.10.0 field names/types in the module cache — e.g. `P_starttime` is `Timeval{Sec int64, Usec int32}`, `P_stat int8` — and adapt the conversion call, not `statFromKinfo`'s contract.)

`listen_other.go`:

```go
//go:build !linux

package main

import (
	"context"
	"net"
)

// listenFreebind is a plain listen off Linux; IP_FREEBIND is Linux-only and
// the darwin daemon binds loopback.
func listenFreebind(ctx context.Context, addr string) (net.Listener, error) {
	return (&net.ListenConfig{}).Listen(ctx, "tcp", addr)
}
```

- [ ] **Step 4: Sweep without the lock during process calls.** Failing test first in `store_test.go`: a store whose `Cwd` blocks on a channel; start `Sweep` in a goroutine, then call `st.Apply(ev)` for another session and assert it returns within 1 s while `Cwd` is still blocked; then unblock and assert the swept session's cwd was applied. Add a second test: if the session's PID changed between snapshot and apply, the stale cwd/end result is not applied. Then rewrite `Sweep`:
  1. Under lock: delete long-ended sessions (as today) and collect `{id, pid, start}` for non-ended sessions with `PID != 0`.
  2. Unlock; for each: `alive := Alive(pid, start)`; if alive, `cwd, err := Cwd(pid)`.
  3. Lock; for each result, re-read the session; skip if missing, ended, or PID/PIDStart differ; apply `machine.End` when not alive, else the cwd update as today.
- [ ] **Step 5: Build targets.** `server/Makefile`:

```make
build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-linux-amd64 ./cmd/mudod
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-darwin-arm64 ./cmd/mudod

# Copies the darwin daemon into the app tree so scripts/on-mac syncs it to the build Mac.
app-resource: build
	mkdir -p ../app/Resources
	cp dist/mudod-darwin-arm64 ../app/Resources/mudod

test:
	go test -race -count=1 ./...
	GOOS=darwin GOARCH=arm64 go build ./...
	GOOS=darwin GOARCH=arm64 go vet ./...
```

Add `.PHONY` entry for `app-resource`; add `app/Resources/mudod` to the root `.gitignore`.
- [ ] **Step 6:** `cd server && make test` — all pass; `make build` produces both binaries.
- [ ] **Step 7:** Commit `feat(server): darwin process backend, plain listener and lock-free sweep`.

---

### Task 2: ingest hardening, darwin install and `--link-only`

Spec 3.3, 3.4.

**Files:**
- Modify: `server/internal/api/api.go` (+ test), `server/internal/install/install.go` (+ `install_test.go`), `server/internal/paths/paths.go`, `server/cmd/mudod/install.go`, `server/cmd/mudod/serve.go` (pass ingest addr to `api.Ingest`).
- Create: `server/internal/install/launchd.go`, `server/internal/install/launchd_test.go`.

**Interfaces:**
- `func Ingest(st *store.Store, addr string) http.Handler` — `addr` is the configured ingest host:port; requests are rejected with 403 when `r.Header.Get("Origin") != ""`, when the media type of `Content-Type` is not `application/json`, or when `r.Host != addr` (also accept `localhost:<port>` and `127.0.0.1:<port>` for the same port).
- `install.Options` gains `GOOS string` (empty = `runtime.GOOS`), `UID int`, `Sleep func(time.Duration)` (nil = `time.Sleep`).
- `func LaunchAgentPlist(bin, log string) string` — XML plist; paths escaped with `encoding/xml` `EscapeText`.
- `paths.Paths` gains `LaunchAgent` (`~/Library/LaunchAgents/dev.mudo.mudod.plist`) and `LaunchLog` (`~/Library/Logs/mudod.log`).
- `mudod install --link-only` prints only `res.ConnectURL` + newline on stdout; warnings to stderr.

- [ ] **Step 1: Failing ingest tests:** POST with `Origin: https://evil.example` → 403; `Content-Type: text/plain` → 403; `Host: evil.example:7878` → 403; the hook's request (`application/json`, `Host: 127.0.0.1:7878`, no Origin) → 204. Existing ingest tests updated to set the header and host.
- [ ] **Step 2: Failing install tests** (fake exec records calls; `GOOS: "darwin"`, `UID: 501`, `Sleep` no-op):
  - fresh install: writes the plist at `paths.LaunchAgent` with mode 0644 and content equal to `LaunchAgentPlist(bin, log)`; exec calls are exactly `launchctl bootout gui/501/dev.mudo.mudod` then `launchctl bootstrap gui/501 <plist>`; no `systemctl`, `loginctl` or `tailscale` call; config `api_addr` is `127.0.0.1:7879`; link has `name=This Mac` and `url=http://127.0.0.1:7879`; Claude and Kiro hooks are written as on Linux.
  - bootstrap fails twice then succeeds → 3 bootstrap calls, no error; fails 5 times → error mentioning `launchctl bootstrap` and its output.
  - existing config with `api_addr = "[::]:7879"` → link url `http://127.0.0.1:7879` and a warning that api_addr is not loopback.
  - uninstall darwin: `launchctl bootout`, plist removed, hooks removed, no systemctl.
  - `LaunchAgentPlist("/Users/a&b/bin/mudod", "/Users/a&b/Library/Logs/mudod.log")` contains `a&amp;b` and `<string>serve</string>`, `<key>KeepAlive</key>`, `<true/>`, `dev.mudo.mudod`.
  - Linux tests keep passing unchanged (set `GOOS: "linux"` in the shared `options` helper).
- [ ] **Step 3: Implement.** In `Run`, branch on `goos := o.GOOS; if goos == "" { goos = runtime.GOOS }`: Linux path as today; darwin path writes plist and runs launchctl:

```go
func bootstrapLaunchAgent(o Options, plist string) error {
	target := fmt.Sprintf("gui/%d", o.UID)
	_, _ = o.Exec("launchctl", "bootout", target+"/"+launchLabel)
	var out string
	var err error
	for i := 0; i < 5; i++ {
		if out, err = o.Exec("launchctl", "bootstrap", target, plist); err == nil {
			return nil
		}
		o.sleep(300 * time.Millisecond)
	}
	return fmt.Errorf("launchctl bootstrap: %v: %s", err, out)
}
```

`ensureConfig` takes the GOOS: on darwin it never calls `tailscale` and defaults `api_addr` to `127.0.0.1:7879`. The darwin link: `url=http://127.0.0.1:<port of api_addr>`, `name=This Mac`; add the non-loopback warning. `cmd/mudod/install.go`: set `UID: os.Getuid()`, add `--link-only`.
- [ ] **Step 4:** `cd server && make test` passes.
- [ ] **Step 5:** Commit `feat(server): harden ingest and install as a LaunchAgent on macOS`.

---

### Task 3: hook captures terminal context; daemon stores it

Spec 4.1, 4.2, 3.1 (hook Cwd only on session_start on darwin).

**Files:**
- Modify: `server/internal/model/model.go`, `server/internal/machine/machine.go` (+ test), `server/internal/hook/run.go` (+ test), `server/cmd/mudod/hook.go`.
- Create: `server/internal/hook/terminal.go`, `server/internal/hook/terminal_test.go`.

**Interfaces:**
- `model.Terminal` exactly as spec 4.1 (all fields, JSON tags); `Event.Terminal *Terminal` and `Session.Terminal *Terminal` with `json:"terminal,omitempty"`.
- `type TerminalDeps struct { GOOS string; TTY func(pid int) string; LookPath func(string) (string, error); TmuxClientSSH func(bin, socket, pane string) string }`
- `func CaptureTerminal(env func(string) string, d TerminalDeps, agentPID int) *model.Terminal`
- `func parseSSHConnection(s string) (clientIP string, clientPort int, serverIP string, serverPort int, ok bool)`
- `hook.Options` gains `Env func(string) string`, `Terminal TerminalDeps`, `CwdOnStartOnly bool`.

- [ ] **Step 1: Failing `terminal_test.go`** table cases (env given as a map):
  - iTerm: `TERM_PROGRAM=iTerm.app`, `ITERM_SESSION_ID=w0t1p0:6C1F8E8A-1B2C-4D3E-9F00-112233445566`, GOOS darwin, TTY fake returns `ttys004` → `Program "iTerm.app"`, `ITermSession "6C1F8E8A-1B2C-4D3E-9F00-112233445566"`, `TTY "/dev/ttys004"`.
  - TTY `??` → `TTY ""`.
  - Linux GOOS → TTY fake never called, `TTY ""`.
  - code-server: `TERM_PROGRAM=vscode`, `VSCODE_PROXY_URI=https://code.example.com/proxy/{{port}}` → `CodeServer true`.
  - tmux darwin: `TMUX=/private/tmp/tmux-501/default,1234,0`, `TMUX_PANE=%3` → `TmuxSocket "/private/tmp/tmux-501/default"`, `TmuxPane "%3"`, `TmuxBin` from LookPath fake (`/opt/homebrew/bin/tmux`).
  - ssh: `SSH_CONNECTION=fd7a:115c:a1e0::20 52144 fd7a:115c:a1e0::10 22` → the four SSH fields.
  - ssh inside tmux on linux: `SSH_CONNECTION` stale `192.168.1.20 40000 192.168.1.10 22`, `TMUX` set, `TmuxClientSSH` fake returns `192.168.1.20 51000 192.168.1.10 22` → client port 51000; fake returns `""` → SSH fields empty.
  - empty env, TTY `??` → nil.
  - `parseSSHConnection` rejects 3 fields, non-numeric ports, ports outside 1–65535.
- [ ] **Step 2: Failing machine tests:** new session copies `ev.Terminal`; existing session with nil terminal + event with terminal → changed=true and stored; equal terminal value (different pointer) → changed=false; different value → changed=true; event with nil terminal keeps the stored one.
- [ ] **Step 3: Failing hook Run tests:** with `Env` and `Terminal` fakes the posted event JSON contains `terminal`; with `CwdOnStartOnly: true` the fake `Proc.Cwd` is not called for a `tool` event but is for `session_start`.
- [ ] **Step 4: Implement.** `terminal.go`: real deps live in `cmd/mudod/hook.go`:
  - `TTY`: `exec.Command("/bin/ps", "-o", "tty=", "-p", strconv.Itoa(pid)).Output()`, trimmed.
  - `LookPath`: `exec.LookPath`.
  - `TmuxClientSSH(bin, socket, pane)` (Linux): `bin -S socket display -p -t pane '#{session_name}'`, then `bin -S socket list-clients -t <session> -F '#{client_activity} #{client_pid}'`, take the highest activity, read `/proc/<pid>/environ`, return the `SSH_CONNECTION` value. On Linux `bin` is `exec.LookPath("tmux")`.
  - `machine.Apply`: in the `prev == nil` branch set `Terminal: ev.Terminal`; otherwise `if ev.Terminal != nil && (s.Terminal == nil || *ev.Terminal != *s.Terminal) { t := *ev.Terminal; s.Terminal = &t; changed = true }`.
  - `cmd/mudod/hook.go`: `Env: os.Getenv`, `CwdOnStartOnly: runtime.GOOS == "darwin"`, `Proc: proc.FS{Root: "/proc"}` unchanged.
- [ ] **Step 5:** `cd server && make test` passes.
- [ ] **Step 6:** Commit `feat(server): record terminal context from hooks`.

---

### Task 4: MuDoCore — terminal info, focus plan, process tree, scripts

Spec 5.1, 5.2, 5.3, and the script text of 5.4.

**Files:**
- Modify: `app/Sources/MuDoCore/Wire.swift` (Session gains `terminal: TerminalInfo?`), `app/Sources/MuDoCore/ServerConfig.swift` (`isLocal`).
- Create: `app/Sources/MuDoCore/TerminalInfo.swift`, `FocusPlan.swift`, `ProcessTree.swift`, `TerminalScripts.swift`.
- Tests: `app/Tests/MuDoCoreTests/TerminalInfoTests.swift`, `FocusPlanTests.swift`, `ProcessTreeTests.swift`, `TerminalScriptsTests.swift`; update `WireTests.swift`, `ServerConfigTests.swift`.

**Interfaces (all `public`, `Sendable`, `Equatable`):**

```swift
public struct TerminalInfo: Codable, Equatable, Sendable {
    public var program: String?
    public var codeServer: Bool?
    public var tty: String?
    public var itermSession: String?
    public var tmuxSocket: String?
    public var tmuxPane: String?
    public var tmuxBin: String?
    public var sshClientIp: String?
    public var sshClientPort: Int?
    public var sshServerIp: String?
    public var sshServerPort: Int?
    /// Drops fields that fail spec 5.1's validation.
    public func validated() -> TerminalInfo
}

extension ServerConfig { public var isLocal: Bool }

public enum FocusPlan: Equatable, Sendable {
    case chrome(codeServer: URL, cwd: String, project: String)
    case local(TerminalInfo?, cwd: String, project: String)
    case ssh(TerminalInfo, cwd: String, project: String)
    case none
    public static func plan(server: ServerConfig, session: Session) -> FocusPlan  // uses session.terminal?.validated()
}

public struct ProcInfo: Equatable, Sendable { public var pid: Int; public var ppid: Int; public var tty: String?; public var comm: String }
public enum TerminalApp: Equatable, Sendable { case iTerm2, terminal, ghostty, vscodeLike(bundlePath: String), other(bundlePath: String) }
public enum Owner: Equatable, Sendable { case app(TerminalApp), tmux(pid: Int) }
public struct ProcessTable: Sendable {
    public init(psOutput: String)                      // `/bin/ps -A -o pid=,ppid=,tty=,comm=`; tty "??" -> nil, "ttys004" -> "/dev/ttys004"
    public func process(_ pid: Int) -> ProcInfo?
    public func processes(onTTY tty: String) -> [ProcInfo]
    public func owner(of pid: Int) -> Owner?            // spec 5.3 owningApp; nil at launchd
    public func outerTTY(of pid: Int) -> String?        // tty of the topmost ancestor that still has a tty
    public static func outermostBundle(_ path: String) -> String?   // "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper" -> "/Applications/Visual Studio Code.app"
}
public struct SSHConn: Equatable, Sendable { public var pid: Int; public var localPort: Int; public var remoteHost: String; public var remotePort: Int }
public enum LsofSSH { public static func parse(_ out: String) -> [SSHConn] }   // -F pcn; only c == "ssh"; IPv6 brackets stripped
public enum TerminalScripts {
    public static func iTerm(sessionID: String?, tty: String?) -> String
    public static func terminalApp(tty: String) -> String
    public static func ghosttyByTTY(_ tty: String) -> String
    public static func ghosttyList() -> String         // returns {id, working directory} pairs for the cwd fallback
    public static func ghosttyFocus(id: String) -> String
    public static func raiseWindow(appName: String, titleContains: [String]) -> String  // System Events AXRaise, first title that contains any candidate in order
}
```

`ProcessTable.owner(of:)` walks from the pid through parents: if `comm`'s basename is `tmux` → `.tmux(pid)`; if `comm` starts with `iTermServer` → `.app(.iTerm2)`; if `outermostBundle(comm)` exists, classify by bundle file name (`iTerm.app` → iTerm2, `Terminal.app` → terminal, `Ghostty.app` → ghostty, `Visual Studio Code.app`/`Cursor.app`/`Windsurf.app`/`VSCodium.app`/`Kiro.app` → vscodeLike, else other). Stops at pid 1 / missing parent → nil.

- [ ] **Step 1: Failing tests.** Cover at least:
  - Decoding a session JSON with every `terminal` field (snake_case) → all properties non-nil; session JSON without `terminal` → nil.
  - `validated()`: keeps `/dev/ttys004`, drops `/dev/ttys004; rm`, drops `../x`; pane `%3` kept, `3` dropped; iterm id 36 hex/dash kept, `abc` dropped; socket `-x` dropped, `/a/../b` dropped; port 0 and 70000 dropped; IP `fd7a:115c:a1e0::10` kept, `devbox` dropped.
  - `isLocal`: `http://127.0.0.1:7879`, `http://[::1]:7879`, `http://localhost:7879` true; `http://[fd7a:115c:a1e0::10]:7879` false.
  - `FocusPlan`: local server → `.local` even with code-server; remote + `codeServer: true` + code-server URL → `.chrome`; remote + ssh port (Remote-SSH: `program "vscode"`, no codeServer) → `.ssh`; remote, no terminal, code-server URL → `.chrome`; remote, nothing → `.none`; invalid ssh port (0) → falls through to rule 4.
  - `ProcessTable` with this fixture (real shapes, placeholder users):

```
    1     0 ??       /sbin/launchd
  500     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2
  610     1 ??       /Users/dev/Library/Application Support/iTerm2/iTermServer-3.5.4
61020   610 ttys000  /usr/bin/login
61021 61020 ttys000  zsh (kiro-cli-term)
61032 61021 ttys001  /bin/zsh
61100 61032 ttys001  claude
  700     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
  710   700 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
  720   710 ttys005  /bin/zsh
  800     1 ??       tmux
  810   800 ttys007  -zsh
  820   810 ttys007  ssh
```

    Expect: `owner(of: 61100) == .app(.iTerm2)`; `outerTTY(of: 61100) == "/dev/ttys000"`; `owner(of: 720) == .app(.vscodeLike(bundlePath: "/Applications/Visual Studio Code.app"))`; `owner(of: 820) == .tmux(pid: 800)`; `processes(onTTY: "/dev/ttys007").map(\.pid) == [810, 820]`; comm with spaces parsed whole.
  - `LsofSSH.parse` of:

```
p820
cssh
f3
n[fd7a:115c:a1e0::20]:52144->[fd7a:115c:a1e0::10]:22
p900
csshd-session
f4
n192.168.1.10:22->192.168.1.20:40000
p901
cssh
f3
n192.168.1.20:50000->192.168.1.10:22
```

    → `[SSHConn(pid: 820, localPort: 52144, remoteHost: "fd7a:115c:a1e0::10", remotePort: 22), SSHConn(pid: 901, localPort: 50000, remoteHost: "192.168.1.10", remotePort: 22)]`.
  - `TerminalScripts`: output contains the quoted tty / session id; a value with `"`, `\` and a newline appears only in escaped form (`TabMatcher.quoted`); iTerm script with `sessionID: nil` matches by tty only.
- [ ] **Step 2:** Run `MUDO_MAC=mudo-mac app/scripts/on-mac swift test` — FAIL.
- [ ] **Step 3: Implement.** AppleScript bodies (values via `TabMatcher.quoted`):
  - iTerm: `tell application "iTerm2"` → repeat windows/tabs/sessions; `if (unique id of s) is <id> or (tty of s) is <tty>` → `select s` / `select t` / `select w`, `activate`, `return true`; end → `return false`. Omit the unique-id test when `sessionID == nil`.
  - Terminal: `tell application "Terminal"` → repeat windows/tabs; `if tty of t is <tty>` → `set selected tab of w to t`, `set index of w to 1`, `activate`, `return true`.
  - Ghostty by tty: `tell application "Ghostty"` → repeat windows/tabs/terminals; `if tty of term is <tty>` → `focus term`, `activate`, `return true` (script errors on Ghostty < 1.4 — the caller treats an error as "no tty support").
  - Ghostty list: returns a list of `{id of term, working directory of term}`; Ghostty focus: find by `id`, `focus term`, `activate`.
  - raiseWindow: `tell application "System Events" to tell process <appName>` → for each candidate in order, for each window whose `name contains` candidate → `perform action "AXRaise" of w`, `set frontmost to true`, `return true`.
- [ ] **Step 4:** Swift tests pass on the Mac (expect 103 existing + new).
- [ ] **Step 5:** Commit `feat(app): terminal info, focus plan, process tree and terminal scripts`.

---

### Task 5: LocalFocuser and SSH focus wired into AppModel

Spec 5.4, 5.5.

**Files:**
- Create: `app/Sources/MuDo/LocalFocuser.swift`, `app/Sources/MuDo/AppleScriptRunner.swift` (extract `run(_:parse:)` and `ScriptResult` from `ChromeTabFocuser` so both focusers share it).
- Modify: `app/Sources/MuDo/ChromeTabFocuser.swift` (use the runner), `app/Sources/MuDo/AppModel.swift` (`open` uses `FocusPlan`).
- Create: `app/Sources/MuDoCore/TmuxPick.swift` + `app/Tests/MuDoCoreTests/TmuxPickTests.swift` (pure parsing for tmux output), `app/Sources/MuDoCore/SSHPick.swift` + tests (pure candidate choice).

**Interfaces:**
- `TmuxPick.client(listClients: String, session: String) -> String?` — input lines `"<activity> <session> <tty>"`; returns the tty of the highest activity whose session equals `session`, else nil.
- `TmuxPick.pane(listPanes: String, tty: String) -> (pane: String, socket: String)?` — lines `"<pane_tty> <pane_id> <socket_path>"`.
- `TmuxPick.resolveBinary(recorded: String?, exists: (String) -> Bool, home: String) -> String?` — `recorded` if it exists, else first existing of `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `<home>/.local/bin/tmux`, `/usr/bin/tmux`.
- `SSHPick.choose(conns: [SSHConn], terminal: TerminalInfo, isMux: (Int) -> Bool) -> SSHConn?` — rule 1 exact (local port == sshClientPort and remote port == sshServerPort); else rule 2: exactly one conn with remoteHost == sshServerIp and remotePort == sshServerPort; candidates where `isMux(pid)` are removed first.
- `@MainActor final class LocalFocuser { func focus(_ plan: FocusPlan) }` — handles `.local` and `.ssh`; in-flight guard like `ChromeTabFocuser`; logs under category `focus`.

- [ ] **Step 1: Failing tests** for `TmuxPick` (client on another session ignored; no client → nil; resolveBinary order) and `SSHPick` (exact match; NAT-changed port with single host match; two host matches → nil; mux removed).
- [ ] **Step 2:** Implement `TmuxPick`, `SSHPick`; tests pass on the Mac.
- [ ] **Step 3: Implement `LocalFocuser`** following spec 5.4/5.5 exactly:
  - helper `runTool(_ path: String, _ args: [String]) async -> String?` (Process off the main actor, 2 s timeout, stdout as String, nil on failure).
  - `.local(t, cwd, project)`: if `t?.tmuxPane` → tmux step (binary via `TmuxPick.resolveBinary`, `display -p -t pane '#{session_name}'`, `select-window -t pane`, `select-pane -t pane`, `list-clients -F '#{client_activity} #{client_session} #{client_tty}'` → `TmuxPick.client`); target tty = client tty; `itermSession` ignored. Else target pid = processes on `t?.tty` (first). Build `ProcessTable` from `/bin/ps -A -o pid=,ppid=,tty=,comm=`. `owner(of:)`; if `.tmux` → `list-panes -a -F '#{pane_tty} #{pane_id} #{socket_path}'` → `TmuxPick.pane` → run the tmux step for that pane and continue with its client tty. Then focus by app with `outerTTY`: iTerm2 → `TerminalScripts.iTerm(sessionID: fromTmux ? nil : t?.itermSession, tty: outer)`; terminal → `terminalApp`; ghostty → `ghosttyByTTY`, on script error or `false` and no tmux step → `ghosttyList` + exactly one `realpath` match on cwd → `ghosttyFocus`; vscodeLike → `raiseWindow(appName: bundle name without .app, titleContains: cwd components deepest-first plus project)`; other/no match → `NSRunningApplication` activate of the bundle (or of `t?.program` mapped to a bundle id: `iTerm.app` → `com.googlecode.iterm2`, `Apple_Terminal` → `com.apple.Terminal`, `ghostty` → `com.mitchellh.ghostty`, `vscode` → `com.microsoft.VSCode`).
  - `.ssh(t, ...)`: `/usr/sbin/lsof -nP -a -iTCP -sTCP:ESTABLISHED -F pcn` → `LsofSSH.parse` → `SSHPick.choose` (`isMux`: `/bin/ps -o command= -p pid` contains `[mux]`). Candidate with tty nil: if `owner` is vscodeLike → raiseWindow; else drop. Otherwise continue as `.local` from the ssh pid. No candidate → activate the frontmost running of iTerm2, Terminal, Ghostty.
  - Automation denied (-1743) → log, activate the app.
- [ ] **Step 4: Wire `AppModel.open`:**

```swift
switch FocusPlan.plan(server: config, session: row.session) {
case let .chrome(codeServer, cwd, project):
    focuser.focus(codeServer: codeServer, cwd: cwd, project: project)
case let plan where plan != .none:
    localFocuser.focus(plan)
default:
    onNeedsCodeServer?()
}
```

- [ ] **Step 5:** `swift test` on the Mac passes; `make app` builds.
- [ ] **Step 6:** Commit `feat(app): focus local terminals, editors and ssh tabs`.

---

### Task 6: bundled mudod and the "Monitor this Mac" toggle

Spec 3.5 (app part), 5.6.

**Files:**
- Modify: `app/Makefile`, `app/scripts/on-mac` (no change needed if `Resources/mudod` is inside `app/`; verify it is synced), `app/Sources/MuDo/AppSettings.swift`, `app/Sources/MuDo/SettingsView.swift`, `app/Sources/MuDo/AppModel.swift` (launch upgrade check).
- Create: `app/Sources/MuDo/LocalDaemon.swift`; `app/Sources/MuDoCore/LocalDaemonLogic.swift` + `app/Tests/MuDoCoreTests/LocalDaemonLogicTests.swift`.

**Interfaces:**
- `LocalDaemonLogic.needsUpgrade(bundled: Data?, installed: Data?) -> Bool` — true when bundled exists and SHA-256 differs from installed (or installed missing). Use `CryptoKit` (`#if canImport(CryptoKit)`) or a small SHA-256 helper so MuDoCore still builds on Linux.
- `LocalDaemonLogic.link(fromInstallOutput: String) -> URL?` — last line starting with `mudo://add?`.
- `@MainActor final class LocalDaemon { func enable() async -> Result<ServerDraft, LocalDaemonError>; func disable() async -> Result<Void, LocalDaemonError>; func upgradeIfNeeded() async }` — runs `Bundle.main.url(forResource: "mudod", withExtension: nil)` with `install --link-only` / `uninstall`; `LocalDaemonError` carries the command output.
- `AppSettings`: `var localServer: ServerConfig? { servers.first(where: \.isLocal) }`.

- [ ] **Step 1: Failing tests** for `needsUpgrade` (same data → false, different → true, installed nil → true, bundled nil → false) and `link(fromInstallOutput:)` (with a warning line before the link; no link → nil).
- [ ] **Step 2:** Implement logic; tests pass.
- [ ] **Step 3: Makefile:**

```make
app: build
	@test -f Resources/mudod || { echo "Resources/mudod missing: run 'make -C server app-resource' on the Linux side first"; exit 1; }
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/MuDo" $(APP)/Contents/MacOS/MuDo
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/mudod $(APP)/Contents/Resources/mudod
	chmod 755 $(APP)/Contents/Resources/mudod
	@if [ -f "$(SIGN_KEYCHAIN)" ] && [ -f "$(SIGN_PASS)" ]; then \
		security unlock-keychain -p "$$(cat "$(SIGN_PASS)")" "$(SIGN_KEYCHAIN)"; fi
	codesign --force --options runtime --sign "$(SIGN_ID)" $(if $(filter-out -,$(SIGN_ID)),--keychain "$(SIGN_KEYCHAIN)") $(APP)/Contents/Resources/mudod
	codesign --force --sign "$(SIGN_ID)" $(if $(filter-out -,$(SIGN_ID)),--keychain "$(SIGN_KEYCHAIN)") $(APP)
```

- [ ] **Step 4: Settings toggle** "Monitor this Mac" in a new section above "Servers" (or inside it): `isOn` derived from `settings.localServer != nil`; turning on calls `enable()` then `settings.add(draft)` + `model.applySettings()`; off calls `disable()` then `settings.remove(local.id)`; show a progress indicator while running and the error output in red text on failure.
- [ ] **Step 5:** On launch (`AppModel.init` → `Task`), `if settings.localServer != nil { await localDaemon.upgradeIfNeeded() }`.
- [ ] **Step 6:** `cd server && make app-resource` on Linux, then `MUDO_MAC=mudo-mac app/scripts/on-mac make app` and `swift test` — pass; `codesign -dv build/MuDo.app/Contents/Resources/mudod` shows the signature.
- [ ] **Step 7:** Commit `feat(app): bundle mudod and add Monitor this Mac`.

---

### Task 7: README and manual verification

Spec 7 (manual), 1 (table).

**Files:** `README.md`, `server/README.md`, `app/README.md`, `docs/superpowers/specs/2026-10-17-mudo-local-ssh-design.md` (append a "Verification notes" section with results).

- [ ] **Step 1:** README: add "Monitor this Mac" to Install/Usage; a "Click targets" table (spec 1 table); permissions list (Automation for iTerm2/Terminal/Ghostty/System Events, Accessibility for editor windows); SSH focus notes (works over LAN/Tailscale; ControlMaster/mosh fall back); troubleshooting entries (tmux not found → install path list; Ghostty < 1.4 matches by working directory; VS Code sidebar Claude sends no hooks, use the terminal); build hand-off (`make -C server app-resource` before `on-mac make app`). server/README: darwin build, LaunchAgent, `--link-only`, ingest hardening.
- [ ] **Step 2:** Add an empty `## Verification notes` section at the end of the spec; the controller (not the task agent) fills it after a manual run on the build Mac, because that run installs mudod for real.
- [ ] **Step 3:** Commit `docs: local Mac and SSH focus`.
