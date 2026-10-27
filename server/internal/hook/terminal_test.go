package hook

import (
	"errors"
	"testing"

	"mudo/internal/model"
)

const iTermID = "6C1F8E8A-1B2C-4D3E-9F00-112233445566"

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestCaptureTerminal(t *testing.T) {
	ttyCalls := 0
	tty := func(v string) func(int) string {
		return func(pid int) string {
			ttyCalls++
			if pid != 300 {
				t.Errorf("TTY pid = %d, want 300", pid)
			}
			return v
		}
	}
	lookPath := func(string) (string, error) { return "/opt/homebrew/bin/tmux", nil }
	clientSSH := func(v string) func(bin, socket, pane string) string {
		return func(bin, socket, pane string) string {
			if bin != "/opt/homebrew/bin/tmux" || socket != "/tmp/tmux-1000/default" || pane != "%1" {
				t.Errorf("TmuxClientSSH(%q, %q, %q)", bin, socket, pane)
			}
			return v
		}
	}
	linuxTmux := map[string]string{
		"SSH_CONNECTION": "192.168.1.20 40000 192.168.1.10 22",
		"TMUX":           "/tmp/tmux-1000/default,999,0",
		"TMUX_PANE":      "%1",
	}
	cases := []struct {
		name  string
		env   map[string]string
		deps  TerminalDeps
		want  *model.Terminal
		noTTY bool // the TTY fake must not be called
	}{
		{"iterm", map[string]string{"TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:" + iTermID},
			TerminalDeps{GOOS: "darwin", TTY: tty("ttys004")},
			&model.Terminal{Program: "iTerm.app", ITermSession: iTermID, TTY: "/dev/ttys004"}, false},
		{"no tty", map[string]string{"TERM_PROGRAM": "Apple_Terminal"},
			TerminalDeps{GOOS: "darwin", TTY: tty("??")},
			&model.Terminal{Program: "Apple_Terminal"}, false},
		{"linux skips tty", map[string]string{"TERM_PROGRAM": "tmux"},
			TerminalDeps{GOOS: "linux", TTY: tty("pts/1")},
			&model.Terminal{Program: "tmux"}, true},
		{"code-server", map[string]string{"TERM_PROGRAM": "vscode", "VSCODE_PROXY_URI": "https://code.example.com/proxy/{{port}}"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{Program: "vscode", CodeServer: true}, true},
		{"tmux darwin", map[string]string{"TMUX": "/private/tmp/tmux-501/default,1234,0", "TMUX_PANE": "%3"},
			TerminalDeps{GOOS: "darwin", TTY: tty("ttys002"), LookPath: lookPath},
			&model.Terminal{TTY: "/dev/ttys002", TmuxSocket: "/private/tmp/tmux-501/default", TmuxPane: "%3",
				TmuxBin: "/opt/homebrew/bin/tmux"}, false},
		{"ssh", map[string]string{"SSH_CONNECTION": "fd7a:115c:a1e0::20 52144 fd7a:115c:a1e0::10 22"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SSHClientIP: "fd7a:115c:a1e0::20", SSHClientPort: 52144,
				SSHServerIP: "fd7a:115c:a1e0::10", SSHServerPort: 22}, true},
		{"ssh inside tmux", linuxTmux,
			TerminalDeps{GOOS: "linux", LookPath: lookPath, TmuxClientSSH: clientSSH("192.168.1.20 51000 192.168.1.10 22")},
			&model.Terminal{TmuxSocket: "/tmp/tmux-1000/default", TmuxPane: "%1",
				SSHClientIP: "192.168.1.20", SSHClientPort: 51000, SSHServerIP: "192.168.1.10", SSHServerPort: 22}, true},
		{"ssh inside tmux, client unknown", linuxTmux,
			TerminalDeps{GOOS: "linux", LookPath: lookPath, TmuxClientSSH: clientSSH("")},
			&model.Terminal{TmuxSocket: "/tmp/tmux-1000/default", TmuxPane: "%1"}, true},
		{"ssh inside tmux, no tmux binary", linuxTmux,
			TerminalDeps{GOOS: "linux", LookPath: func(string) (string, error) { return "", errors.New("not found") },
				TmuxClientSSH: clientSSH("192.168.1.20 51000 192.168.1.10 22")},
			&model.Terminal{TmuxSocket: "/tmp/tmux-1000/default", TmuxPane: "%1"}, true},
		{"slack channel", map[string]string{"KIROCREW_CHANNEL_ID": "C0123456789"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "C0123456789"}, true},
		{"slack channel and team", map[string]string{"KIROCREW_CHANNEL_ID": "C0123456789", "KIROCREW_SLACK_TEAM_ID": "T0123456789"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "C0123456789", SlackTeam: "T0123456789"}, true},
		{"bad slack team", map[string]string{"KIROCREW_CHANNEL_ID": "C0123456789", "KIROCREW_SLACK_TEAM_ID": "t01&x=1"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "C0123456789"}, true},
		{"slack thread from session key", map[string]string{"KIROCREW_CHANNEL_ID": "C0123456789", "KIROCREW_SESSION_KEY": "1700000000.000100"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "C0123456789", SlackThread: "1700000000.000100"}, true},
		{"slack thread from namespaced session key", map[string]string{"KIROCREW_CHANNEL_ID": "C0123456789", "KIROCREW_SESSION_KEY": "slack:1700000000.000100"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "C0123456789", SlackThread: "1700000000.000100"}, true},
		{"flat dm session key has no thread", map[string]string{"KIROCREW_CHANNEL_ID": "D0123456789", "KIROCREW_SESSION_KEY": "slack:D0123456789"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "D0123456789"}, true},
		{"bad session key", map[string]string{"KIROCREW_CHANNEL_ID": "C0123456789", "KIROCREW_SESSION_KEY": "1700000000.1&x=1"},
			TerminalDeps{GOOS: "linux"},
			&model.Terminal{SlackChannel: "C0123456789"}, true},
		{"session key without channel", map[string]string{"KIROCREW_SESSION_KEY": "1700000000.000100"},
			TerminalDeps{GOOS: "linux"}, nil, true},
		{"slack team without channel", map[string]string{"KIROCREW_SLACK_TEAM_ID": "T0123456789"},
			TerminalDeps{GOOS: "linux"}, nil, true},
		{"bad slack channel", map[string]string{"KIROCREW_CHANNEL_ID": "c0123; rm"},
			TerminalDeps{GOOS: "linux"}, nil, true},
		{"nothing known", map[string]string{},
			TerminalDeps{GOOS: "darwin", TTY: tty("??")}, nil, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ttyCalls = 0
			got := CaptureTerminal(envOf(c.env), c.deps, 300)
			if (got == nil) != (c.want == nil) || (got != nil && *got != *c.want) {
				t.Fatalf("got %+v, want %+v", got, c.want)
			}
			if c.noTTY && ttyCalls != 0 {
				t.Fatalf("TTY called %d times", ttyCalls)
			}
			if !c.noTTY && ttyCalls != 1 {
				t.Fatalf("TTY called %d times, want 1", ttyCalls)
			}
		})
	}
}

func TestParseSSHConnection(t *testing.T) {
	cip, cport, sip, sport, ok := parseSSHConnection("100.64.0.20 52144 100.64.0.10 22")
	if !ok || cip != "100.64.0.20" || cport != 52144 || sip != "100.64.0.10" || sport != 22 {
		t.Fatalf("got %q %d %q %d %v", cip, cport, sip, sport, ok)
	}
	for _, s := range []string{
		"",
		"100.64.0.20 52144 100.64.0.10",
		"100.64.0.20 x 100.64.0.10 22",
		"100.64.0.20 52144 100.64.0.10 ssh",
		"100.64.0.20 0 100.64.0.10 22",
		"100.64.0.20 52144 100.64.0.10 65536",
		"100.64.0.20 -1 100.64.0.10 22",
	} {
		if _, _, _, _, ok := parseSSHConnection(s); ok {
			t.Errorf("parseSSHConnection(%q) ok", s)
		}
	}
}
