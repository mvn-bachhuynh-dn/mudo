//go:build linux

package hook

// These tests resolve the agent through a fake /proc (proc.FS.Root), which only
// the Linux backend reads; on darwin FS queries the real kernel.

import (
	"testing"

	"mudo/internal/model"
	"mudo/internal/proc"
)

func TestRunPostsNormalizedEvent(t *testing.T) {
	srv, got := capture(t)
	Run(options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"abc","cwd":"/w/api"}`))
	want := model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w/api", Kind: model.EvStop, PID: 300, PIDStart: 555}
	if ev := next(t, got); ev != want {
		t.Fatalf("got %+v, want %+v", ev, want)
	}
}

func TestRunTakesCwdFromAgentProcess(t *testing.T) {
	srv, got := capture(t)
	o := options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"abc","cwd":"/w/api/drifted"}`)
	if err := proc.WriteFakeCwd(o.Proc.Root, 300, "/w/api"); err != nil {
		t.Fatal(err)
	}
	Run(o)
	ev := next(t, got)
	if ev.Cwd != "/w/api" || !ev.CwdFromProc {
		t.Fatalf("got %+v", ev)
	}
}

func TestRunKeepsPayloadCwdWhenAgentNotFound(t *testing.T) {
	srv, got := capture(t)
	o := options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"abc","cwd":"/w/api/drifted"}`)
	o.Agent = "kiro" // no kiro process in the tree: falls back to the parent
	if err := proc.WriteFakeCwd(o.Proc.Root, 400, "/should/not/be/used"); err != nil {
		t.Fatal(err)
	}
	Run(o)
	ev := next(t, got)
	if ev.Cwd == "/should/not/be/used" || ev.CwdFromProc {
		t.Fatalf("got %+v", ev)
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

func TestRunSendsTerminal(t *testing.T) {
	srv, got := capture(t)
	o := options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"abc"}`)
	o.Env = envOf(map[string]string{"TERM_PROGRAM": "iTerm.app", "TMUX_PANE": "%3"})
	o.Terminal = TerminalDeps{GOOS: "darwin", TTY: func(pid int) string {
		if pid != 300 {
			t.Errorf("TTY pid = %d, want 300", pid)
		}
		return "ttys004"
	}}
	Run(o)
	ev := next(t, got)
	want := model.Terminal{Program: "iTerm.app", TmuxPane: "%3", TTY: "/dev/ttys004"}
	if ev.Terminal == nil || *ev.Terminal != want {
		t.Fatalf("terminal = %+v, want %+v", ev.Terminal, want)
	}
}

func TestRunCwdOnStartOnly(t *testing.T) {
	for _, c := range []struct {
		payload  string
		fromProc bool
	}{
		{`{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/w/api/drifted"}`, false},
		{`{"hook_event_name":"SessionStart","session_id":"abc","cwd":"/w/api/drifted"}`, true},
	} {
		srv, got := capture(t)
		o := options(t, srv.URL, c.payload)
		o.CwdOnStartOnly = true
		if err := proc.WriteFakeCwd(o.Proc.Root, 300, "/w/api"); err != nil {
			t.Fatal(err)
		}
		Run(o)
		ev := next(t, got)
		if ev.CwdFromProc != c.fromProc || (ev.Cwd == "/w/api") != c.fromProc {
			t.Errorf("%s: got %+v", ev.Kind, ev)
		}
	}
}
