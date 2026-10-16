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
