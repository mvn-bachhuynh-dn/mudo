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
