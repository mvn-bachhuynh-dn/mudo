package install

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"mudo/internal/config"
	"mudo/internal/paths"
)

func darwinOptions(t *testing.T, ex *fakeExec) Options {
	t.Helper()
	o := options(t, ex)
	o.GOOS, o.UID = "darwin", 501
	o.Sleep = func(time.Duration) {}
	return o
}

func TestLaunchAgentPlist(t *testing.T) {
	got := LaunchAgentPlist("/Users/a&b/bin/mudod", "/Users/a&b/Library/Logs/mudod.log")
	for _, want := range []string{"a&amp;b", "<string>serve</string>", "<key>KeepAlive</key>", "<true/>", "dev.mudo.mudod"} {
		if !strings.Contains(got, want) {
			t.Errorf("plist lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "a&b") {
		t.Errorf("unescaped path in plist:\n%s", got)
	}
}

func TestRunDarwinInstallsLaunchAgent(t *testing.T) {
	ex := &fakeExec{}
	o := darwinOptions(t, ex)
	res, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	p := paths.For(o.Home)

	info, err := os.Stat(p.LaunchAgent)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Errorf("plist mode = %v", info.Mode().Perm())
	}
	if data, _ := os.ReadFile(p.LaunchAgent); string(data) != LaunchAgentPlist(p.Bin, p.LaunchLog) {
		t.Errorf("plist = %s", data)
	}
	want := []string{"launchctl bootout gui/501/dev.mudo.mudod", "launchctl bootstrap gui/501 " + p.LaunchAgent}
	if strings.Join(ex.calls, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls = %q, want %q", ex.calls, want)
	}
	cfg, err := config.Load(p.Config)
	if err != nil || cfg.APIAddr != "127.0.0.1:7879" {
		t.Fatalf("config %+v %v", cfg, err)
	}
	if got := linkURL(t, res); got != "http://127.0.0.1:7879" {
		t.Errorf("url = %s", got)
	}
	if !strings.Contains(res.ConnectURL, "name=This+Mac") {
		t.Errorf("connect url = %s", res.ConnectURL)
	}
	if len(res.Warnings) != 0 {
		t.Errorf("warnings = %v", res.Warnings)
	}
	if s, _ := os.ReadFile(p.ClaudeSettings); !strings.Contains(string(s), p.Bin+" hook --agent claude") {
		t.Errorf("claude settings = %s", s)
	}
	if k, _ := os.ReadFile(p.KiroHooks); !strings.Contains(string(k), p.Bin+" hook --agent kiro") {
		t.Errorf("kiro hooks = %s", k)
	}
	if _, err := os.Stat(p.Unit); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("systemd unit written on darwin: %v", err)
	}
}

func TestRunDarwinRetriesBootstrap(t *testing.T) {
	ex := &fakeExec{bootstrapFails: 2}
	var slept []time.Duration
	o := darwinOptions(t, ex)
	o.Sleep = func(d time.Duration) { slept = append(slept, d) }
	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	if n := countCalls(ex, "launchctl bootstrap"); n != 3 {
		t.Errorf("%d bootstrap calls, want 3: %q", n, ex.calls)
	}
	if len(slept) != 2 {
		t.Errorf("slept %v", slept)
	}

	ex = &fakeExec{bootstrapFails: 5}
	_, err := Run(darwinOptions(t, ex))
	if err == nil || !strings.Contains(err.Error(), "launchctl bootstrap") || !strings.Contains(err.Error(), "Input/output error") {
		t.Fatalf("err = %v", err)
	}
	if n := countCalls(ex, "launchctl bootstrap"); n != 5 {
		t.Errorf("%d bootstrap calls, want 5", n)
	}
}

func TestRunDarwinWarnsOnNonLoopbackAPIAddr(t *testing.T) {
	ex := &fakeExec{v6: "fd7a:115c:a1e0::10"}
	o := darwinOptions(t, ex)
	p := paths.For(o.Home)
	cfg := config.Config{Token: "tok", Host: "devbox", IngestAddr: config.DefaultIngestAddr, APIAddr: "[::]:7879"}
	if err := cfg.Write(p.Config); err != nil {
		t.Fatal(err)
	}
	res, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	if got := linkURL(t, res); got != "http://127.0.0.1:7879" {
		t.Errorf("url = %s", got)
	}
	if w := strings.Join(res.Warnings, "\n"); !strings.Contains(w, "api_addr") || !strings.Contains(w, "loopback") {
		t.Errorf("warnings = %v", res.Warnings)
	}
	if n := countCalls(ex, "tailscale"); n != 0 {
		t.Errorf("tailscale called on darwin: %q", ex.calls)
	}
}

func TestUninstallDarwin(t *testing.T) {
	ex := &fakeExec{}
	o := darwinOptions(t, ex)
	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	ex.calls = nil
	if err := Uninstall(o); err != nil {
		t.Fatal(err)
	}
	p := paths.For(o.Home)
	for _, f := range []string{p.LaunchAgent, p.KiroHooks} {
		if _, err := os.Stat(f); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s still exists", f)
		}
	}
	if s, _ := os.ReadFile(p.ClaudeSettings); strings.Contains(string(s), "mudod") {
		t.Errorf("claude settings still mention mudod: %s", s)
	}
	if countCalls(ex, "launchctl bootout gui/501/dev.mudo.mudod") != 1 || countCalls(ex, "systemctl") != 0 {
		t.Errorf("calls = %q", ex.calls)
	}
}

func countCalls(ex *fakeExec, prefix string) int {
	n := 0
	for _, c := range ex.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}
