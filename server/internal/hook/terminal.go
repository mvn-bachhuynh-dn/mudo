package hook

import (
	"regexp"
	"strconv"
	"strings"

	"mudo/internal/model"
)

// TerminalDeps are the side effects of CaptureTerminal, injected for tests.
type TerminalDeps struct {
	GOOS     string
	TTY      func(pid int) string // `ps -o tty=` for pid, e.g. ttys004 or ??
	LookPath func(string) (string, error)
	// TmuxClientSSH returns SSH_CONNECTION of the most recently active
	// client attached to pane's session, or "" (Linux).
	TmuxClientSSH func(bin, socket, pane string) string
}

// CaptureTerminal describes the terminal the agent runs in from the hook's
// environment. It returns nil when nothing is known.
func CaptureTerminal(env func(string) string, d TerminalDeps, agentPID int) *model.Terminal {
	t := model.Terminal{
		Program:    env("TERM_PROGRAM"),
		CodeServer: env("VSCODE_PROXY_URI") != "",
		TmuxPane:   env("TMUX_PANE"),
	}
	if id := env("ITERM_SESSION_ID"); id != "" {
		t.ITermSession = id[strings.LastIndex(id, ":")+1:]
	}
	if ch := env("KIROCREW_CHANNEL_ID"); validSlackChannel(ch) {
		t.SlackChannel = ch
		if team := env("KIROCREW_SLACK_TEAM_ID"); validSlackTeam(team) {
			t.SlackTeam = team
		}
		t.SlackThread = slackThread(env("KIROCREW_SESSION_KEY"))
	}
	tmux := env("TMUX")
	if tmux != "" {
		t.TmuxSocket, _, _ = strings.Cut(tmux, ",")
	}
	if d.GOOS == "darwin" {
		if d.TTY != nil && agentPID > 0 {
			if tty := strings.TrimSpace(d.TTY(agentPID)); tty != "" && tty != "??" {
				t.TTY = "/dev/" + tty
			}
		}
		if tmux != "" && d.LookPath != nil {
			t.TmuxBin, _ = d.LookPath("tmux")
		}
	}
	conn := env("SSH_CONNECTION")
	// Inside tmux on a server, SSH_CONNECTION is the one from when the tmux
	// server started; ask tmux which client is attached now.
	if tmux != "" && d.GOOS == "linux" {
		conn = ""
		if d.LookPath != nil && d.TmuxClientSSH != nil {
			if bin, err := d.LookPath("tmux"); err == nil {
				conn = d.TmuxClientSSH(bin, t.TmuxSocket, t.TmuxPane)
			}
		}
	}
	if cip, cport, sip, sport, ok := parseSSHConnection(conn); ok {
		t.SSHClientIP, t.SSHClientPort, t.SSHServerIP, t.SSHServerPort = cip, cport, sip, sport
	}
	if t == (model.Terminal{}) {
		return nil
	}
	return &t
}

// parseSSHConnection splits SSH_CONNECTION: "clientIP clientPort serverIP serverPort".
func parseSSHConnection(s string) (clientIP string, clientPort int, serverIP string, serverPort int, ok bool) {
	f := strings.Fields(s)
	if len(f) != 4 {
		return "", 0, "", 0, false
	}
	cport, err1 := strconv.Atoi(f[1])
	sport, err2 := strconv.Atoi(f[3])
	if err1 != nil || err2 != nil || !validPort(cport) || !validPort(sport) {
		return "", 0, "", 0, false
	}
	return f[0], cport, f[2], sport, true
}

func validPort(p int) bool { return p >= 1 && p <= 65535 }

var slackChannelRE = regexp.MustCompile(`^[CDG][A-Z0-9]{6,20}$`)

// validSlackChannel accepts a Slack channel ID (public, DM or group).
func validSlackChannel(s string) bool { return slackChannelRE.MatchString(s) }

var slackTeamRE = regexp.MustCompile(`^[TE][A-Z0-9]{6,20}$`)

// validSlackTeam accepts a Slack workspace (T) or Enterprise Grid org (E) ID.
func validSlackTeam(s string) bool { return slackTeamRE.MatchString(s) }

var slackTSRE = regexp.MustCompile(`^[0-9]{1,20}\.[0-9]{1,20}$`)

// slackThread returns the thread ts in a KiroCrew Slack session key (the bare
// thread ts or "slack:<thread ts>"), else "" (e.g. a flat DM "slack:<channel>").
func slackThread(key string) string {
	ts := strings.TrimPrefix(key, "slack:")
	if !slackTSRE.MatchString(ts) {
		return ""
	}
	return ts
}
