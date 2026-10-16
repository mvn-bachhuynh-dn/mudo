// Package machine is the pure session state machine from spec section 4.2.
package machine

import (
	"errors"
	"path/filepath"
	"time"

	"mudo/internal/model"
)

var ErrNotDone = errors.New("session is not done")

// Apply folds one hook event into a session. prev is nil for a session the
// daemon has not seen yet. It reports whether the session changed.
func Apply(prev *model.Session, ev model.Event, host string, now time.Time) (model.Session, bool) {
	if prev == nil {
		return model.Session{
			ID: ev.SessionID, Agent: ev.Agent, Host: host,
			Cwd: ev.Cwd, Project: projectName(ev.Cwd),
			State: initialState(ev.Kind), StateSince: now,
			PID: ev.PID, PIDStart: ev.PIDStart,
			LastPrompt: ev.Prompt, UpdatedAt: now,
		}, true
	}

	s := *prev
	changed := false
	// Hook payloads report the agent's current directory, which drifts when
	// the agent cd's. Keep the session's cwd unless it is unknown, a fresh
	// session_start re-homes it, or the hook read it from the agent process.
	if ev.Cwd != "" && ev.Cwd != s.Cwd && (s.Cwd == "" || ev.Kind == model.EvSessionStart || ev.CwdFromProc) {
		s.Cwd, s.Project = ev.Cwd, projectName(ev.Cwd)
		changed = true
	}
	if ev.PID != 0 && (ev.PID != s.PID || ev.PIDStart != s.PIDStart) {
		s.PID, s.PIDStart = ev.PID, ev.PIDStart
		changed = true
	}
	if ev.Kind == model.EvPrompt && ev.Prompt != s.LastPrompt {
		s.LastPrompt = ev.Prompt
		changed = true
	}
	if next := transition(s.State, ev.Kind); next != s.State {
		s.State, s.StateSince = next, now
		changed = true
	}
	if changed {
		s.UpdatedAt = now
	}
	return s, changed
}

// Ack marks a done session as seen by the user.
func Ack(s model.Session, now time.Time) (model.Session, error) {
	if s.State != model.StateDone {
		return s, ErrNotDone
	}
	s.State, s.StateSince, s.UpdatedAt = model.StateIdle, now, now
	return s, nil
}

// End marks a session whose process is gone.
func End(s model.Session, now time.Time) model.Session {
	if s.State == model.StateEnded {
		return s
	}
	s.State, s.StateSince, s.UpdatedAt = model.StateEnded, now, now
	return s
}

func transition(from model.State, k model.EventKind) model.State {
	switch k {
	case model.EvSessionStart:
		return model.StateIdle
	case model.EvPrompt:
		return model.StateRunning
	case model.EvTool:
		if from == model.StateWaiting || from == model.StateIdle || from == model.StateDone {
			return model.StateRunning
		}
	case model.EvWaiting:
		if from == model.StateRunning {
			return model.StateWaiting
		}
	case model.EvStop:
		if from == model.StateRunning || from == model.StateWaiting {
			return model.StateDone
		}
	case model.EvSessionEnd:
		return model.StateEnded
	}
	return from
}

func initialState(k model.EventKind) model.State {
	switch k {
	case model.EvPrompt, model.EvTool:
		return model.StateRunning
	case model.EvWaiting:
		return model.StateWaiting
	case model.EvStop:
		return model.StateDone
	case model.EvSessionEnd:
		return model.StateEnded
	}
	return model.StateIdle
}

func projectName(cwd string) string {
	if cwd == "" {
		return ""
	}
	return filepath.Base(cwd)
}
