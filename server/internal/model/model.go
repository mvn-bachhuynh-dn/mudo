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
	CwdFromProc bool `json:"cwd_from_proc,omitempty"`
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
}
