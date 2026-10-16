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
