// Package model holds the types shared by the hook, the daemon and the API.
package model

import "time"

type State string

const (
	StateIdle    State = "idle"
	StateRunning State = "running"
	StateWaiting State = "waiting"
	StateDone    State = "done"
	StateEnded   State = "ended"
)

type EventKind string

const (
	EvSessionStart EventKind = "session_start"
	EvPrompt       EventKind = "prompt"
	EvTool         EventKind = "tool"
	EvWaiting      EventKind = "waiting"
	EvStop         EventKind = "stop"
	EvSessionEnd   EventKind = "session_end"
)

// Event is one normalized hook invocation, sent from `mudod hook` to the daemon.
type Event struct {
	Agent     string    `json:"agent"`
	SessionID string    `json:"session_id"`
	Cwd       string    `json:"cwd"`
	Kind      EventKind `json:"event"`
	Prompt    string    `json:"prompt,omitempty"`
	PID       int       `json:"pid"`
	PIDStart  uint64    `json:"pid_start"`
	// CwdFromProc marks Cwd as read from the agent process (/proc/<pid>/cwd):
	// the launch directory, immune to the agent cd-ing around.
	CwdFromProc bool      `json:"cwd_from_proc,omitempty"`
	Terminal    *Terminal `json:"terminal,omitempty"`
}

// Session is the daemon's view of one agent session.
type Session struct {
	ID         string    `json:"id"`
	Agent      string    `json:"agent"`
	Host       string    `json:"host"`
	Cwd        string    `json:"cwd"`
	Project    string    `json:"project"`
	State      State     `json:"state"`
	StateSince time.Time `json:"state_since"`
	PID        int       `json:"pid"`
	PIDStart   uint64    `json:"pid_start"`
	LastPrompt string    `json:"last_prompt"`
	UpdatedAt  time.Time `json:"updated_at"`
	Terminal   *Terminal `json:"terminal,omitempty"`
}

// Terminal records where the agent runs, as seen by its hook.
type Terminal struct {
	Program       string `json:"program,omitempty"`         // TERM_PROGRAM: iTerm.app, Apple_Terminal, ghostty, vscode, tmux
	CodeServer    bool   `json:"code_server,omitempty"`     // VSCODE_PROXY_URI is set (code-server terminal)
	TTY           string `json:"tty,omitempty"`             // agent's controlling tty, e.g. /dev/ttys004 (darwin only)
	ITermSession  string `json:"iterm_session,omitempty"`   // ITERM_SESSION_ID, part after ':' (the unique id)
	TmuxSocket    string `json:"tmux_socket,omitempty"`     // first field of TMUX
	TmuxPane      string `json:"tmux_pane,omitempty"`       // TMUX_PANE, e.g. %3
	TmuxBin       string `json:"tmux_bin,omitempty"`        // exec.LookPath("tmux") in the agent's env (darwin only)
	SSHClientIP   string `json:"ssh_client_ip,omitempty"`   // SSH_CONNECTION field 1
	SSHClientPort int    `json:"ssh_client_port,omitempty"` // field 2
	SSHServerIP   string `json:"ssh_server_ip,omitempty"`   // field 3
	SSHServerPort int    `json:"ssh_server_port,omitempty"` // field 4
	SlackChannel  string `json:"slack_channel,omitempty"`   // KIROCREW_CHANNEL_ID: Slack channel of a KiroCrew session
	SlackTeam     string `json:"slack_team,omitempty"`      // KIROCREW_SLACK_TEAM_ID: its Slack workspace
}
