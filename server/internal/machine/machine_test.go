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

// TestCwdDriftIgnored: hooks report the agent's current directory, which moves
// when the agent cd's. Only session_start may re-home an existing session.
func TestCwdDriftIgnored(t *testing.T) {
	cases := map[model.EventKind]bool{ // kind -> whether cwd should change
		model.EvPrompt:       false,
		model.EvTool:         false,
		model.EvWaiting:      false,
		model.EvStop:         false,
		model.EvSessionEnd:   false,
		model.EvSessionStart: true,
	}
	for kind, want := range cases {
		ev := event(kind)
		ev.Cwd = "/w/api/app/Sources/MuDo"
		got, _ := Apply(session(model.StateRunning), ev, "devbox", t0.Add(time.Minute))
		changed := got.Cwd == ev.Cwd
		if changed != want {
			t.Errorf("%s: cwd=%q project=%q, want cwd changed=%v", kind, got.Cwd, got.Project, want)
		}
		if want && got.Project != "MuDo" {
			t.Errorf("%s: project=%q, want MuDo", kind, got.Project)
		}
		if !want && (got.Cwd != "/w/api" || got.Project != "api") {
			t.Errorf("%s: cwd=%q project=%q, want unchanged /w/api/api", kind, got.Cwd, got.Project)
		}
	}
}

func TestCwdFromProcCorrectsDriftedSession(t *testing.T) {
	prev := session(model.StateRunning)
	prev.Cwd, prev.Project = "/w/api/server", "server"
	ev := event(model.EvTool)
	ev.Cwd, ev.CwdFromProc = "/w/api", true
	got, changed := Apply(prev, ev, "devbox", t0.Add(time.Minute))
	if !changed || got.Cwd != "/w/api" || got.Project != "api" {
		t.Fatalf("cwd=%q project=%q changed=%v", got.Cwd, got.Project, changed)
	}
}

func TestEmptyCwdAdoptsFirstNonEmpty(t *testing.T) {
	prev := session(model.StateIdle)
	prev.Cwd, prev.Project = "", ""
	ev := event(model.EvPrompt)
	ev.Cwd = "/w/api"
	got, changed := Apply(prev, ev, "devbox", t0.Add(time.Minute))
	if !changed || got.Cwd != "/w/api" || got.Project != "api" {
		t.Fatalf("adopt: cwd=%q project=%q changed=%v", got.Cwd, got.Project, changed)
	}

	ev.Cwd = "/w/api/sub"
	got, _ = Apply(&got, ev, "devbox", t0.Add(2*time.Minute))
	if got.Cwd != "/w/api" {
		t.Fatalf("later drift: cwd=%q, want /w/api", got.Cwd)
	}
}

func TestTerminal(t *testing.T) {
	term := model.Terminal{Program: "iTerm.app", TTY: "/dev/ttys004"}
	withTerm := func(k model.EventKind, v model.Terminal) model.Event {
		ev := event(k)
		ev.Terminal = &v
		return ev
	}
	later := t0.Add(time.Minute)

	got, _ := Apply(nil, withTerm(model.EvSessionStart, term), "devbox", t0)
	if got.Terminal == nil || *got.Terminal != term {
		t.Fatalf("new session terminal = %+v", got.Terminal)
	}

	got, changed := Apply(session(model.StateRunning), withTerm(model.EvTool, term), "devbox", later)
	if !changed || got.Terminal == nil || *got.Terminal != term || !got.UpdatedAt.Equal(later) {
		t.Fatalf("first terminal: changed=%v terminal=%+v", changed, got.Terminal)
	}

	prev := session(model.StateRunning)
	same := term
	prev.Terminal = &same
	got, changed = Apply(prev, withTerm(model.EvTool, term), "devbox", later)
	if changed || *got.Terminal != term {
		t.Fatalf("equal terminal: changed=%v terminal=%+v", changed, got.Terminal)
	}

	other := model.Terminal{Program: "iTerm.app", TTY: "/dev/ttys005"}
	got, changed = Apply(prev, withTerm(model.EvTool, other), "devbox", later)
	if !changed || *got.Terminal != other || *prev.Terminal != term {
		t.Fatalf("new terminal: changed=%v terminal=%+v prev=%+v", changed, got.Terminal, prev.Terminal)
	}

	got, changed = Apply(prev, event(model.EvTool), "devbox", later)
	if changed || got.Terminal == nil || *got.Terminal != term {
		t.Fatalf("nil terminal: changed=%v terminal=%+v", changed, got.Terminal)
	}
}

// A hook that captured only part of the terminal keeps the rest of the stored one.
func TestTerminalMergesFieldByField(t *testing.T) {
	later := t0.Add(time.Minute)
	stored := model.Terminal{
		Program: "iTerm.app", TTY: "/dev/ttys004", ITermSession: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
		SSHClientIP: "100.64.0.20", SSHClientPort: 52000, SSHServerIP: "100.64.0.10", SSHServerPort: 22,
	}
	apply := func(v model.Terminal) (model.Terminal, bool) {
		prev := session(model.StateRunning)
		s := stored
		prev.Terminal = &s
		ev := event(model.EvTool)
		ev.Terminal = &v
		got, changed := Apply(prev, ev, "devbox", later)
		if *prev.Terminal != stored {
			t.Fatalf("prev mutated: %+v", prev.Terminal)
		}
		return *got.Terminal, changed
	}

	// TTY empty in the event: kept.
	got, changed := apply(model.Terminal{Program: "iTerm.app"})
	if changed || got != stored {
		t.Fatalf("empty tty: changed=%v terminal=%+v", changed, got)
	}

	// A new TTY replaces the stored one; the rest stays.
	got, changed = apply(model.Terminal{TTY: "/dev/ttys009"})
	want := stored
	want.TTY = "/dev/ttys009"
	if !changed || got != want {
		t.Fatalf("new tty: changed=%v terminal=%+v", changed, got)
	}

	// SSH fields empty in the event: kept, while new fields are added.
	got, changed = apply(model.Terminal{Program: "iTerm.app", TmuxPane: "%3", TmuxSocket: "/tmp/tmux-1000/default"})
	want = stored
	want.TmuxPane, want.TmuxSocket = "%3", "/tmp/tmux-1000/default"
	if !changed || got != want {
		t.Fatalf("ssh kept: changed=%v terminal=%+v", changed, got)
	}

	// New SSH fields replace the stored ones.
	got, _ = apply(model.Terminal{SSHClientIP: "100.64.0.21", SSHClientPort: 53000, SSHServerIP: "100.64.0.10", SSHServerPort: 22})
	if got.SSHClientIP != "100.64.0.21" || got.SSHClientPort != 53000 || got.TTY != stored.TTY {
		t.Fatalf("new ssh: terminal=%+v", got)
	}

	// CodeServer stays true once seen.
	got, changed = apply(model.Terminal{CodeServer: true})
	if !changed || !got.CodeServer {
		t.Fatalf("code server set: changed=%v terminal=%+v", changed, got)
	}

	// A Slack channel is added, and kept by an event that does not carry it.
	got, changed = apply(model.Terminal{SlackChannel: "C0123456789", SlackTeam: "T0123456789", SlackThread: "1700000000.000100"})
	if !changed || got.SlackChannel != "C0123456789" || got.SlackTeam != "T0123456789" || got.SlackThread != "1700000000.000100" || got.TTY != stored.TTY {
		t.Fatalf("slack channel: changed=%v terminal=%+v", changed, got)
	}
	stored.SlackChannel, stored.SlackTeam, stored.SlackThread = "C0123456789", "T0123456789", "1700000000.000100"
	got, _ = apply(model.Terminal{Program: "iTerm.app"})
	if got.SlackChannel != "C0123456789" || got.SlackTeam != "T0123456789" || got.SlackThread != "1700000000.000100" {
		t.Fatalf("slack channel kept: terminal=%+v", got)
	}
}

func TestSessionStartReplacesTerminal(t *testing.T) {
	prev := session(model.StateIdle)
	prev.Terminal = &model.Terminal{Program: "tmux", TmuxPane: "%3", TmuxSocket: "/tmp/tmux-1000/default", TTY: "/dev/ttys004"}
	ev := event(model.EvSessionStart)
	ev.Terminal = &model.Terminal{Program: "iTerm.app", TTY: "/dev/ttys009"}
	got, changed := Apply(prev, ev, "devbox", t0.Add(time.Minute))
	if !changed || *got.Terminal != *ev.Terminal {
		t.Fatalf("changed=%v terminal=%+v; want a fresh %+v", changed, got.Terminal, ev.Terminal)
	}
}

func TestLastOutput(t *testing.T) {
	ev := event(model.EvStop)
	ev.Output = "Pushed the fix"
	got, changed := Apply(session(model.StateRunning), ev, "devbox", t0)
	if !changed || got.LastOutput != "Pushed the fix" {
		t.Fatalf("stop: last_output=%q changed=%v", got.LastOutput, changed)
	}
	if _, changed := Apply(&got, ev, "devbox", t0.Add(time.Minute)); changed {
		t.Fatal("same output again must be a no-op")
	}
	got, _ = Apply(&got, event(model.EvPrompt), "devbox", t0)
	if got.LastOutput != "" {
		t.Fatalf("prompt kept last_output %q", got.LastOutput)
	}
}

func TestNotice(t *testing.T) {
	ev := event(model.EvWaiting)
	ev.Notice = "Claude needs your permission to use Bash"
	waiting, changed := Apply(session(model.StateRunning), ev, "devbox", t0)
	if !changed || waiting.Notice != ev.Notice {
		t.Fatalf("waiting: notice=%q changed=%v", waiting.Notice, changed)
	}
	for _, k := range []model.EventKind{model.EvTool, model.EvStop} {
		got, changed := Apply(&waiting, event(k), "devbox", t0)
		if !changed || got.State == model.StateWaiting || got.Notice != "" {
			t.Errorf("%s after waiting: state=%s notice=%q changed=%v", k, got.State, got.Notice, changed)
		}
	}
}

func TestNewSessionKeepsOutputAndNotice(t *testing.T) {
	ev := event(model.EvStop)
	ev.Output = "Done"
	if got, _ := Apply(nil, ev, "devbox", t0); got.LastOutput != "Done" {
		t.Fatalf("stop: last_output=%q", got.LastOutput)
	}
	ev = event(model.EvWaiting)
	ev.Notice = "Needs input"
	if got, _ := Apply(nil, ev, "devbox", t0); got.Notice != "Needs input" {
		t.Fatalf("waiting: notice=%q", got.Notice)
	}
}

func TestEndClearsNotice(t *testing.T) {
	s := session(model.StateWaiting)
	s.Notice = "Needs input"
	if got := End(*s, t0.Add(time.Minute)); got.Notice != "" {
		t.Fatalf("notice = %q", got.Notice)
	}
}
