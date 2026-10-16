package install

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"mudo/internal/config"
	"mudo/internal/paths"
)

type fakeExec struct {
	calls     []string
	tailscale error
}

func (f *fakeExec) run(name string, args ...string) (string, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	switch name {
	case "tailscale":
		if f.tailscale != nil {
			return "", f.tailscale
		}
		return "100.64.0.5\n", nil
	case "loginctl":
		return "Linger=no\n", nil
	}
	return "", nil
}

func options(t *testing.T, ex *fakeExec) Options {
	t.Helper()
	self := filepath.Join(t.TempDir(), "mudod")
	if err := os.WriteFile(self, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	return Options{Home: t.TempDir(), Self: self, Hostname: "devbox", User: "steve",
		Now: func() time.Time { return t0 }, Exec: ex.run}
}

func TestRunInstallsEverything(t *testing.T) {
	ex := &fakeExec{}
	o := options(t, ex)
	res, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	p := paths.For(o.Home)

	if data, err := os.ReadFile(p.Bin); err != nil || string(data) != "binary" {
		t.Fatalf("binary: %q %v", data, err)
	}
	cfg, err := config.Load(p.Config)
	if err != nil || cfg.APIAddr != "100.64.0.5:7879" || cfg.Host != "devbox" || len(cfg.Token) != 64 {
		t.Fatalf("config %+v %v", cfg, err)
	}
	if unit, _ := os.ReadFile(p.Unit); !strings.Contains(string(unit), "ExecStart="+p.Bin+" serve") {
		t.Fatalf("unit = %s", unit)
	}
	if s, _ := os.ReadFile(p.ClaudeSettings); !strings.Contains(string(s), p.Bin+" hook --agent claude") {
		t.Fatalf("claude settings = %s", s)
	}
	if k, _ := os.ReadFile(p.KiroHooks); !strings.Contains(string(k), p.Bin+" hook --agent kiro") {
		t.Fatalf("kiro hooks = %s", k)
	}
	want := "mudo://add?name=devbox&token=" + cfg.Token + "&url=http%3A%2F%2F100.64.0.5%3A7879"
	if res.ConnectURL != want {
		t.Fatalf("connect url = %s", res.ConnectURL)
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "sudo loginctl enable-linger steve") {
		t.Fatalf("warnings = %v", res.Warnings)
	}
	joined := strings.Join(ex.calls, "\n")
	for _, c := range []string{"systemctl --user daemon-reload", "systemctl --user enable mudod.service", "systemctl --user restart mudod.service"} {
		if !strings.Contains(joined, c) {
			t.Errorf("missing call %q in\n%s", c, joined)
		}
	}

	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	cfg2, _ := config.Load(p.Config)
	if cfg2.Token != cfg.Token {
		t.Fatal("re-running install must keep the token")
	}
}

func TestRunWithoutTailscaleBindsLocalhost(t *testing.T) {
	ex := &fakeExec{tailscale: errors.New("not found")}
	o := options(t, ex)
	res, err := Run(o)
	if err != nil {
		t.Fatal(err)
	}
	cfg, _ := config.Load(paths.For(o.Home).Config)
	if cfg.APIAddr != "127.0.0.1:7879" {
		t.Fatalf("api addr = %s", cfg.APIAddr)
	}
	if !strings.Contains(strings.Join(res.Warnings, "\n"), "api_addr") {
		t.Fatalf("warnings = %v", res.Warnings)
	}
}

func TestUninstall(t *testing.T) {
	ex := &fakeExec{}
	o := options(t, ex)
	if _, err := Run(o); err != nil {
		t.Fatal(err)
	}
	if err := Uninstall(o); err != nil {
		t.Fatal(err)
	}
	p := paths.For(o.Home)
	for _, f := range []string{p.Unit, p.KiroHooks} {
		if _, err := os.Stat(f); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s still exists", f)
		}
	}
	if s, _ := os.ReadFile(p.ClaudeSettings); strings.Contains(string(s), "mudod") {
		t.Errorf("claude settings still mention mudod: %s", s)
	}
	if _, err := os.Stat(p.Config); err != nil {
		t.Errorf("config must be kept: %v", err)
	}
	if !strings.Contains(strings.Join(ex.calls, "\n"), "systemctl --user disable --now mudod.service") {
		t.Errorf("calls = %v", ex.calls)
	}
}
