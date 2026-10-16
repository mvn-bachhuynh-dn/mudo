# mudod (Server Daemon) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `mudod`, a single static Go binary that turns Claude Code / Kiro CLI hook calls into live session state and streams it over SSE to the MuDo Mac app.

**Architecture:** `mudod hook` (invoked by agent hooks) normalizes the hook payload, finds the agent PID in `/proc`, and POSTs an event to `mudod serve` on localhost. `serve` folds events through a pure state machine into a mutex-guarded store that persists to JSON, sweeps dead PIDs, and broadcasts changes to SSE subscribers on a token-protected API. `install` wires hooks, config and a systemd user unit; `fake` replays a scripted session cycle for UI development.

**Tech Stack:** Go 1.22, standard library only (`net/http` 1.22 method+path patterns, `encoding/json`, `os/exec`). No third-party modules.

**Spec:** `docs/superpowers/specs/2026-10-14-mudo-design.md` (sections 3, 4, 5, 7, 8, 9, 10).

## Global Constraints

- Go module path: `mudo`, rooted at `server/`. Go directive `go 1.22`.
- Zero third-party dependencies; build with `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`.
- Ingest listener: `127.0.0.1:7878`, path `POST /event`.
- Client API listener: `<tailscale-ip>:7879`, all routes under `/v1`, every request needs `Authorization: Bearer <token>`, mismatch → 401.
- `mudod hook` must **always exit 0 and print nothing to stdout or stderr**; errors go to `~/.local/state/mudo/hook.log` (rotate at 1 MB). Ingest POST timeout 500 ms. Stdin read capped at 1 MB.
- States: `idle | running | waiting | done | ended`. Normalized events: `session_start | prompt | tool | waiting | stop | session_end`.
- `last_prompt` ≤ 80 characters.
- Liveness sweep every 10 s; `ended` sessions deleted after 1 h; state file written atomically, debounced 200 ms.
- SSE: `snapshot` on connect, then `upsert` / `remove`, `ping` every 15 s; every message carries `server_now`.
- Files: config `~/.config/mudo/config.toml` (0600), state `~/.local/state/mudo/state.json`, binary `~/.local/bin/mudod`, unit `~/.config/systemd/user/mudod.service`, Claude settings `~/.claude/settings.json`, Kiro hooks `~/.kiro/hooks/mudo.json`.
- Hook commands use the absolute binary path, never `~`.
- All commands below run from `server/` unless stated.

---

## File Structure

```
must-do/
  .gitignore
  server/
    go.mod
    Makefile
    README.md
    cmd/mudod/
      main.go          subcommand dispatch, version
      hook.go          `mudod hook` wiring
      serve.go         `mudod serve` wiring
      install.go       `mudod install` / `uninstall` wiring
      fake.go          `mudod fake` wiring
      main_test.go     end-to-end test (build binary, hook → serve → SSE, restart)
    internal/
      model/model.go           Session, Event, State, EventKind
      machine/machine.go       pure state machine: Apply, Ack, End
      proc/proc.go             /proc parsing: Stat, FindAgent, Alive
      proc/fake.go             WriteFakeProcess helper for tests
      hook/normalize.go        payload → model.Event
      hook/run.go              one hook invocation, silent, logs errors
      store/store.go           session map, subscribers, sweep, persistence
      config/config.go         flat key = "value" config file
      paths/paths.go           all on-disk locations derived from $HOME
      api/api.go               ingest handler + client handler (SSE, ack, health)
      install/claude.go        merge/remove hooks in ~/.claude/settings.json
      install/kiro.go          ~/.kiro/hooks/mudo.json content
      install/install.go       Run / Uninstall orchestration, systemd unit
      fake/fake.go             scripted event cycle
```

---

### Task 1: Repository, module, model and state machine

**Files:**
- Create: `.gitignore`, `server/go.mod`, `server/internal/model/model.go`, `server/internal/machine/machine.go`
- Test: `server/internal/machine/machine_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `model.State` (`StateIdle`, `StateRunning`, `StateWaiting`, `StateDone`, `StateEnded`), `model.EventKind` (`EvSessionStart`, `EvPrompt`, `EvTool`, `EvWaiting`, `EvStop`, `EvSessionEnd`)
  - `model.Event{Agent, SessionID, Cwd string; Kind EventKind; Prompt string; PID int; PIDStart uint64}` (comparable struct)
  - `model.Session{ID, Agent, Host, Cwd, Project string; State State; StateSince time.Time; PID int; PIDStart uint64; LastPrompt string; UpdatedAt time.Time}`
  - `machine.Apply(prev *model.Session, ev model.Event, host string, now time.Time) (model.Session, bool)`
  - `machine.Ack(s model.Session, now time.Time) (model.Session, error)`, `machine.ErrNotDone`
  - `machine.End(s model.Session, now time.Time) model.Session`

- [ ] **Step 1: Initialise the repository**

From the project root `must-do/`:

```bash
git init
```

Create `.gitignore`:

```gitignore
server/dist/
temp/
.DS_Store
app/build/
xcuserdata/
DerivedData/
```

Create `server/go.mod`:

```
module mudo

go 1.22
```

```bash
git add .gitignore server/go.mod docs/
git commit -m "chore: init repo with MuDo spec and Go module"
```

- [ ] **Step 2: Write the model**

Create `server/internal/model/model.go`:

```go
// Package model holds the types shared by the hook, the daemon and the API.
package model

import "time"

type State string

const (
	StateIdle    State = "idle"
	StateRunning State = "running"
	StateWaiting State = "waiting"
	StateDone    State = "done"
	StateEnded   State = "ended"
)

type EventKind string

const (
	EvSessionStart EventKind = "session_start"
	EvPrompt       EventKind = "prompt"
	EvTool         EventKind = "tool"
	EvWaiting      EventKind = "waiting"
	EvStop         EventKind = "stop"
	EvSessionEnd   EventKind = "session_end"
)

// Event is one normalized hook invocation, sent from `mudod hook` to the daemon.
type Event struct {
	Agent     string    `json:"agent"`
	SessionID string    `json:"session_id"`
	Cwd       string    `json:"cwd"`
	Kind      EventKind `json:"event"`
	Prompt    string    `json:"prompt,omitempty"`
	PID       int       `json:"pid"`
	PIDStart  uint64    `json:"pid_start"`
}

// Session is the daemon's view of one agent session.
type Session struct {
	ID         string    `json:"id"`
	Agent      string    `json:"agent"`
	Host       string    `json:"host"`
	Cwd        string    `json:"cwd"`
	Project    string    `json:"project"`
	State      State     `json:"state"`
	StateSince time.Time `json:"state_since"`
	PID        int       `json:"pid"`
	PIDStart   uint64    `json:"pid_start"`
	LastPrompt string    `json:"last_prompt"`
	UpdatedAt  time.Time `json:"updated_at"`
}
```

- [ ] **Step 3: Write the failing state machine tests**

Create `server/internal/machine/machine_test.go`:

```go
package machine

import (
	"errors"
	"testing"
	"time"

	"mudo/internal/model"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

func session(state model.State) *model.Session {
	return &model.Session{ID: "s1", Agent: "claude", Host: "devbox", Cwd: "/w/api", Project: "api",
		State: state, StateSince: t0, PID: 42, PIDStart: 7, UpdatedAt: t0}
}

func event(k model.EventKind) model.Event {
	return model.Event{Agent: "claude", SessionID: "s1", Cwd: "/w/api", Kind: k, PID: 42, PIDStart: 7}
}

// TestTransitions encodes the spec's transition table (section 4.2) for every
// (state, event) pair.
func TestTransitions(t *testing.T) {
	all := []model.State{model.StateIdle, model.StateRunning, model.StateWaiting, model.StateDone, model.StateEnded}
	rules := map[model.EventKind]func(from model.State) model.State{
		model.EvSessionStart: func(model.State) model.State { return model.StateIdle },
		model.EvPrompt:       func(model.State) model.State { return model.StateRunning },
		model.EvTool: func(from model.State) model.State {
			switch from {
			case model.StateWaiting, model.StateIdle, model.StateDone:
				return model.StateRunning
			}
			return from
		},
		model.EvWaiting: func(from model.State) model.State {
			if from == model.StateRunning {
				return model.StateWaiting
			}
			return from
		},
		model.EvStop: func(from model.State) model.State {
			if from == model.StateRunning || from == model.StateWaiting {
				return model.StateDone
			}
			return from
		},
		model.EvSessionEnd: func(model.State) model.State { return model.StateEnded },
	}
	for kind, rule := range rules {
		for _, from := range all {
			got, _ := Apply(session(from), event(kind), "devbox", t0.Add(time.Minute))
			if want := rule(from); got.State != want {
				t.Errorf("%s + %s = %s, want %s", from, kind, got.State, want)
			}
		}
	}
}

func TestStateSinceOnlyMovesOnStateChange(t *testing.T) {
	got, changed := Apply(session(model.StateRunning), event(model.EvTool), "devbox", t0.Add(time.Minute))
	if changed {
		t.Fatal("tool on a running session must be a no-op")
	}
	if !got.StateSince.Equal(t0) {
		t.Fatalf("state_since moved to %v", got.StateSince)
	}

	later := t0.Add(time.Minute)
	got, changed = Apply(session(model.StateRunning), event(model.EvStop), "devbox", later)
	if !changed || !got.StateSince.Equal(later) || !got.UpdatedAt.Equal(later) {
		t.Fatalf("stop: changed=%v state_since=%v updated_at=%v", changed, got.StateSince, got.UpdatedAt)
	}
}

func TestNewSessionTakesStateFromEvent(t *testing.T) {
	cases := map[model.EventKind]model.State{
		model.EvSessionStart: model.StateIdle,
		model.EvPrompt:       model.StateRunning,
		model.EvTool:         model.StateRunning,
		model.EvWaiting:      model.StateWaiting,
		model.EvStop:         model.StateDone,
		model.EvSessionEnd:   model.StateEnded,
	}
	for kind, want := range cases {
		ev := event(kind)
		ev.Cwd = "/home/steve/code/api-gateway"
		got, changed := Apply(nil, ev, "devbox", t0)
		if !changed || got.State != want {
			t.Errorf("%s: state=%s changed=%v, want %s", kind, got.State, changed, want)
		}
		if got.ID != "s1" || got.Project != "api-gateway" || got.Host != "devbox" || !got.StateSince.Equal(t0) {
			t.Errorf("%s: bad record %+v", kind, got)
		}
	}
}

func TestPromptSetsLastPrompt(t *testing.T) {
	ev := event(model.EvPrompt)
	ev.Prompt = "refactor auth"
	got, _ := Apply(session(model.StateDone), ev, "devbox", t0)
	if got.LastPrompt != "refactor auth" {
		t.Fatalf("last_prompt = %q", got.LastPrompt)
	}
}

func TestNewPIDReplacesOld(t *testing.T) {
	ev := event(model.EvPrompt)
	ev.PID, ev.PIDStart = 99, 3
	got, _ := Apply(session(model.StateIdle), ev, "devbox", t0)
	if got.PID != 99 || got.PIDStart != 3 {
		t.Fatalf("pid = %d/%d", got.PID, got.PIDStart)
	}
}

func TestAck(t *testing.T) {
	later := t0.Add(time.Minute)
	got, err := Ack(*session(model.StateDone), later)
	if err != nil || got.State != model.StateIdle || !got.StateSince.Equal(later) {
		t.Fatalf("ack done: %+v, %v", got, err)
	}
	if _, err := Ack(*session(model.StateRunning), later); !errors.Is(err, ErrNotDone) {
		t.Fatalf("ack running: err = %v, want ErrNotDone", err)
	}
}

func TestEnd(t *testing.T) {
	got := End(*session(model.StateRunning), t0.Add(time.Minute))
	if got.State != model.StateEnded || !got.StateSince.Equal(t0.Add(time.Minute)) {
		t.Fatalf("end: %+v", got)
	}
	again := End(got, t0.Add(time.Hour))
	if !again.StateSince.Equal(got.StateSince) {
		t.Fatal("ending an ended session must not move state_since")
	}
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd server && go test ./internal/machine/`
Expected: FAIL, `undefined: Apply` (and `Ack`, `End`, `ErrNotDone`).

- [ ] **Step 5: Implement the state machine**

Create `server/internal/machine/machine.go`:

```go
// Package machine is the pure session state machine from spec section 4.2.
package machine

import (
	"errors"
	"path/filepath"
	"time"

	"mudo/internal/model"
)

var ErrNotDone = errors.New("session is not done")

// Apply folds one hook event into a session. prev is nil for a session the
// daemon has not seen yet. It reports whether the session changed.
func Apply(prev *model.Session, ev model.Event, host string, now time.Time) (model.Session, bool) {
	if prev == nil {
		return model.Session{
			ID: ev.SessionID, Agent: ev.Agent, Host: host,
			Cwd: ev.Cwd, Project: projectName(ev.Cwd),
			State: initialState(ev.Kind), StateSince: now,
			PID: ev.PID, PIDStart: ev.PIDStart,
			LastPrompt: ev.Prompt, UpdatedAt: now,
		}, true
	}

	s := *prev
	changed := false
	if ev.Cwd != "" && ev.Cwd != s.Cwd {
		s.Cwd, s.Project = ev.Cwd, projectName(ev.Cwd)
		changed = true
	}
	if ev.PID != 0 && (ev.PID != s.PID || ev.PIDStart != s.PIDStart) {
		s.PID, s.PIDStart = ev.PID, ev.PIDStart
		changed = true
	}
	if ev.Kind == model.EvPrompt && ev.Prompt != s.LastPrompt {
		s.LastPrompt = ev.Prompt
		changed = true
	}
	if next := transition(s.State, ev.Kind); next != s.State {
		s.State, s.StateSince = next, now
		changed = true
	}
	if changed {
		s.UpdatedAt = now
	}
	return s, changed
}

// Ack marks a done session as seen by the user.
func Ack(s model.Session, now time.Time) (model.Session, error) {
	if s.State != model.StateDone {
		return s, ErrNotDone
	}
	s.State, s.StateSince, s.UpdatedAt = model.StateIdle, now, now
	return s, nil
}

// End marks a session whose process is gone.
func End(s model.Session, now time.Time) model.Session {
	if s.State == model.StateEnded {
		return s
	}
	s.State, s.StateSince, s.UpdatedAt = model.StateEnded, now, now
	return s
}

func transition(from model.State, k model.EventKind) model.State {
	switch k {
	case model.EvSessionStart:
		return model.StateIdle
	case model.EvPrompt:
		return model.StateRunning
	case model.EvTool:
		if from == model.StateWaiting || from == model.StateIdle || from == model.StateDone {
			return model.StateRunning
		}
	case model.EvWaiting:
		if from == model.StateRunning {
			return model.StateWaiting
		}
	case model.EvStop:
		if from == model.StateRunning || from == model.StateWaiting {
			return model.StateDone
		}
	case model.EvSessionEnd:
		return model.StateEnded
	}
	return from
}

func initialState(k model.EventKind) model.State {
	switch k {
	case model.EvPrompt, model.EvTool:
		return model.StateRunning
	case model.EvWaiting:
		return model.StateWaiting
	case model.EvStop:
		return model.StateDone
	case model.EvSessionEnd:
		return model.StateEnded
	}
	return model.StateIdle
}

func projectName(cwd string) string {
	if cwd == "" {
		return ""
	}
	return filepath.Base(cwd)
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `go test ./internal/machine/ -v`
Expected: PASS for all 7 tests. Also run `go vet ./...` — no output.

- [ ] **Step 7: Commit**

```bash
git add server/internal/model server/internal/machine
git commit -m "feat(server): add session model and state machine"
```

---

### Task 2: /proc parsing and agent PID discovery

**Files:**
- Create: `server/internal/proc/proc.go`, `server/internal/proc/fake.go`
- Test: `server/internal/proc/proc_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `proc.FS{Root string}` — `Root` is `/proc` in production, a temp dir in tests.
  - `(proc.FS).Stat(pid int) (proc.Stat, error)`, `proc.Stat{Comm, State string; PPID int; StartTime uint64}`
  - `(proc.FS).FindAgent(from int, agent string) (pid int, start uint64)`
  - `(proc.FS).Alive(pid int, start uint64) bool`
  - `proc.WriteFakeProcess(root string, pid int, comm string, ppid int, start uint64, cmdline string) error`

- [ ] **Step 1: Write the fake /proc helper**

Create `server/internal/proc/fake.go`:

```go
package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// WriteFakeProcess writes a minimal /proc/<pid>/{stat,cmdline} under root so
// tests in any package can build a fake process tree.
func WriteFakeProcess(root string, pid int, comm string, ppid int, start uint64, cmdline string) error {
	dir := filepath.Join(root, strconv.Itoa(pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// Fields 3..21 then starttime (field 22), then two trailing fields.
	stat := fmt.Sprintf("%d (%s) S %d 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %d 0 0\n", pid, comm, ppid, start)
	if err := os.WriteFile(filepath.Join(dir, "stat"), []byte(stat), 0o644); err != nil {
		return err
	}
	args := strings.ReplaceAll(cmdline, " ", "\x00") + "\x00"
	return os.WriteFile(filepath.Join(dir, "cmdline"), []byte(args), 0o644)
}
```

- [ ] **Step 2: Write the failing tests**

Create `server/internal/proc/proc_test.go`:

```go
package proc

import (
	"os"
	"path/filepath"
	"testing"
)

func fakeTree(t *testing.T) FS {
	t.Helper()
	root := t.TempDir()
	procs := []struct {
		pid, ppid int
		comm      string
		start     uint64
		cmdline   string
	}{
		{100, 1, "code-server", 10, "node /usr/lib/code-server"},
		{200, 100, "bash", 20, "/bin/bash"},
		{300, 200, "claude", 30, "claude"},
		{400, 300, "sh", 40, "sh -c mudod hook --agent claude"},
		{500, 200, "node", 50, "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"},
		{600, 500, "sh", 60, "sh -c mudod hook"},
		{700, 200, "kiro-cli-chat", 70, "kiro-cli chat"},
		{800, 700, "sh", 80, "sh -c mudod hook --agent kiro"},
		{900, 200, "tmux: server", 90, "tmux"},
	}
	for _, p := range procs {
		if err := WriteFakeProcess(root, p.pid, p.comm, p.ppid, p.start, p.cmdline); err != nil {
			t.Fatal(err)
		}
	}
	return FS{Root: root}
}

func TestStatParsesCommWithSpaces(t *testing.T) {
	st, err := fakeTree(t).Stat(900)
	if err != nil {
		t.Fatal(err)
	}
	if st.Comm != "tmux: server" || st.PPID != 200 || st.StartTime != 90 || st.State != "S" {
		t.Fatalf("stat = %+v", st)
	}
}

func TestFindAgent(t *testing.T) {
	fs := fakeTree(t)
	cases := []struct {
		name      string
		from      int
		agent     string
		pid       int
		startTime uint64
	}{
		{"claude binary", 400, "claude", 300, 30},
		{"claude via node", 600, "claude", 500, 50},
		{"kiro", 800, "kiro", 700, 70},
		{"fallback to caller", 400, "kiro", 400, 40},
	}
	for _, c := range cases {
		pid, start := fs.FindAgent(c.from, c.agent)
		if pid != c.pid || start != c.startTime {
			t.Errorf("%s: got %d/%d, want %d/%d", c.name, pid, start, c.pid, c.startTime)
		}
	}
}

func TestFindAgentMissingProcess(t *testing.T) {
	pid, start := fakeTree(t).FindAgent(4242, "claude")
	if pid != 4242 || start != 0 {
		t.Fatalf("got %d/%d", pid, start)
	}
}

func TestAlive(t *testing.T) {
	fs := fakeTree(t)
	if !fs.Alive(300, 30) {
		t.Error("running process with matching start time must be alive")
	}
	if !fs.Alive(300, 0) {
		t.Error("unknown start time must only check existence")
	}
	if fs.Alive(300, 31) {
		t.Error("start time mismatch means the PID was reused")
	}
	if fs.Alive(4242, 0) {
		t.Error("missing process must not be alive")
	}
	if err := os.WriteFile(filepath.Join(fs.Root, "300", "stat"),
		[]byte("300 (claude) Z 200 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 30 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if fs.Alive(300, 30) {
		t.Error("zombie must not be alive")
	}
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `go test ./internal/proc/`
Expected: FAIL, `fs.Stat undefined` / `FindAgent undefined`.

- [ ] **Step 4: Implement /proc parsing**

Create `server/internal/proc/proc.go`:

```go
// Package proc reads the Linux /proc filesystem to find and watch agent processes.
package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type FS struct {
	Root string
}

type Stat struct {
	Comm      string
	State     string
	PPID      int
	StartTime uint64
}

func (f FS) Stat(pid int) (Stat, error) {
	data, err := os.ReadFile(filepath.Join(f.Root, strconv.Itoa(pid), "stat"))
	if err != nil {
		return Stat{}, err
	}
	s := string(data)
	open, end := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
	if open < 0 || end < open {
		return Stat{}, fmt.Errorf("proc: malformed stat for %d", pid)
	}
	// fields[0] is stat field 3; field N is fields[N-3].
	fields := strings.Fields(s[end+1:])
	if len(fields) < 20 {
		return Stat{}, fmt.Errorf("proc: short stat for %d", pid)
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return Stat{}, fmt.Errorf("proc: ppid for %d: %w", pid, err)
	}
	start, err := strconv.ParseUint(fields[19], 10, 64)
	if err != nil {
		return Stat{}, fmt.Errorf("proc: starttime for %d: %w", pid, err)
	}
	return Stat{Comm: s[open+1 : end], State: fields[0], PPID: ppid, StartTime: start}, nil
}

// FindAgent walks up from pid `from` to the agent's own process. If none is
// found it returns `from` itself.
func (f FS) FindAgent(from int, agent string) (int, uint64) {
	pid := from
	for i := 0; i < 16 && pid > 1; i++ {
		st, err := f.Stat(pid)
		if err != nil {
			break
		}
		if f.isAgent(pid, st.Comm, agent) {
			return pid, st.StartTime
		}
		pid = st.PPID
	}
	st, err := f.Stat(from)
	if err != nil {
		return from, 0
	}
	return from, st.StartTime
}

// Alive reports whether pid exists, is not a zombie, and (when start is
// known) is the same process that was first seen.
func (f FS) Alive(pid int, start uint64) bool {
	st, err := f.Stat(pid)
	if err != nil || st.State == "Z" {
		return false
	}
	return start == 0 || st.StartTime == start
}

func (f FS) isAgent(pid int, comm, agent string) bool {
	switch agent {
	case "claude":
		if comm == "claude" {
			return true
		}
		return comm == "node" && strings.Contains(f.cmdline(pid), "claude")
	case "kiro":
		return strings.HasPrefix(comm, "kiro")
	}
	return false
}

func (f FS) cmdline(pid int) string {
	b, err := os.ReadFile(filepath.Join(f.Root, strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(b), "\x00", " ")
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/proc/ -v`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add server/internal/proc
git commit -m "feat(server): find agent PID and check liveness via /proc"
```

---

### Task 3: Hook payload normalization and silent hook runner

**Files:**
- Create: `server/internal/hook/normalize.go`, `server/internal/hook/run.go`
- Test: `server/internal/hook/normalize_test.go`, `server/internal/hook/run_test.go`

**Interfaces:**
- Consumes: `model.Event`, `model.EvKind*` (Task 1); `proc.FS`, `proc.WriteFakeProcess` (Task 2).
- Produces:
  - `hook.Normalize(agent string, payload []byte) (model.Event, bool, error)` — `bool` false means "event we ignore".
  - `hook.Truncate(s string, n int) string`
  - `hook.Options{Agent string; Stdin io.Reader; IngestURL, LogPath string; Dump bool; Proc proc.FS; PPID int; Cwd string; Client *http.Client}`
  - `hook.Run(o hook.Options)` — never returns an error, never writes to stdout/stderr.

- [ ] **Step 1: Write the failing normalization tests**

Create `server/internal/hook/normalize_test.go`:

```go
package hook

import (
	"strings"
	"testing"

	"mudo/internal/model"
)

func TestNormalize(t *testing.T) {
	cases := []struct {
		name    string
		agent   string
		payload string
		want    model.Event
		ok      bool
	}{
		{"claude stop", "claude",
			`{"hook_event_name":"Stop","session_id":"abc","cwd":"/w/api"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w/api", Kind: model.EvStop}, true},
		{"claude prompt", "claude",
			`{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/w/api","prompt":"fix  the\nbug"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w/api", Kind: model.EvPrompt, Prompt: "fix the bug"}, true},
		{"claude permission prompt", "claude",
			`{"hook_event_name":"Notification","session_id":"abc","cwd":"/w","notification_type":"permission_prompt"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvWaiting}, true},
		{"claude elicitation", "claude",
			`{"hook_event_name":"Notification","session_id":"abc","cwd":"/w","notification_type":"elicitation_dialog"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvWaiting}, true},
		{"claude idle notification ignored", "claude",
			`{"hook_event_name":"Notification","session_id":"abc","notification_type":"idle_prompt"}`,
			model.Event{}, false},
		{"claude session end", "claude",
			`{"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/w","reason":"prompt_input_exit"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvSessionEnd}, true},
		{"claude pre tool use", "claude",
			`{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/w","tool_name":"Bash"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvTool}, true},
		{"kiro v3 session start", "kiro",
			`{"hook_event_name":"SessionStart","session_id":"k1","cwd":"/w"}`,
			model.Event{Agent: "kiro", SessionID: "k1", Cwd: "/w", Kind: model.EvSessionStart}, true},
		{"kiro camelCase fields", "kiro",
			`{"hookEventName":"agentSpawn","sessionId":"k1","cwd":"/w"}`,
			model.Event{Agent: "kiro", SessionID: "k1", Cwd: "/w", Kind: model.EvSessionStart}, true},
		{"kiro lower-case stop", "kiro",
			`{"hook_event_name":"stop","session_id":"k1","cwd":"/w"}`,
			model.Event{Agent: "kiro", SessionID: "k1", Cwd: "/w", Kind: model.EvStop}, true},
		{"unknown event ignored", "claude",
			`{"hook_event_name":"PostToolUse","session_id":"abc"}`,
			model.Event{}, false},
	}
	for _, c := range cases {
		got, ok, err := Normalize(c.agent, []byte(c.payload))
		if err != nil {
			t.Errorf("%s: unexpected error %v", c.name, err)
			continue
		}
		if ok != c.ok || got != c.want {
			t.Errorf("%s: got %+v ok=%v, want %+v ok=%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestNormalizeRejectsBadJSON(t *testing.T) {
	if _, _, err := Normalize("claude", []byte("not json")); err == nil {
		t.Fatal("expected error")
	}
}

func TestTruncate(t *testing.T) {
	long := strings.Repeat("é", 100)
	got := Truncate(long, 80)
	if n := len([]rune(got)); n != 80 {
		t.Fatalf("len = %d runes", n)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("missing ellipsis: %q", got)
	}
	if got := Truncate("short", 80); got != "short" {
		t.Fatalf("short string changed: %q", got)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/hook/`
Expected: FAIL, `undefined: Normalize`.

- [ ] **Step 3: Implement normalization**

Create `server/internal/hook/normalize.go`:

```go
// Package hook turns one agent hook invocation into a model.Event.
package hook

import (
	"encoding/json"
	"fmt"
	"strings"

	"mudo/internal/model"
)

const promptLimit = 80

// Normalize decodes a Claude Code or Kiro CLI hook payload. It returns
// ok=false for events MuDo does not track.
func Normalize(agent string, payload []byte) (model.Event, bool, error) {
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		return model.Event{}, false, fmt.Errorf("hook: decode payload: %w", err)
	}
	kind, ok := kindFor(str(m, "hook_event_name", "hookEventName", "event"), str(m, "notification_type", "notificationType"))
	if !ok {
		return model.Event{}, false, nil
	}
	ev := model.Event{
		Agent:     agent,
		SessionID: str(m, "session_id", "sessionId"),
		Cwd:       str(m, "cwd"),
		Kind:      kind,
	}
	if kind == model.EvPrompt {
		ev.Prompt = Truncate(str(m, "prompt"), promptLimit)
	}
	return ev, true, nil
}

// Truncate collapses whitespace and cuts s to at most n runes, ending with "…" when cut.
func Truncate(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func kindFor(name, notification string) (model.EventKind, bool) {
	switch strings.ToLower(name) {
	case "sessionstart", "agentspawn":
		return model.EvSessionStart, true
	case "userpromptsubmit":
		return model.EvPrompt, true
	case "pretooluse":
		return model.EvTool, true
	case "notification":
		if notification == "permission_prompt" || notification == "elicitation_dialog" {
			return model.EvWaiting, true
		}
	case "stop":
		return model.EvStop, true
	case "sessionend":
		return model.EvSessionEnd, true
	}
	return "", false
}

func str(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}
```

- [ ] **Step 4: Run normalization tests to verify they pass**

Run: `go test ./internal/hook/ -run 'TestNormalize|TestTruncate' -v`
Expected: PASS.

- [ ] **Step 5: Write the failing runner tests**

Create `server/internal/hook/run_test.go`:

```go
package hook

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"mudo/internal/model"
	"mudo/internal/proc"
)

func fakeProc(t *testing.T) proc.FS {
	t.Helper()
	root := t.TempDir()
	if err := proc.WriteFakeProcess(root, 300, "claude", 1, 555, "claude"); err != nil {
		t.Fatal(err)
	}
	if err := proc.WriteFakeProcess(root, 400, "sh", 300, 600, "sh -c mudod"); err != nil {
		t.Fatal(err)
	}
	return proc.FS{Root: root}
}

func capture(t *testing.T) (*httptest.Server, chan model.Event) {
	t.Helper()
	got := make(chan model.Event, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var ev model.Event
		if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
			t.Errorf("decode: %v", err)
		}
		got <- ev
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(srv.Close)
	return srv, got
}

func options(t *testing.T, srvURL string, payload string) Options {
	return Options{
		Agent:     "claude",
		Stdin:     strings.NewReader(payload),
		IngestURL: srvURL,
		LogPath:   filepath.Join(t.TempDir(), "hook.log"),
		Proc:      fakeProc(t),
		PPID:      400,
		Cwd:       "/fallback",
		Client:    &http.Client{Timeout: 500 * time.Millisecond},
	}
}

func next(t *testing.T, ch chan model.Event) model.Event {
	t.Helper()
	select {
	case ev := <-ch:
		return ev
	case <-time.After(time.Second):
		t.Fatal("no event posted")
		return model.Event{}
	}
}

func TestRunPostsNormalizedEvent(t *testing.T) {
	srv, got := capture(t)
	Run(options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"abc","cwd":"/w/api"}`))
	want := model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w/api", Kind: model.EvStop, PID: 300, PIDStart: 555}
	if ev := next(t, got); ev != want {
		t.Fatalf("got %+v, want %+v", ev, want)
	}
}

func TestRunFillsMissingSessionAndCwd(t *testing.T) {
	srv, got := capture(t)
	Run(options(t, srv.URL, `{"hook_event_name":"Stop"}`))
	ev := next(t, got)
	if ev.SessionID != "claude-300" || ev.Cwd != "/fallback" {
		t.Fatalf("got %+v", ev)
	}
}

func TestRunSkipsIgnoredEvents(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	Run(options(t, srv.URL, `{"hook_event_name":"PostToolUse","session_id":"abc"}`))
	if n := calls.Load(); n != 0 {
		t.Fatalf("ingest called %d times", n)
	}
}

func TestRunLogsWhenDaemonIsDown(t *testing.T) {
	o := options(t, "http://127.0.0.1:1/event", `{"hook_event_name":"Stop","session_id":"abc"}`)
	Run(o)
	data, err := os.ReadFile(o.LogPath)
	if err != nil || !strings.Contains(string(data), "post event") {
		t.Fatalf("log = %q, err = %v", data, err)
	}
}

func TestRunDumpsPayload(t *testing.T) {
	srv, got := capture(t)
	o := options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"dumped"}`)
	o.Dump = true
	Run(o)
	next(t, got)
	data, _ := os.ReadFile(o.LogPath)
	if !strings.Contains(string(data), `"session_id":"dumped"`) {
		t.Fatalf("payload not dumped: %q", data)
	}
}

func TestRunLogsBadJSON(t *testing.T) {
	o := options(t, "http://127.0.0.1:1/event", `nope`)
	Run(o)
	data, _ := os.ReadFile(o.LogPath)
	if !strings.Contains(string(data), "decode payload") {
		t.Fatalf("log = %q", data)
	}
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `go test ./internal/hook/`
Expected: FAIL, `undefined: Run` / `undefined: Options`.

- [ ] **Step 7: Implement the runner**

Create `server/internal/hook/run.go`:

```go
package hook

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"mudo/internal/proc"
)

const (
	maxPayload = 1 << 20
	maxLogSize = 1 << 20
)

type Options struct {
	Agent     string
	Stdin     io.Reader
	IngestURL string
	LogPath   string
	Dump      bool
	Proc      proc.FS
	PPID      int
	Cwd       string // used when the payload has no cwd
	Client    *http.Client
}

// Run handles one hook invocation. It never fails and never writes to
// stdout or stderr: Kiro adds hook stdout to the agent context and a
// non-zero exit blocks the prompt. Problems go to the log file.
func Run(o Options) {
	payload, err := io.ReadAll(io.LimitReader(o.Stdin, maxPayload))
	if err != nil {
		logf(o.LogPath, "read stdin: %v", err)
		return
	}
	if o.Dump {
		logf(o.LogPath, "dump agent=%s payload=%s", o.Agent, payload)
	}
	ev, ok, err := Normalize(o.Agent, payload)
	if err != nil {
		logf(o.LogPath, "%v", err)
		return
	}
	if !ok {
		return
	}
	ev.PID, ev.PIDStart = o.Proc.FindAgent(o.PPID, o.Agent)
	if ev.Cwd == "" {
		ev.Cwd = o.Cwd
	}
	if ev.SessionID == "" {
		ev.SessionID = fmt.Sprintf("%s-%d", o.Agent, ev.PID)
	}
	body, err := json.Marshal(ev)
	if err != nil {
		logf(o.LogPath, "encode event: %v", err)
		return
	}
	resp, err := o.Client.Post(o.IngestURL, "application/json", bytes.NewReader(body))
	if err != nil {
		logf(o.LogPath, "post event: %v", err)
		return
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		logf(o.LogPath, "post event: status %d", resp.StatusCode)
	}
}

func logf(path, format string, args ...any) {
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return
	}
	if fi, err := os.Stat(path); err == nil && fi.Size() > maxLogSize {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().UTC().Format(time.RFC3339), fmt.Sprintf(format, args...))
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `go test ./internal/hook/ -v`
Expected: PASS (all normalize and run tests).

- [ ] **Step 9: Commit**

```bash
git add server/internal/hook
git commit -m "feat(server): normalize Claude/Kiro hook payloads and post silently"
```

---

### Task 4: Session store (subscribers, sweep, persistence)

**Files:**
- Create: `server/internal/store/store.go`
- Test: `server/internal/store/store_test.go`

**Interfaces:**
- Consumes: `model.*` (Task 1), `machine.Apply/Ack/End/ErrNotDone` (Task 1).
- Produces:
  - `store.Options{Host, Path string; Now func() time.Time; Alive func(pid int, start uint64) bool; EndedTTL time.Duration}` (zero values → `time.Now`, always-alive, 1 h; empty `Path` disables persistence)
  - `store.New(o store.Options) *store.Store`
  - `(*Store).Load() error`, `Flush() error`, `Apply(ev model.Event)`, `Ack(id string) error`, `Snapshot() []model.Session` (sorted by ID, never nil), `Sweep()`
  - `(*Store).Subscribe(buf int) (<-chan store.Msg, []model.Session, func())` — channel is closed when the subscriber falls behind or cancels.
  - `(*Store).Run(ctx context.Context, sweepEvery time.Duration, onErr func(error))`
  - `store.Msg{Type store.MsgType; Session model.Session; ID string}`, `store.MsgUpsert`, `store.MsgRemove`, `store.ErrNotFound`

- [ ] **Step 1: Write the failing tests**

Create `server/internal/store/store_test.go`:

```go
package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"mudo/internal/machine"
	"mudo/internal/model"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

type clock struct{ now time.Time }

func (c *clock) Now() time.Time { return c.now }

func newStore(t *testing.T, c *clock, alive func(int, uint64) bool) *Store {
	t.Helper()
	return New(Options{Host: "devbox", Path: filepath.Join(t.TempDir(), "state.json"), Now: c.Now, Alive: alive})
}

func ev(id string, k model.EventKind) model.Event {
	return model.Event{Agent: "claude", SessionID: id, Cwd: "/w/api", Kind: k, PID: 42, PIDStart: 7}
}

func recv(t *testing.T, ch <-chan Msg) Msg {
	t.Helper()
	select {
	case m, ok := <-ch:
		if !ok {
			t.Fatal("channel closed")
		}
		return m
	case <-time.After(time.Second):
		t.Fatal("no message")
	}
	return Msg{}
}

func expectQuiet(t *testing.T, ch <-chan Msg) {
	t.Helper()
	select {
	case m := <-ch:
		t.Fatalf("unexpected message %+v", m)
	default:
	}
}

func TestApplyBroadcastsChangesOnly(t *testing.T) {
	s := newStore(t, &clock{t0}, nil)
	ch, snap, cancel := s.Subscribe(8)
	defer cancel()
	if snap == nil || len(snap) != 0 {
		t.Fatalf("initial snapshot = %#v", snap)
	}
	s.Apply(ev("s1", model.EvPrompt))
	if m := recv(t, ch); m.Type != MsgUpsert || m.Session.State != model.StateRunning || m.Session.Host != "devbox" {
		t.Fatalf("got %+v", m)
	}
	s.Apply(ev("s1", model.EvTool))
	expectQuiet(t, ch)
}

func TestSubscribeReturnsCurrentSnapshot(t *testing.T) {
	s := newStore(t, &clock{t0}, nil)
	s.Apply(ev("b", model.EvPrompt))
	s.Apply(ev("a", model.EvStop))
	_, snap, cancel := s.Subscribe(8)
	defer cancel()
	if len(snap) != 2 || snap[0].ID != "a" || snap[1].ID != "b" {
		t.Fatalf("snapshot = %+v", snap)
	}
}

func TestAck(t *testing.T) {
	s := newStore(t, &clock{t0}, nil)
	s.Apply(ev("s1", model.EvPrompt))
	if err := s.Ack("s1"); !errors.Is(err, machine.ErrNotDone) {
		t.Fatalf("ack running: %v", err)
	}
	if err := s.Ack("nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ack unknown: %v", err)
	}
	s.Apply(ev("s1", model.EvStop))
	if err := s.Ack("s1"); err != nil {
		t.Fatalf("ack done: %v", err)
	}
	if got := s.Snapshot()[0].State; got != model.StateIdle {
		t.Fatalf("state after ack = %s", got)
	}
}

func TestSweepEndsDeadSessionsAndExpiresEnded(t *testing.T) {
	c := &clock{t0}
	dead := map[int]bool{}
	s := newStore(t, c, func(pid int, _ uint64) bool { return !dead[pid] })
	s.Apply(ev("s1", model.EvPrompt))
	ch, _, cancel := s.Subscribe(8)
	defer cancel()

	s.Sweep()
	expectQuiet(t, ch)

	dead[42] = true
	s.Sweep()
	if m := recv(t, ch); m.Type != MsgUpsert || m.Session.State != model.StateEnded {
		t.Fatalf("got %+v", m)
	}

	c.now = t0.Add(59 * time.Minute)
	s.Sweep()
	expectQuiet(t, ch)

	c.now = t0.Add(61 * time.Minute)
	s.Sweep()
	if m := recv(t, ch); m.Type != MsgRemove || m.ID != "s1" {
		t.Fatalf("got %+v", m)
	}
	if n := len(s.Snapshot()); n != 0 {
		t.Fatalf("%d sessions left", n)
	}
}

func TestSweepIgnoresSessionsWithoutPID(t *testing.T) {
	s := newStore(t, &clock{t0}, func(int, uint64) bool { return false })
	e := ev("s1", model.EvPrompt)
	e.PID = 0
	s.Apply(e)
	s.Sweep()
	if got := s.Snapshot()[0].State; got != model.StateRunning {
		t.Fatalf("state = %s", got)
	}
}

func TestSlowSubscriberIsDropped(t *testing.T) {
	s := newStore(t, &clock{t0}, nil)
	ch, _, cancel := s.Subscribe(1)
	defer cancel()
	s.Apply(ev("s1", model.EvPrompt))
	s.Apply(ev("s2", model.EvPrompt))
	<-ch
	if _, ok := <-ch; ok {
		t.Fatal("expected channel closed after overflow")
	}
}

func TestFlushAndLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	c := &clock{t0}
	s := New(Options{Host: "devbox", Path: path, Now: c.Now})
	s.Apply(ev("s1", model.EvPrompt))
	if err := s.Flush(); err != nil {
		t.Fatal(err)
	}
	s2 := New(Options{Host: "devbox", Path: path, Now: c.Now})
	if err := s2.Load(); err != nil {
		t.Fatal(err)
	}
	got := s2.Snapshot()
	if len(got) != 1 || got[0].State != model.StateRunning || !got[0].StateSince.Equal(t0) {
		t.Fatalf("loaded %+v", got)
	}
}

func TestLoadMissingFileIsEmpty(t *testing.T) {
	s := New(Options{Path: filepath.Join(t.TempDir(), "missing.json")})
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	if n := len(s.Snapshot()); n != 0 {
		t.Fatalf("%d sessions", n)
	}
}

func TestRunWritesStateAfterChange(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	s := New(Options{Host: "devbox", Path: path})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		s.Run(ctx, time.Hour, func(err error) { t.Error(err) })
		close(done)
	}()
	s.Apply(ev("s1", model.EvPrompt))
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("state file not written")
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	<-done
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/store/`
Expected: FAIL, `undefined: New` / `Options` / `Msg`.

- [ ] **Step 3: Implement the store**

Create `server/internal/store/store.go`:

```go
// Package store holds live sessions, broadcasts changes and persists them.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"mudo/internal/machine"
	"mudo/internal/model"
)

var ErrNotFound = errors.New("session not found")

type MsgType string

const (
	MsgUpsert MsgType = "upsert"
	MsgRemove MsgType = "remove"
)

type Msg struct {
	Type    MsgType
	Session model.Session
	ID      string
}

type Options struct {
	Host     string
	Path     string // state file; empty disables persistence
	Now      func() time.Time
	Alive    func(pid int, start uint64) bool
	EndedTTL time.Duration
}

// Store is safe for concurrent use. Every mutation broadcasts while holding
// the lock, so all subscribers see changes in the same order.
type Store struct {
	opts     Options
	mu       sync.Mutex
	sessions map[string]model.Session
	subs     map[chan Msg]struct{}
	dirty    chan struct{}
}

func New(o Options) *Store {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Alive == nil {
		o.Alive = func(int, uint64) bool { return true }
	}
	if o.EndedTTL == 0 {
		o.EndedTTL = time.Hour
	}
	return &Store{
		opts:     o,
		sessions: map[string]model.Session{},
		subs:     map[chan Msg]struct{}{},
		dirty:    make(chan struct{}, 1),
	}
}

func (s *Store) Load() error {
	if s.opts.Path == "" {
		return nil
	}
	data, err := os.ReadFile(s.opts.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var list []model.Session
	if err := json.Unmarshal(data, &list); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, x := range list {
		s.sessions[x.ID] = x
	}
	return nil
}

func (s *Store) Apply(ev model.Event) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var prev *model.Session
	if cur, ok := s.sessions[ev.SessionID]; ok {
		prev = &cur
	}
	next, changed := machine.Apply(prev, ev, s.opts.Host, s.now())
	if changed {
		s.put(next)
	}
}

func (s *Store) Ack(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, ok := s.sessions[id]
	if !ok {
		return ErrNotFound
	}
	next, err := machine.Ack(cur, s.now())
	if err != nil {
		return err
	}
	s.put(next)
	return nil
}

func (s *Store) Snapshot() []model.Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked()
}

// Subscribe registers a listener and returns the snapshot it starts from.
// The channel is closed if the listener falls behind by more than buf
// messages, or when cancel is called.
func (s *Store) Subscribe(buf int) (<-chan Msg, []model.Session, func()) {
	ch := make(chan Msg, buf)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	snap := s.snapshotLocked()
	s.mu.Unlock()
	cancel := func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if _, ok := s.subs[ch]; ok {
			delete(s.subs, ch)
			close(ch)
		}
	}
	return ch, snap, cancel
}

// Sweep ends sessions whose process is gone and deletes long-ended ones.
func (s *Store) Sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for id, x := range s.sessions {
		switch {
		case x.State != model.StateEnded && x.PID != 0 && !s.opts.Alive(x.PID, x.PIDStart):
			s.put(machine.End(x, now))
		case x.State == model.StateEnded && now.Sub(x.StateSince) >= s.opts.EndedTTL:
			delete(s.sessions, id)
			s.broadcast(Msg{Type: MsgRemove, ID: id})
			s.markDirty()
		}
	}
}

// Flush writes the state file atomically.
func (s *Store) Flush() error {
	if s.opts.Path == "" {
		return nil
	}
	data, err := json.MarshalIndent(s.Snapshot(), "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.opts.Path), 0o700); err != nil {
		return err
	}
	tmp := s.opts.Path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.opts.Path)
}

// Run sweeps every sweepEvery and writes the state file 200 ms after the
// last change. It flushes once more and returns when ctx is cancelled.
func (s *Store) Run(ctx context.Context, sweepEvery time.Duration, onErr func(error)) {
	s.Sweep()
	ticker := time.NewTicker(sweepEvery)
	defer ticker.Stop()
	var debounce <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			if err := s.Flush(); err != nil {
				onErr(err)
			}
			return
		case <-ticker.C:
			s.Sweep()
		case <-s.dirty:
			debounce = time.After(200 * time.Millisecond)
		case <-debounce:
			debounce = nil
			if err := s.Flush(); err != nil {
				onErr(err)
			}
		}
	}
}

func (s *Store) now() time.Time { return s.opts.Now().UTC() }

func (s *Store) put(x model.Session) {
	s.sessions[x.ID] = x
	s.broadcast(Msg{Type: MsgUpsert, Session: x, ID: x.ID})
	s.markDirty()
}

func (s *Store) broadcast(m Msg) {
	for ch := range s.subs {
		select {
		case ch <- m:
		default:
			delete(s.subs, ch)
			close(ch)
		}
	}
}

func (s *Store) markDirty() {
	select {
	case s.dirty <- struct{}{}:
	default:
	}
}

func (s *Store) snapshotLocked() []model.Session {
	list := make([]model.Session, 0, len(s.sessions))
	for _, x := range s.sessions {
		list = append(list, x)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	return list
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/store/ -race -v`
Expected: PASS (10 tests), no race reports.

- [ ] **Step 5: Commit**

```bash
git add server/internal/store
git commit -m "feat(server): add session store with SSE fan-out, sweep and persistence"
```

---

### Task 5: Config file and paths

**Files:**
- Create: `server/internal/config/config.go`, `server/internal/paths/paths.go`
- Test: `server/internal/config/config_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `config.Config{Token, Host, IngestAddr, APIAddr string}`
  - `config.Load(path string) (config.Config, error)` — missing file error wraps `fs.ErrNotExist`; fills `IngestAddr` default; errors if `token` or `api_addr` empty.
  - `(config.Config).Write(path string) error` — creates dir 0700, file 0600.
  - `config.NewToken() (string, error)` — 64 hex chars.
  - `config.DefaultIngestAddr = "127.0.0.1:7878"`, `config.DefaultAPIPort = "7879"`
  - `paths.For(home string) paths.Paths{Home, Config, State, HookLog, Bin, Unit, ClaudeSettings, KiroHooks string}`

- [ ] **Step 1: Write the failing config tests**

Create `server/internal/config/config_test.go`:

```go
package config

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mudo", "config.toml")
	want := Config{Token: "abc", Host: "devbox", IngestAddr: "127.0.0.1:9", APIAddr: "100.64.0.5:7879"}
	if err := want.Write(path); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, err = %v", fi.Mode().Perm(), err)
	}
	got, err := Load(path)
	if err != nil || got != want {
		t.Fatalf("got %+v, err %v", got, err)
	}
}

func TestLoadAppliesDefaultsAndIgnoresComments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	content := "# MuDo\n\ntoken = \"abc\"\napi_addr = \"0.0.0.0:7879\"\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.IngestAddr != DefaultIngestAddr || got.Token != "abc" {
		t.Fatalf("got %+v", got)
	}
}

func TestLoadErrors(t *testing.T) {
	dir := t.TempDir()
	if _, err := Load(filepath.Join(dir, "missing")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("missing file: %v", err)
	}
	cases := map[string]string{
		"no token":    "api_addr = \"0.0.0.0:7879\"\n",
		"no api":      "token = \"abc\"\n",
		"bad quote":   "token = abc\n",
		"no equals":   "token\n",
		"unknown key": "token = \"a\"\napi_addr = \"b\"\ncolour = \"red\"\n",
	}
	for name, content := range cases {
		path := filepath.Join(dir, strings.ReplaceAll(name, " ", "_"))
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestNewToken(t *testing.T) {
	a, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewToken()
	if len(a) != 64 || a == b {
		t.Fatalf("tokens %q %q", a, b)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/`
Expected: FAIL, `undefined: Config`.

- [ ] **Step 3: Implement config and paths**

Create `server/internal/config/config.go`:

```go
// Package config reads and writes ~/.config/mudo/config.toml, a flat file of
// `key = "value"` lines (a strict subset of TOML).
package config

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	DefaultIngestAddr = "127.0.0.1:7878"
	DefaultAPIPort    = "7879"
)

type Config struct {
	Token      string
	Host       string
	IngestAddr string
	APIAddr    string
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("config: %w", err)
	}
	var c Config
	fields := map[string]*string{"token": &c.Token, "host": &c.Host, "ingest_addr": &c.IngestAddr, "api_addr": &c.APIAddr}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, raw, ok := strings.Cut(line, "=")
		if !ok {
			return Config{}, fmt.Errorf("config: %s:%d: expected key = \"value\"", path, n)
		}
		dst, known := fields[strings.TrimSpace(key)]
		if !known {
			return Config{}, fmt.Errorf("config: %s:%d: unknown key %q", path, n, strings.TrimSpace(key))
		}
		val, err := strconv.Unquote(strings.TrimSpace(raw))
		if err != nil {
			return Config{}, fmt.Errorf("config: %s:%d: value must be a quoted string", path, n)
		}
		*dst = val
	}
	if c.IngestAddr == "" {
		c.IngestAddr = DefaultIngestAddr
	}
	if c.Token == "" {
		return Config{}, errors.New("config: token is required")
	}
	if c.APIAddr == "" {
		return Config{}, errors.New("config: api_addr is required")
	}
	return c, nil
}

func (c Config) Write(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	content := fmt.Sprintf("# MuDo daemon config\ntoken = %q\nhost = %q\ningest_addr = %q\napi_addr = %q\n",
		c.Token, c.Host, c.IngestAddr, c.APIAddr)
	return os.WriteFile(path, []byte(content), 0o600)
}

func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
```

Create `server/internal/paths/paths.go`:

```go
// Package paths lists every file mudod reads or writes, relative to $HOME.
package paths

import "path/filepath"

type Paths struct {
	Home           string
	Config         string
	State          string
	HookLog        string
	Bin            string
	Unit           string
	ClaudeSettings string
	KiroHooks      string
}

func For(home string) Paths {
	return Paths{
		Home:           home,
		Config:         filepath.Join(home, ".config", "mudo", "config.toml"),
		State:          filepath.Join(home, ".local", "state", "mudo", "state.json"),
		HookLog:        filepath.Join(home, ".local", "state", "mudo", "hook.log"),
		Bin:            filepath.Join(home, ".local", "bin", "mudod"),
		Unit:           filepath.Join(home, ".config", "systemd", "user", "mudod.service"),
		ClaudeSettings: filepath.Join(home, ".claude", "settings.json"),
		KiroHooks:      filepath.Join(home, ".kiro", "hooks", "mudo.json"),
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/ -v && go vet ./...`
Expected: PASS (4 tests), vet clean.

- [ ] **Step 5: Commit**

```bash
git add server/internal/config server/internal/paths
git commit -m "feat(server): add config file and path layout"
```

---

### Task 6: HTTP API (ingest, SSE stream, ack, health)

**Files:**
- Create: `server/internal/api/api.go`
- Test: `server/internal/api/api_test.go`

**Interfaces:**
- Consumes: `store.Store` methods `Apply`, `Ack`, `Subscribe`, `store.MsgUpsert/MsgRemove`, `store.ErrNotFound` (Task 4); `machine.ErrNotDone` (Task 1); `model.Event`, `model.Session` (Task 1).
- Produces:
  - `api.Ingest(st *store.Store) http.Handler` — `POST /event`, 204 on success, 400 on bad body or missing `agent`/`session_id`/`event`.
  - `api.ClientOptions{Token, Host, Version string; Started time.Time; Now func() time.Time; PingEvery time.Duration; SubBuffer int}`
  - `api.Client(st *store.Store, o api.ClientOptions) http.Handler` — `GET /v1/stream`, `POST /v1/sessions/{id}/ack`, `GET /v1/health`, all behind bearer token.
  - Wire format exactly as spec section 5 (`snapshot`, `upsert`, `remove`, `ping`, each with `server_now`).

- [ ] **Step 1: Write the failing tests**

Create `server/internal/api/api_test.go`:

```go
package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"mudo/internal/model"
	"mudo/internal/store"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

func setup(t *testing.T) (*store.Store, *httptest.Server) {
	t.Helper()
	st := store.New(store.Options{Host: "devbox", Now: func() time.Time { return t0 }})
	srv := httptest.NewServer(Client(st, ClientOptions{
		Token: "secret", Host: "devbox", Version: "test", Started: t0,
		Now:       func() time.Time { return t0.Add(90 * time.Second) },
		PingEvery: 50 * time.Millisecond, SubBuffer: 8,
	}))
	t.Cleanup(srv.Close)
	return st, srv
}

func request(t *testing.T, ctx context.Context, method, url, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func readEvent(t *testing.T, r *bufio.Reader) (string, []byte) {
	t.Helper()
	var name string
	var data []byte
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatalf("read stream: %v", err)
		}
		line = strings.TrimRight(line, "\n")
		switch {
		case line == "" && name != "":
			return name, data
		case strings.HasPrefix(line, "event: "):
			name = strings.TrimPrefix(line, "event: ")
		case strings.HasPrefix(line, "data: "):
			data = []byte(strings.TrimPrefix(line, "data: "))
		}
	}
}

func prompt(id string) model.Event {
	return model.Event{Agent: "claude", SessionID: id, Cwd: "/w/api", Kind: model.EvPrompt, Prompt: "hi"}
}

func TestRejectsBadToken(t *testing.T) {
	_, srv := setup(t)
	for _, token := range []string{"", "wrong"} {
		resp := request(t, context.Background(), "GET", srv.URL+"/v1/health", token)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("token %q: status %d", token, resp.StatusCode)
		}
	}
}

func TestHealth(t *testing.T) {
	_, srv := setup(t)
	resp := request(t, context.Background(), "GET", srv.URL+"/v1/health", "secret")
	defer resp.Body.Close()
	var got struct {
		Version string `json:"version"`
		Uptime  int    `json:"uptime_s"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 || got.Version != "test" || got.Uptime != 90 {
		t.Fatalf("status %d, body %+v", resp.StatusCode, got)
	}
}

func TestAck(t *testing.T) {
	st, srv := setup(t)
	st.Apply(prompt("s1"))
	ack := func(id string) int {
		resp := request(t, context.Background(), "POST", srv.URL+"/v1/sessions/"+id+"/ack", "secret")
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := ack("nope"); code != http.StatusNotFound {
		t.Errorf("unknown: %d", code)
	}
	if code := ack("s1"); code != http.StatusConflict {
		t.Errorf("running: %d", code)
	}
	st.Apply(model.Event{Agent: "claude", SessionID: "s1", Kind: model.EvStop})
	if code := ack("s1"); code != http.StatusNoContent {
		t.Errorf("done: %d", code)
	}
}

func TestStream(t *testing.T) {
	st, srv := setup(t)
	st.Apply(prompt("existing"))
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp := request(t, ctx, "GET", srv.URL+"/v1/stream", "secret")
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type %q", ct)
	}
	r := bufio.NewReader(resp.Body)

	name, data := readEvent(t, r)
	var snap struct {
		ServerNow time.Time       `json:"server_now"`
		Host      string          `json:"host"`
		Sessions  []model.Session `json:"sessions"`
	}
	if err := json.Unmarshal(data, &snap); err != nil || name != "snapshot" {
		t.Fatalf("first event %s %s (%v)", name, data, err)
	}
	if snap.Host != "devbox" || len(snap.Sessions) != 1 || !snap.ServerNow.Equal(t0.Add(90*time.Second)) {
		t.Fatalf("snapshot %+v", snap)
	}

	st.Apply(prompt("new"))
	for {
		name, data = readEvent(t, r)
		if name != "ping" {
			break
		}
	}
	var up struct {
		ServerNow time.Time     `json:"server_now"`
		Session   model.Session `json:"session"`
	}
	if err := json.Unmarshal(data, &up); err != nil || name != "upsert" {
		t.Fatalf("event %s %s (%v)", name, data, err)
	}
	if up.Session.ID != "new" || up.Session.State != model.StateRunning || up.ServerNow.IsZero() {
		t.Fatalf("upsert %+v", up)
	}
}

func TestStreamPings(t *testing.T) {
	_, srv := setup(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp := request(t, ctx, "GET", srv.URL+"/v1/stream", "secret")
	defer resp.Body.Close()
	r := bufio.NewReader(resp.Body)
	readEvent(t, r)
	if name, data := readEvent(t, r); name != "ping" || !strings.Contains(string(data), "server_now") {
		t.Fatalf("got %s %s", name, data)
	}
}

func TestIngest(t *testing.T) {
	st := store.New(store.Options{Host: "devbox"})
	srv := httptest.NewServer(Ingest(st))
	defer srv.Close()
	post := func(body string) int {
		resp, err := http.Post(srv.URL+"/event", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := post(`{"agent":"claude","session_id":"s1","event":"prompt","cwd":"/w"}`); code != http.StatusNoContent {
		t.Fatalf("valid event: %d", code)
	}
	if n := len(st.Snapshot()); n != 1 {
		t.Fatalf("%d sessions", n)
	}
	if code := post(`nope`); code != http.StatusBadRequest {
		t.Errorf("bad json: %d", code)
	}
	if code := post(`{"agent":"claude","event":"prompt"}`); code != http.StatusBadRequest {
		t.Errorf("missing session: %d", code)
	}
	resp, err := http.Get(srv.URL + "/event")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("GET: %d", resp.StatusCode)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/api/`
Expected: FAIL, `undefined: Client` / `Ingest`.

- [ ] **Step 3: Implement the API**

Create `server/internal/api/api.go`:

```go
// Package api serves the localhost ingest endpoint and the client API (spec section 5).
package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"mudo/internal/machine"
	"mudo/internal/model"
	"mudo/internal/store"
)

// Ingest accepts events from `mudod hook`. Bind it to localhost only.
func Ingest(st *store.Store) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /event", func(w http.ResponseWriter, r *http.Request) {
		var ev model.Event
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&ev); err != nil {
			http.Error(w, "bad event", http.StatusBadRequest)
			return
		}
		if ev.Agent == "" || ev.SessionID == "" || ev.Kind == "" {
			http.Error(w, "missing agent, session_id or event", http.StatusBadRequest)
			return
		}
		st.Apply(ev)
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}

type ClientOptions struct {
	Token     string
	Host      string
	Version   string
	Started   time.Time
	Now       func() time.Time
	PingEvery time.Duration
	SubBuffer int
}

// Client serves the token-protected API used by the Mac app.
func Client(st *store.Store, o ClientOptions) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"version":  o.Version,
			"uptime_s": int(o.Now().Sub(o.Started).Seconds()),
		})
	})
	mux.HandleFunc("POST /v1/sessions/{id}/ack", func(w http.ResponseWriter, r *http.Request) {
		switch err := st.Ack(r.PathValue("id")); {
		case err == nil:
			w.WriteHeader(http.StatusNoContent)
		case errors.Is(err, store.ErrNotFound):
			http.Error(w, err.Error(), http.StatusNotFound)
		case errors.Is(err, machine.ErrNotDone):
			http.Error(w, err.Error(), http.StatusConflict)
		default:
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})
	mux.HandleFunc("GET /v1/stream", stream(st, o))
	return requireToken(o.Token, mux)
}

type snapshotMsg struct {
	ServerNow time.Time       `json:"server_now"`
	Host      string          `json:"host"`
	Sessions  []model.Session `json:"sessions"`
}

type upsertMsg struct {
	ServerNow time.Time     `json:"server_now"`
	Session   model.Session `json:"session"`
}

type removeMsg struct {
	ServerNow time.Time `json:"server_now"`
	ID        string    `json:"id"`
}

type pingMsg struct {
	ServerNow time.Time `json:"server_now"`
}

func stream(st *store.Store, o ClientOptions) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "text/event-stream")
		h.Set("Cache-Control", "no-cache")
		h.Set("Connection", "keep-alive")

		ch, snap, cancel := st.Subscribe(o.SubBuffer)
		defer cancel()
		if err := writeEvent(w, "snapshot", snapshotMsg{ServerNow: o.Now().UTC(), Host: o.Host, Sessions: snap}); err != nil {
			return
		}
		flusher.Flush()

		ping := time.NewTicker(o.PingEvery)
		defer ping.Stop()
		for {
			var err error
			select {
			case <-r.Context().Done():
				return
			case <-ping.C:
				err = writeEvent(w, "ping", pingMsg{ServerNow: o.Now().UTC()})
			case m, ok := <-ch:
				if !ok {
					return // fell behind; the client reconnects and gets a fresh snapshot
				}
				switch m.Type {
				case store.MsgUpsert:
					err = writeEvent(w, "upsert", upsertMsg{ServerNow: o.Now().UTC(), Session: m.Session})
				case store.MsgRemove:
					err = writeEvent(w, "remove", removeMsg{ServerNow: o.Now().UTC(), ID: m.ID})
				}
			}
			if err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func writeEvent(w io.Writer, name string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", name, data)
	return err
}

func requireToken(token string, next http.Handler) http.Handler {
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), want) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/api/ -race -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add server/internal/api
git commit -m "feat(server): add ingest and token-protected SSE client API"
```

---

### Task 7: `mudod` binary — hook, serve, version + end-to-end test

**Files:**
- Create: `server/cmd/mudod/main.go`, `server/cmd/mudod/hook.go`, `server/cmd/mudod/serve.go`, `server/cmd/mudod/stubs.go` (temporary)
- Test: `server/cmd/mudod/main_test.go`

**Interfaces:**
- Consumes: `hook.Run/Options` (Task 3), `proc.FS` (Task 2), `store.New/Options`, `(*Store).Load/Run` (Task 4), `config.Load`, `config.Config.Write`, `config.DefaultIngestAddr`, `paths.For` (Task 5), `api.Ingest`, `api.Client`, `api.ClientOptions` (Task 6).
- Produces:
  - CLI: `mudod hook --agent claude|kiro [--ingest URL]`, `mudod serve [--config PATH] [--state PATH]`, `mudod version`.
  - `var version` in package `main` (overridden by `-ldflags "-X main.version=..."`), used by Tasks 8 and 9.
  - `func homePaths() (paths.Paths, error)` in package `main`.
  - `main` dispatches `install`, `uninstall`, `fake` to `runInstall`, `runUninstall`, `runFake`; Task 7 adds temporary stubs for them in `stubs.go` that Tasks 8 and 9 delete.

- [ ] **Step 1: Write the failing end-to-end test**

Create `server/cmd/mudod/main_test.go`:

```go
package main

import (
	"bufio"
	"bytes"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"mudo/internal/config"
	"mudo/internal/paths"
)

func buildBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "mudod")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	return bin
}

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

func startServe(t *testing.T, bin, home string) func() {
	t.Helper()
	cmd := exec.Command(bin, "serve")
	cmd.Env = append(os.Environ(), "HOME="+home)
	var logs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &logs, &logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			if err := cmd.Wait(); err != nil {
				t.Errorf("serve exited with %v\n%s", err, logs.String())
			}
		})
	}
	t.Cleanup(stop)
	return stop
}

func authed(t *testing.T, method, url string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(method, url, nil)
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func waitHealthy(t *testing.T, addr string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest("GET", "http://"+addr+"/v1/health", nil)
		req.Header.Set("Authorization", "Bearer secret")
		if resp, err := http.DefaultClient.Do(req); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("serve never became healthy")
}

func expectEvent(t *testing.T, r *bufio.Reader, want string) string {
	t.Helper()
	for {
		var name, data string
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				t.Fatalf("read stream: %v", err)
			}
			line = strings.TrimRight(line, "\n")
			if line == "" && name != "" {
				break
			}
			if v, ok := strings.CutPrefix(line, "event: "); ok {
				name = v
			}
			if v, ok := strings.CutPrefix(line, "data: "); ok {
				data = v
			}
		}
		if name == "ping" {
			continue
		}
		if name != want {
			t.Fatalf("got event %q (%s), want %q", name, data, want)
		}
		return data
	}
}

func TestHookToStreamEndToEnd(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the binary")
	}
	bin := buildBinary(t)
	home := t.TempDir()
	p := paths.For(home)
	ingestAddr, apiAddr := freeAddr(t), freeAddr(t)
	cfg := config.Config{Token: "secret", Host: "testbox", IngestAddr: ingestAddr, APIAddr: apiAddr}
	if err := cfg.Write(p.Config); err != nil {
		t.Fatal(err)
	}

	stop := startServe(t, bin, home)
	waitHealthy(t, apiAddr)
	resp := authed(t, "GET", "http://"+apiAddr+"/v1/stream")
	r := bufio.NewReader(resp.Body)
	expectEvent(t, r, "snapshot")

	hook := exec.Command(bin, "hook", "--agent", "claude", "--ingest", "http://"+ingestAddr+"/event")
	hook.Env = append(os.Environ(), "HOME="+home)
	hook.Stdin = strings.NewReader(`{"hook_event_name":"UserPromptSubmit","session_id":"e2e","cwd":"/w/api","prompt":"hello"}`)
	out, err := hook.CombinedOutput()
	if err != nil || len(out) != 0 {
		t.Fatalf("hook must exit 0 silently: err=%v out=%q", err, out)
	}
	data := expectEvent(t, r, "upsert")
	if !strings.Contains(data, `"id":"e2e"`) || !strings.Contains(data, `"state":"running"`) || !strings.Contains(data, `"host":"testbox"`) {
		t.Fatalf("upsert = %s", data)
	}
	resp.Body.Close()

	stop()
	state, err := os.ReadFile(p.State)
	if err != nil || !strings.Contains(string(state), `"e2e"`) {
		t.Fatalf("state file: %s (%v)", state, err)
	}

	startServe(t, bin, home)
	waitHealthy(t, apiAddr)
	resp = authed(t, "GET", "http://"+apiAddr+"/v1/stream")
	defer resp.Body.Close()
	if data := expectEvent(t, bufio.NewReader(resp.Body), "snapshot"); !strings.Contains(data, `"id":"e2e"`) {
		t.Fatalf("session lost across restart: %s", data)
	}
}

func TestHookIsSilentWhenDaemonIsDown(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the binary")
	}
	bin := buildBinary(t)
	home := t.TempDir()
	hook := exec.Command(bin, "hook", "--agent", "kiro", "--ingest", "http://127.0.0.1:1/event")
	hook.Env = append(os.Environ(), "HOME="+home)
	hook.Stdin = strings.NewReader(`{"hook_event_name":"Stop","session_id":"x"}`)
	out, err := hook.CombinedOutput()
	if err != nil || len(out) != 0 {
		t.Fatalf("err=%v out=%q", err, out)
	}
	if _, err := os.Stat(paths.For(home).HookLog); err != nil {
		t.Fatalf("hook log not written: %v", err)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./cmd/mudod/`
Expected: FAIL, build error `no Go files in .../cmd/mudod` or `undefined` symbols.

- [ ] **Step 3: Implement main, hook and serve**

Create `server/cmd/mudod/main.go`:

```go
// Command mudod tracks Claude Code and Kiro CLI sessions for the MuDo Mac app.
package main

import (
	"fmt"
	"os"

	"mudo/internal/paths"
)

var version = "0.1.0"

const usage = `usage: mudod <command>

commands:
  hook --agent claude|kiro   called by agent hooks (reads JSON on stdin)
  serve                      run the daemon
  install                    set up daemon, hooks and systemd unit
  uninstall                  remove daemon unit and hooks
  fake                       serve scripted fake sessions for UI work
  version                    print version`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "hook":
		runHook(os.Args[2:])
		os.Exit(0)
	case "serve":
		err = runServe(os.Args[2:])
	case "install":
		err = runInstall(os.Args[2:])
	case "uninstall":
		err = runUninstall(os.Args[2:])
	case "fake":
		err = runFake(os.Args[2:])
	case "version":
		fmt.Println(version)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "mudod:", err)
		os.Exit(1)
	}
}

func homePaths() (paths.Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return paths.Paths{}, err
	}
	return paths.For(home), nil
}
```

Create `server/cmd/mudod/hook.go`:

```go
package main

import (
	"flag"
	"io"
	"net/http"
	"os"
	"time"

	"mudo/internal/config"
	"mudo/internal/hook"
	"mudo/internal/proc"
)

// runHook never prints and never fails; see hook.Run.
func runHook(args []string) {
	fs := flag.NewFlagSet("hook", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	agent := fs.String("agent", "claude", "claude or kiro")
	ingest := fs.String("ingest", "http://"+config.DefaultIngestAddr+"/event", "daemon ingest URL")
	if err := fs.Parse(args); err != nil {
		return
	}
	p, err := homePaths()
	if err != nil {
		return
	}
	cwd, _ := os.Getwd()
	hook.Run(hook.Options{
		Agent:     *agent,
		Stdin:     os.Stdin,
		IngestURL: *ingest,
		LogPath:   p.HookLog,
		Dump:      os.Getenv("MUDO_HOOK_DUMP") == "1",
		Proc:      proc.FS{Root: "/proc"},
		PPID:      os.Getppid(),
		Cwd:       cwd,
		Client:    &http.Client{Timeout: 500 * time.Millisecond},
	})
}
```

Create `server/cmd/mudod/serve.go`:

```go
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"mudo/internal/api"
	"mudo/internal/config"
	"mudo/internal/proc"
	"mudo/internal/store"
)

func runServe(args []string) error {
	p, err := homePaths()
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	cfgPath := fs.String("config", p.Config, "config file")
	statePath := fs.String("state", p.State, "state file")
	_ = fs.Parse(args)

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		return err
	}
	host := cfg.Host
	if host == "" {
		host, _ = os.Hostname()
	}
	logger := log.New(os.Stderr, "mudod: ", log.LstdFlags)

	pfs := proc.FS{Root: "/proc"}
	st := store.New(store.Options{Host: host, Path: *statePath, Alive: pfs.Alive})
	if err := st.Load(); err != nil {
		return fmt.Errorf("load state: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	stored := make(chan struct{})
	go func() {
		st.Run(ctx, 10*time.Second, func(err error) { logger.Printf("persist: %v", err) })
		close(stored)
	}()

	base := func(net.Listener) context.Context { return ctx }
	ingest := &http.Server{Addr: cfg.IngestAddr, Handler: api.Ingest(st), BaseContext: base}
	client := &http.Server{Addr: cfg.APIAddr, BaseContext: base, Handler: api.Client(st, api.ClientOptions{
		Token: cfg.Token, Host: host, Version: version, Started: time.Now(), Now: time.Now,
		PingEvery: 15 * time.Second, SubBuffer: 64,
	})}

	errc := make(chan error, 2)
	for _, srv := range []*http.Server{ingest, client} {
		go func(s *http.Server) { errc <- s.ListenAndServe() }(srv)
	}
	logger.Printf("ingest on %s, api on %s", cfg.IngestAddr, cfg.APIAddr)

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-errc:
		stop()
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = ingest.Shutdown(shutdownCtx)
	_ = client.Shutdown(shutdownCtx)
	<-stored
	if runErr != nil && !errors.Is(runErr, http.ErrServerClosed) {
		return runErr
	}
	return nil
}
```

Create temporary `server/cmd/mudod/stubs.go` so the binary compiles before Tasks 8 and 9:

```go
package main

import "errors"

func runInstall([]string) error   { return errors.New("install: not implemented") }
func runUninstall([]string) error { return errors.New("uninstall: not implemented") }
func runFake([]string) error      { return errors.New("fake: not implemented") }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./cmd/mudod/ -v -count=1`
Expected: PASS (`TestHookToStreamEndToEnd`, `TestHookIsSilentWhenDaemonIsDown`). Then `go test ./... -race` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add server/cmd/mudod
git commit -m "feat(server): add mudod hook and serve commands with end-to-end test"
```

---

### Task 8: `mudod install` / `uninstall`

**Files:**
- Create: `server/internal/install/claude.go`, `server/internal/install/kiro.go`, `server/internal/install/install.go`, `server/cmd/mudod/install.go`
- Modify: `server/cmd/mudod/stubs.go` (remove `runInstall`, `runUninstall`)
- Test: `server/internal/install/claude_test.go`, `server/internal/install/install_test.go`

**Interfaces:**
- Consumes: `config.Load`, `config.Config`, `config.NewToken`, `config.DefaultIngestAddr`, `config.DefaultAPIPort` (Task 5); `paths.For` (Task 5); `version`, `homePaths` in package main (Task 7).
- Produces:
  - `install.ClaudeEvents []string`
  - `install.MergeClaudeSettings(path, command string, now time.Time) (bool, error)`
  - `install.RemoveClaudeHooks(path, command string) (bool, error)`
  - `install.KiroHooks(command string) []byte`
  - `install.SystemdUnit(bin string) string`
  - `install.Options{Home, Self, Hostname, User string; Now func() time.Time; Exec func(name string, args ...string) (string, error)}`
  - `install.Result{ConnectURL string; Warnings []string}`
  - `install.Run(o install.Options) (install.Result, error)`, `install.Uninstall(o install.Options) error`

- [ ] **Step 1: Write the failing Claude/Kiro config tests**

Create `server/internal/install/claude_test.go`:

```go
package install

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

const cmd = "/home/steve/.local/bin/mudod hook --agent claude"

func readSettings(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestMergeClaudeSettingsPreservesExistingHooks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	existing := `{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := MergeClaudeSettings(path, cmd, t0)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	got := readSettings(t, path)
	if got["model"] != "opus" {
		t.Fatalf("model lost: %v", got["model"])
	}
	hooks := got["hooks"].(map[string]any)
	for _, ev := range ClaudeEvents {
		groups, _ := hooks[ev].([]any)
		if !containsCommand(groups, cmd) {
			t.Errorf("%s missing mudod hook", ev)
		}
	}
	if n := len(hooks["Stop"].([]any)); n != 2 {
		t.Errorf("Stop groups = %d, want 2", n)
	}
	note := hooks["Notification"].([]any)[0].(map[string]any)
	if note["matcher"] != "permission_prompt|elicitation_dialog" {
		t.Errorf("notification matcher = %v", note["matcher"])
	}
	backups, _ := filepath.Glob(path + ".mudo-bak-*")
	if len(backups) != 1 {
		t.Fatalf("backups = %v", backups)
	}

	changed, err = MergeClaudeSettings(path, cmd, t0.Add(time.Hour))
	if err != nil || changed {
		t.Fatalf("second merge changed=%v err=%v", changed, err)
	}
	if n := len(readSettings(t, path)["hooks"].(map[string]any)["Stop"].([]any)); n != 2 {
		t.Fatalf("second merge duplicated Stop: %d groups", n)
	}
}

func TestMergeClaudeSettingsCreatesMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude", "settings.json")
	if _, err := MergeClaudeSettings(path, cmd, t0); err != nil {
		t.Fatal(err)
	}
	if _, ok := readSettings(t, path)["hooks"]; !ok {
		t.Fatal("hooks not written")
	}
	if backups, _ := filepath.Glob(path + ".mudo-bak-*"); len(backups) != 0 {
		t.Fatalf("unexpected backup %v", backups)
	}
}

func TestRemoveClaudeHooksKeepsOthers(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	existing := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := MergeClaudeSettings(path, cmd, t0); err != nil {
		t.Fatal(err)
	}
	changed, err := RemoveClaudeHooks(path, cmd)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	hooks := readSettings(t, path)["hooks"].(map[string]any)
	if len(hooks) != 1 {
		t.Fatalf("hooks left: %v", hooks)
	}
	stop := hooks["Stop"].([]any)
	if len(stop) != 1 || containsCommand(stop, cmd) || !containsCommand(stop, "say done") {
		t.Fatalf("Stop = %v", stop)
	}
}

func TestRemoveClaudeHooksMissingFile(t *testing.T) {
	changed, err := RemoveClaudeHooks(filepath.Join(t.TempDir(), "none.json"), cmd)
	if err != nil || changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
}

func TestKiroHooks(t *testing.T) {
	var got struct {
		Version string `json:"version"`
		Hooks   []struct {
			Name    string `json:"name"`
			Trigger string `json:"trigger"`
			Action  struct {
				Type    string `json:"type"`
				Command string `json:"command"`
			} `json:"action"`
			Timeout int  `json:"timeout"`
			Enabled bool `json:"enabled"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(KiroHooks("/x/mudod hook --agent kiro"), &got); err != nil {
		t.Fatal(err)
	}
	if got.Version != "v1" || len(got.Hooks) != 4 {
		t.Fatalf("got %+v", got)
	}
	triggers := []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"}
	for i, h := range got.Hooks {
		if h.Trigger != triggers[i] || h.Action.Type != "command" || h.Action.Command != "/x/mudod hook --agent kiro" || h.Timeout != 2 || !h.Enabled {
			t.Errorf("hook %d = %+v", i, h)
		}
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/install/`
Expected: FAIL, `undefined: MergeClaudeSettings`.

- [ ] **Step 3: Implement Claude and Kiro hook config**

Create `server/internal/install/claude.go`:

```go
// Package install wires mudod into systemd, Claude Code and Kiro CLI.
package install

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// ClaudeEvents are the Claude Code hook events mudod listens to (spec 4.1).
var ClaudeEvents = []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"}

const notificationMatcher = "permission_prompt|elicitation_dialog"

// MergeClaudeSettings adds a mudod hook for every event in ClaudeEvents,
// keeping existing hooks. It backs up an existing file before changing it
// and reports whether anything changed.
func MergeClaudeSettings(path, command string, now time.Time) (bool, error) {
	settings, existed, err := readJSONObject(path)
	if err != nil {
		return false, err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	for _, ev := range ClaudeEvents {
		groups, _ := hooks[ev].([]any)
		if containsCommand(groups, command) {
			continue
		}
		group := map[string]any{"hooks": []any{map[string]any{"type": "command", "command": command}}}
		if ev == "Notification" {
			group["matcher"] = notificationMatcher
		}
		hooks[ev] = append(groups, group)
		changed = true
	}
	if !changed {
		return false, nil
	}
	settings["hooks"] = hooks
	if existed {
		if err := copyFile(path, path+".mudo-bak-"+now.Format("20060102-150405"), 0o644); err != nil {
			return false, err
		}
	}
	return true, writeJSON(path, settings)
}

// RemoveClaudeHooks deletes every hook handler running command, dropping
// groups and events left empty.
func RemoveClaudeHooks(path, command string) (bool, error) {
	settings, existed, err := readJSONObject(path)
	if err != nil || !existed {
		return false, err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	changed := false
	for ev, v := range hooks {
		groups, _ := v.([]any)
		var kept []any
		for _, g := range groups {
			group, ok := g.(map[string]any)
			if !ok {
				kept = append(kept, g)
				continue
			}
			handlers, _ := group["hooks"].([]any)
			var rest []any
			for _, h := range handlers {
				if m, ok := h.(map[string]any); ok && m["command"] == command {
					changed = true
					continue
				}
				rest = append(rest, h)
			}
			if len(rest) == 0 {
				continue
			}
			group["hooks"] = rest
			kept = append(kept, group)
		}
		if len(kept) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = kept
		}
	}
	if !changed {
		return false, nil
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
	return true, writeJSON(path, settings)
}

func containsCommand(groups []any, command string) bool {
	for _, g := range groups {
		group, _ := g.(map[string]any)
		handlers, _ := group["hooks"].([]any)
		for _, h := range handlers {
			if m, ok := h.(map[string]any); ok && m["command"] == command {
				return true
			}
		}
	}
	return false
}

func readJSONObject(path string) (map[string]any, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{}, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	m := map[string]any{}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, true, err
		}
	}
	return m, true, nil
}

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(path, append(data, '\n'), 0o644)
}

// writeFile replaces path atomically, creating parent directories.
func writeFile(path string, data []byte, perm os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	if err := os.Chmod(tmp, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func copyFile(src, dst string, perm os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return writeFile(dst, data, perm)
}
```

Create `server/internal/install/kiro.go`:

```go
package install

import "encoding/json"

type kiroAction struct {
	Type    string `json:"type"`
	Command string `json:"command"`
}

type kiroHook struct {
	Name    string     `json:"name"`
	Trigger string     `json:"trigger"`
	Action  kiroAction `json:"action"`
	Timeout int        `json:"timeout"`
	Enabled bool       `json:"enabled"`
}

// KiroHooks returns ~/.kiro/hooks/mudo.json in the Kiro CLI V3 hook format.
func KiroHooks(command string) []byte {
	var hooks []kiroHook
	for _, trigger := range []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"} {
		hooks = append(hooks, kiroHook{
			Name: "mudo-" + trigger, Trigger: trigger,
			Action:  kiroAction{Type: "command", Command: command},
			Timeout: 2, Enabled: true,
		})
	}
	data, _ := json.MarshalIndent(struct {
		Version string     `json:"version"`
		Hooks   []kiroHook `json:"hooks"`
	}{"v1", hooks}, "", "  ")
	return append(data, '\n')
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/install/ -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing orchestration tests**

Create `server/internal/install/install_test.go`:

```go
package install

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"mudo/internal/config"
	"mudo/internal/paths"
)

type fakeExec struct {
	calls     []string
	tailscale error
}

func (f *fakeExec) run(name string, args ...string) (string, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	switch name {
	case "tailscale":
		if f.tailscale != nil {
			return "", f.tailscale
		}
		return "100.64.0.5\n", nil
	case "loginctl":
		return "Linger=no\n", nil
	}
	return "", nil
}

func options(t *testing.T, ex *fakeExec) Options {
	t.Helper()
	self := filepath.Join(t.TempDir(), "mudod")
	if err := os.WriteFile(self, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	return Options{Home: t.TempDir(), Self: self, Hostname: "devbox", User: "steve",
		Now: func() time.Time { return t0 }, Exec: ex.run}
}

func TestRunInstallsEverything(t *testing.T) {
	ex := &fakeExec{}
	o := options(t, ex)
	res, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	p := paths.For(o.Home)

	if data, err := os.ReadFile(p.Bin); err != nil || string(data) != "binary" {
		t.Fatalf("binary: %q %v", data, err)
	}
	cfg, err := config.Load(p.Config)
	if err != nil || cfg.APIAddr != "100.64.0.5:7879" || cfg.Host != "devbox" || len(cfg.Token) != 64 {
		t.Fatalf("config %+v %v", cfg, err)
	}
	if unit, _ := os.ReadFile(p.Unit); !strings.Contains(string(unit), "ExecStart="+p.Bin+" serve") {
		t.Fatalf("unit = %s", unit)
	}
	if s, _ := os.ReadFile(p.ClaudeSettings); !strings.Contains(string(s), p.Bin+" hook --agent claude") {
		t.Fatalf("claude settings = %s", s)
	}
	if k, _ := os.ReadFile(p.KiroHooks); !strings.Contains(string(k), p.Bin+" hook --agent kiro") {
		t.Fatalf("kiro hooks = %s", k)
	}
	want := "mudo://add?name=devbox&token=" + cfg.Token + "&url=http%3A%2F%2F100.64.0.5%3A7879"
	if res.ConnectURL != want {
		t.Fatalf("connect url = %s", res.ConnectURL)
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "sudo loginctl enable-linger steve") {
		t.Fatalf("warnings = %v", res.Warnings)
	}
	joined := strings.Join(ex.calls, "\n")
	for _, c := range []string{"systemctl --user daemon-reload", "systemctl --user enable mudod.service", "systemctl --user restart mudod.service"} {
		if !strings.Contains(joined, c) {
			t.Errorf("missing call %q in\n%s", c, joined)
		}
	}

	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	cfg2, _ := config.Load(p.Config)
	if cfg2.Token != cfg.Token {
		t.Fatal("re-running install must keep the token")
	}
}

func TestRunWithoutTailscaleBindsLocalhost(t *testing.T) {
	ex := &fakeExec{tailscale: errors.New("not found")}
	o := options(t, ex)
	res, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	cfg, _ := config.Load(paths.For(o.Home).Config)
	if cfg.APIAddr != "127.0.0.1:7879" {
		t.Fatalf("api addr = %s", cfg.APIAddr)
	}
	if !strings.Contains(strings.Join(res.Warnings, "\n"), "api_addr") {
		t.Fatalf("warnings = %v", res.Warnings)
	}
}

func TestUninstall(t *testing.T) {
	ex := &fakeExec{}
	o := options(t, ex)
	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	if err := Uninstall(o); err != nil {
		t.Fatal(err)
	}
	p := paths.For(o.Home)
	for _, f := range []string{p.Unit, p.KiroHooks} {
		if _, err := os.Stat(f); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s still exists", f)
		}
	}
	if s, _ := os.ReadFile(p.ClaudeSettings); strings.Contains(string(s), "mudod") {
		t.Errorf("claude settings still mention mudod: %s", s)
	}
	if _, err := os.Stat(p.Config); err != nil {
		t.Errorf("config must be kept: %v", err)
	}
	if !strings.Contains(strings.Join(ex.calls, "\n"), "systemctl --user disable --now mudod.service") {
		t.Errorf("calls = %v", ex.calls)
	}
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `go test ./internal/install/`
Expected: FAIL, `undefined: Run` / `Options` / `Uninstall`.

- [ ] **Step 7: Implement install orchestration**

Create `server/internal/install/install.go`:

```go
package install

import (
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"mudo/internal/config"
	"mudo/internal/paths"
)

type Options struct {
	Home     string
	Self     string // path of the running mudod binary
	Hostname string
	User     string
	Now      func() time.Time
	Exec     func(name string, args ...string) (string, error)
}

type Result struct {
	ConnectURL string
	Warnings   []string
}

func SystemdUnit(bin string) string {
	return fmt.Sprintf(`[Unit]
Description=MuDo agent session daemon
After=network-online.target

[Service]
ExecStart=%s serve
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
`, bin)
}

// Run performs spec section 4.3. It is safe to run again: the token is
// kept and hooks are not duplicated.
func Run(o Options) (Result, error) {
	p := paths.For(o.Home)
	var res Result

	if err := installBinary(o.Self, p.Bin); err != nil {
		return res, fmt.Errorf("install binary: %w", err)
	}
	cfg, err := ensureConfig(o, p.Config, &res)
	if err != nil {
		return res, err
	}
	if err := writeFile(p.Unit, []byte(SystemdUnit(p.Bin)), 0o644); err != nil {
		return res, fmt.Errorf("write unit: %w", err)
	}
	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", "mudod.service"},
		{"--user", "restart", "mudod.service"},
	} {
		if out, err := o.Exec("systemctl", args...); err != nil {
			return res, fmt.Errorf("systemctl %s: %v: %s", strings.Join(args, " "), err, out)
		}
	}
	if out, err := o.Exec("loginctl", "show-user", o.User, "--property=Linger"); err == nil && strings.TrimSpace(out) == "Linger=no" {
		res.Warnings = append(res.Warnings,
			"lingering is off, so mudod stops when you log out; run: sudo loginctl enable-linger "+o.User)
	}
	if _, err := MergeClaudeSettings(p.ClaudeSettings, p.Bin+" hook --agent claude", o.Now()); err != nil {
		return res, fmt.Errorf("claude hooks: %w", err)
	}
	if err := writeFile(p.KiroHooks, KiroHooks(p.Bin+" hook --agent kiro"), 0o644); err != nil {
		return res, fmt.Errorf("kiro hooks: %w", err)
	}

	q := url.Values{"name": {cfg.Host}, "url": {"http://" + cfg.APIAddr}, "token": {cfg.Token}}
	res.ConnectURL = "mudo://add?" + q.Encode()
	return res, nil
}

// Uninstall removes the unit and MuDo's hooks. Config, state and binary are kept.
func Uninstall(o Options) error {
	p := paths.For(o.Home)
	_, _ = o.Exec("systemctl", "--user", "disable", "--now", "mudod.service")
	if err := os.Remove(p.Unit); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	_, _ = o.Exec("systemctl", "--user", "daemon-reload")
	if _, err := RemoveClaudeHooks(p.ClaudeSettings, p.Bin+" hook --agent claude"); err != nil {
		return fmt.Errorf("claude hooks: %w", err)
	}
	if err := os.Remove(p.KiroHooks); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func installBinary(self, dst string) error {
	a, errA := filepath.Abs(self)
	b, errB := filepath.Abs(dst)
	if errA == nil && errB == nil && a == b {
		return nil
	}
	// copyFile writes a temp file and renames it, so replacing a running binary works.
	return copyFile(self, dst, 0o755)
}

func ensureConfig(o Options, path string, res *Result) (config.Config, error) {
	cfg, err := config.Load(path)
	if err == nil {
		return cfg, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return config.Config{}, err
	}
	token, err := config.NewToken()
	if err != nil {
		return config.Config{}, err
	}
	ip := "127.0.0.1"
	if out, err := o.Exec("tailscale", "ip", "-4"); err == nil && len(strings.Fields(out)) > 0 {
		ip = strings.Fields(out)[0]
	} else {
		res.Warnings = append(res.Warnings,
			"`tailscale ip -4` failed, so the API listens on 127.0.0.1 only; set api_addr in "+path)
	}
	cfg = config.Config{Token: token, Host: o.Hostname, IngestAddr: config.DefaultIngestAddr, APIAddr: ip + ":" + config.DefaultAPIPort}
	return cfg, cfg.Write(path)
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `go test ./internal/install/ -v`
Expected: PASS (8 tests).

- [ ] **Step 9: Wire the CLI**

Create `server/cmd/mudod/install.go`:

```go
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"time"

	"mudo/internal/install"
)

func installOptions() (install.Options, error) {
	p, err := homePaths()
	if err != nil {
		return install.Options{}, err
	}
	self, err := os.Executable()
	if err != nil {
		return install.Options{}, err
	}
	if resolved, err := filepath.EvalSymlinks(self); err == nil {
		self = resolved
	}
	host, _ := os.Hostname()
	u, err := user.Current()
	if err != nil {
		return install.Options{}, err
	}
	return install.Options{
		Home: p.Home, Self: self, Hostname: host, User: u.Username, Now: time.Now,
		Exec: func(name string, args ...string) (string, error) {
			out, err := exec.Command(name, args...).CombinedOutput()
			return string(out), err
		},
	}, nil
}

func runInstall([]string) error {
	o, err := installOptions()
	if err != nil {
		return err
	}
	res, err := install.Run(o)
	for _, w := range res.Warnings {
		fmt.Println("warning:", w)
	}
	if err != nil {
		return err
	}
	fmt.Println("mudod installed and running. Add this server in MuDo (open on the Mac):")
	fmt.Println(res.ConnectURL)
	return nil
}

func runUninstall([]string) error {
	o, err := installOptions()
	if err != nil {
		return err
	}
	if err := install.Uninstall(o); err != nil {
		return err
	}
	p, _ := homePaths()
	fmt.Printf("mudod unit and hooks removed. Kept: %s, %s, %s\n", p.Config, p.State, p.Bin)
	return nil
}
```

Edit `server/cmd/mudod/stubs.go` to leave only:

```go
package main

import "errors"

func runFake([]string) error { return errors.New("fake: not implemented") }
```

- [ ] **Step 10: Run all tests**

Run: `go test ./... -race -count=1`
Expected: PASS for every package.

- [ ] **Step 11: Commit**

```bash
git add server/internal/install server/cmd/mudod
git commit -m "feat(server): add install/uninstall for systemd, Claude and Kiro hooks"
```

---

### Task 9: `mudod fake` for UI development

**Files:**
- Create: `server/internal/fake/fake.go`, `server/cmd/mudod/fake.go`
- Delete: `server/cmd/mudod/stubs.go`
- Test: `server/internal/fake/fake_test.go`

**Interfaces:**
- Consumes: `store.New/Options`, `(*Store).Apply/Subscribe/Snapshot` (Task 4); `api.Client`, `api.ClientOptions` (Task 6); `version` (Task 7).
- Produces:
  - `fake.Script() []model.Event`
  - `fake.Drive(ctx context.Context, st *store.Store, step time.Duration)`
  - CLI: `mudod fake [--addr 0.0.0.0:7879] [--token fake-token] [--step 3s]`

- [ ] **Step 1: Write the failing tests**

Create `server/internal/fake/fake_test.go`:

```go
package fake

import (
	"context"
	"testing"
	"time"

	"mudo/internal/model"
	"mudo/internal/store"
)

func TestScriptVisitsEveryState(t *testing.T) {
	st := store.New(store.Options{Host: "fake"})
	ch, _, cancel := st.Subscribe(64)
	defer cancel()
	for _, ev := range Script() {
		st.Apply(ev)
	}
	seen := map[model.State]bool{}
	for len(ch) > 0 {
		m := <-ch
		seen[m.Session.State] = true
	}
	for _, s := range []model.State{model.StateIdle, model.StateRunning, model.StateWaiting, model.StateDone, model.StateEnded} {
		if !seen[s] {
			t.Errorf("script never reaches %s", s)
		}
	}
}

func TestDriveStopsOnCancel(t *testing.T) {
	st := store.New(store.Options{Host: "fake"})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		Drive(ctx, st, time.Millisecond)
		close(done)
	}()
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Drive did not stop")
	}
	if n := len(st.Snapshot()); n != 3 {
		t.Fatalf("%d sessions, want 3", n)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/fake/`
Expected: FAIL, `undefined: Script`.

- [ ] **Step 3: Implement the fake driver and CLI**

Create `server/internal/fake/fake.go`:

```go
// Package fake replays a scripted session cycle so the Mac app can be built
// without real agents.
package fake

import (
	"context"
	"time"

	"mudo/internal/model"
	"mudo/internal/store"
)

// Script cycles three sessions through every state. Events carry no PID, so
// the store never ends them by liveness.
func Script() []model.Event {
	ev := func(id, agent, cwd string, k model.EventKind, prompt string) model.Event {
		return model.Event{Agent: agent, SessionID: id, Cwd: cwd, Kind: k, Prompt: prompt}
	}
	const (
		api   = "/home/dev/code/api-gateway"
		web   = "/home/dev/code/web-ui"
		infra = "/home/dev/code/infra-tf"
	)
	return []model.Event{
		ev("fake-1", "claude", api, model.EvSessionStart, ""),
		ev("fake-1", "claude", api, model.EvPrompt, "refactor auth middleware to use JWT"),
		ev("fake-2", "kiro", web, model.EvPrompt, "add a dark mode toggle to settings"),
		ev("fake-3", "claude", infra, model.EvPrompt, "plan the VPC module split"),
		ev("fake-1", "claude", api, model.EvWaiting, ""),
		ev("fake-3", "claude", infra, model.EvStop, ""),
		ev("fake-1", "claude", api, model.EvTool, ""),
		ev("fake-2", "kiro", web, model.EvStop, ""),
		ev("fake-1", "claude", api, model.EvStop, ""),
		ev("fake-2", "kiro", web, model.EvSessionEnd, ""),
	}
}

// Drive applies Script in a loop, one event per step, until ctx ends.
func Drive(ctx context.Context, st *store.Store, step time.Duration) {
	script := Script()
	for i := 0; ; i = (i + 1) % len(script) {
		st.Apply(script[i])
		select {
		case <-ctx.Done():
			return
		case <-time.After(step):
		}
	}
}
```

Create `server/cmd/mudod/fake.go`:

```go
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"mudo/internal/api"
	"mudo/internal/fake"
	"mudo/internal/store"
)

func runFake(args []string) error {
	fs := flag.NewFlagSet("fake", flag.ExitOnError)
	addr := fs.String("addr", "0.0.0.0:7879", "listen address")
	token := fs.String("token", "fake-token", "bearer token")
	step := fs.Duration("step", 3*time.Second, "delay between scripted events")
	_ = fs.Parse(args)

	st := store.New(store.Options{Host: "fake"})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go fake.Drive(ctx, st, *step)

	srv := &http.Server{
		Addr:        *addr,
		BaseContext: func(net.Listener) context.Context { return ctx },
		Handler: api.Client(st, api.ClientOptions{
			Token: *token, Host: "fake", Version: version, Started: time.Now(), Now: time.Now,
			PingEvery: 15 * time.Second, SubBuffer: 64,
		}),
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	fmt.Printf("fake mudod on %s, token %q, step %s\n", *addr, *token, *step)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
```

Delete `server/cmd/mudod/stubs.go`:

```bash
git rm server/cmd/mudod/stubs.go
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./... -race -count=1`
Expected: PASS for every package.

Smoke test the fake server:

```bash
go run ./cmd/mudod fake --addr 127.0.0.1:17879 --step 500ms &
sleep 2
curl -sN -m 3 -H 'Authorization: Bearer fake-token' http://127.0.0.1:17879/v1/stream | head -n 12
kill %1
```

Expected: an `event: snapshot` block followed by several `event: upsert` blocks with `"host":"fake"`.

- [ ] **Step 5: Commit**

```bash
git add server/internal/fake server/cmd/mudod
git commit -m "feat(server): add mudod fake for UI development"
```

---

### Task 10: Build, docs and verification on the real server

**Files:**
- Create: `server/Makefile`, `server/README.md`
- Modify: `docs/superpowers/specs/2026-10-14-mudo-design.md` section 10 (record findings)

**Interfaces:**
- Consumes: the full `mudod` binary (Tasks 1–9).
- Produces: `server/dist/mudod-linux-amd64`; verified behavior on the user's real server; answers to spec section 10 open items.

- [ ] **Step 1: Add the Makefile**

Create `server/Makefile`:

```makefile
VERSION ?= 0.1.0
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build test vet clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-linux-amd64 ./cmd/mudod

test:
	go test -race -count=1 ./...

vet:
	go vet ./...

clean:
	rm -rf dist
```

Run: `make vet test build && file dist/mudod-linux-amd64 && ./dist/mudod-linux-amd64 version`
Expected: tests PASS; `file` reports `ELF 64-bit LSB executable, x86-64, ... statically linked`; version prints `0.1.0`.

- [ ] **Step 2: Write the README**

Create `server/README.md`:

````markdown
# mudod

Server-side daemon for MuDo. It receives Claude Code / Kiro CLI hook calls and streams session state to the MuDo Mac app.

## Build

```bash
make test build    # produces dist/mudod-linux-amd64
```

## Install on a server

```bash
scp dist/mudod-linux-amd64 devbox:/tmp/mudod
ssh devbox '/tmp/mudod install'
```

`install`:

- copies the binary to `~/.local/bin/mudod`
- writes `~/.config/mudo/config.toml` (token, `api_addr` = Tailscale IP:7879)
- enables the `mudod` systemd user service
- adds hooks to `~/.claude/settings.json` (backup: `settings.json.mudo-bak-*`)
- writes `~/.kiro/hooks/mudo.json`
- prints a `mudo://add?...` link; open it on the Mac to add the server

If it warns about lingering, run the printed `sudo loginctl enable-linger <user>` so the daemon survives logout.

Running `install` again upgrades the binary and keeps the token.

## Check it works

```bash
systemctl --user status mudod
journalctl --user -u mudod -f
TOKEN=$(sed -n 's/^token = "\(.*\)"/\1/p' ~/.config/mudo/config.toml)
curl -sN -H "Authorization: Bearer $TOKEN" http://$(tailscale ip -4):7879/v1/stream
```

Start a `claude` session in code-server and send a prompt: an `upsert` with `"state":"running"` appears, then `"done"` when it finishes.

Hook errors are logged to `~/.local/state/mudo/hook.log`. Set `MUDO_HOOK_DUMP=1` in the agent's environment to log raw hook payloads.

## Fake server for UI work

```bash
mudod fake --addr 0.0.0.0:7879 --token fake-token --step 3s
```

## Uninstall

```bash
~/.local/bin/mudod uninstall
```

Removes the systemd unit and MuDo's hooks. Config, state and the binary stay.
````

- [ ] **Step 3: Commit build and docs**

```bash
git add server/Makefile server/README.md
git commit -m "docs(server): add Makefile and install guide"
```

- [ ] **Step 4: Install on this server (needs the user)**

The server is the development machine itself (`devbox`, Tailscale IP `100.64.0.10`). Facts checked on 2026-10-16:

- `claude` processes have `comm` = `claude`; Kiro runs as `kiro-cli` → child `kiro-cli-chat` (V3, `--v3`), both matched by `strings.HasPrefix(comm, "kiro")`.
- `~/.claude/settings.json` already has a `PreToolUse` hook; `MergeClaudeSettings` keeps it and writes a backup.
- `~/.kiro/hooks/` does not exist yet; install creates it.
- The agent's sandboxed shell cannot reach the systemd user bus (`Failed to connect to bus: No medium found`), so `install` must be run by the user in a normal terminal, or via `! <command>` in Claude Code if that shell has the bus.

Ask the user to run:

```bash
cd server && make build && ./dist/mudod-linux-amd64 install
```

Expected: no error; a `mudo://add?...` line with `url=http%3A%2F%2F100.64.0.10%3A7879` is printed. Save that line for Plan B (Mac app). If it warns about lingering, ask the user to run the printed `sudo loginctl enable-linger steve`.

Note: the new Claude hooks apply to Claude sessions started after install; already-running sessions (including the one executing this plan) may need a restart before they report.

- [ ] **Step 5: Verify Claude Code end to end**

On the server, in one terminal:

```bash
TOKEN=$(sed -n 's/^token = "\(.*\)"/\1/p' ~/.config/mudo/config.toml)
curl -sN -H "Authorization: Bearer $TOKEN" http://$(tailscale ip -4):7879/v1/stream
```

In a code-server terminal, start `claude`, send a prompt that needs a permission (e.g. "run ls"), approve it, and let it finish. Then exit claude with Ctrl+D twice.

Expected sequence of `state` values for that session: `idle` (SessionStart) → `running` → `waiting` → `running` → `done` → `ended`.

Also check: the session's `pid` is the `claude` process (`ps -o pid,comm -p <pid>` shows `claude`).

- [ ] **Step 6: Verify Kiro CLI and its payload fields**

```bash
MUDO_HOOK_DUMP=1 kiro-cli chat --v3
```

Send one prompt, wait for the answer, exit. Then:

```bash
grep dump ~/.local/state/mudo/hook.log | tail -n 5
```

Expected: payloads with `hook_event_name`, `session_id`, `cwd`, `prompt` (or camelCase variants handled by `Normalize`). If the field names differ from every variant in `hook.Normalize` (`hook_event_name|hookEventName|event`, `session_id|sessionId`, `cwd`, `prompt`), add the real names to the `str(...)` calls in `server/internal/hook/normalize.go`, add a test case with the real payload to `normalize_test.go`, and commit `fix(server): support real Kiro hook fields`.

Also confirm `PreToolUse` fires without a `matcher` in `~/.kiro/hooks/mudo.json` (a `tool` dump appears when Kiro runs a tool). If Kiro requires a matcher, set `"matcher": "*"` in `install/kiro.go`, update `TestKiroHooks`, and commit.

The stream should show the Kiro session going `idle` → `running` → `done`, then `ended` within 10 s of exiting.

- [ ] **Step 7: Record findings in the spec**

Update section 10 of `docs/superpowers/specs/2026-10-14-mudo-design.md`: replace each open item with what was observed (Kiro field names, Claude process name). Commit:

```bash
git add docs/superpowers/specs/2026-10-14-mudo-design.md
git commit -m "docs: record verified hook payloads and process names"
```
