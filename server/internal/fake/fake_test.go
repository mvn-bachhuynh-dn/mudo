package fake

import (
	"context"
	"encoding/json"
	"strings"
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

func TestCswapListAndSwitch(t *testing.T) {
	run := Cswap()
	ctx := context.Background()
	active := func() int {
		out, err := run(ctx, "list", "--json")
		if err != nil {
			t.Fatal(err)
		}
		var v struct {
			Active   int `json:"activeAccountNumber"`
			Accounts []struct {
				Number int  `json:"number"`
				Active bool `json:"active"`
			} `json:"accounts"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			t.Fatal(err)
		}
		marked := 0
		for _, a := range v.Accounts {
			if a.Active {
				marked++
				if a.Number != v.Active {
					t.Fatalf("account %d marked active, activeAccountNumber is %d", a.Number, v.Active)
				}
			}
		}
		if marked != 1 {
			t.Fatalf("%d accounts marked active, want 1", marked)
		}
		return v.Active
	}
	if got := active(); got != 1 {
		t.Fatalf("initial active %d, want 1", got)
	}
	if _, err := run(ctx, "switch", "2"); err != nil {
		t.Fatal(err)
	}
	if got := active(); got != 2 {
		t.Fatalf("active after switch %d, want 2", got)
	}
	if _, err := run(ctx, "switch", "4"); err == nil {
		t.Fatal("switching to an account that needs a new login should fail")
	}
	if _, err := run(ctx, "switch", "99"); err == nil {
		t.Fatal("switching to an unknown account should fail")
	}
	if got := active(); got != 2 {
		t.Fatalf("failed switches changed the active account to %d", got)
	}
}

func TestCswapUsesPlaceholdersOnly(t *testing.T) {
	out, err := Cswap()(context.Background(), "list", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Accounts []struct {
			Email string `json:"email"`
		} `json:"accounts"`
	}
	if err := json.Unmarshal(out, &v); err != nil {
		t.Fatal(err)
	}
	for _, a := range v.Accounts {
		if !strings.HasSuffix(a.Email, "@example.com") && !strings.HasSuffix(a.Email, "@token.local") {
			t.Errorf("fake account %q is not a placeholder address", a.Email)
		}
	}
}
