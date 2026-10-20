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

func TestRunRecoversFromPanic(t *testing.T) {
	o := options(t, "http://127.0.0.1:1", `{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/w"}`)
	o.Client = nil
	Run(o)
	data, _ := os.ReadFile(o.LogPath)
	if !strings.Contains(string(data), "panic") {
		t.Fatalf("log = %q, want panic entry", data)
	}
}

func TestRunSkipsKiroCrewAgentsWithoutChannel(t *testing.T) {
	srv, got := capture(t)
	o := options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"bg"}`)
	o.Env = envOf(map[string]string{"KIROCREW_SPAWNED": "1"})
	Run(o)
	select {
	case ev := <-got:
		t.Fatalf("posted %+v for a channel-less KiroCrew agent", ev)
	case <-time.After(200 * time.Millisecond):
	}

	o = options(t, srv.URL, `{"hook_event_name":"Stop","session_id":"slack"}`)
	o.Env = envOf(map[string]string{"KIROCREW_SPAWNED": "1", "KIROCREW_CHANNEL_ID": "C0123456789"})
	Run(o)
	ev := next(t, got)
	if ev.Terminal == nil || ev.Terminal.SlackChannel != "C0123456789" {
		t.Fatalf("terminal = %+v, want slack channel C0123456789", ev.Terminal)
	}
}
