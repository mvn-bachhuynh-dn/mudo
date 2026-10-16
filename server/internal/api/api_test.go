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
