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

func TestLoadQuarantinesCorruptState(t *testing.T) {
	for name, content := range map[string]string{"empty": "", "garbage": "{garbage"} {
		t.Run(name, func(t *testing.T) {
			s := newStore(t, &clock{now: t0}, nil)
			if err := os.WriteFile(s.opts.Path, []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := s.Load(); err != nil {
				t.Fatalf("Load = %v, want nil", err)
			}
			if n := len(s.Snapshot()); n != 0 {
				t.Fatalf("snapshot has %d sessions", n)
			}
			m, _ := filepath.Glob(s.opts.Path + ".corrupt-*")
			if len(m) != 1 {
				t.Fatalf("corrupt files = %v", m)
			}
		})
	}
}
