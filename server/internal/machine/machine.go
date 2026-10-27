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
		s := model.Session{
			ID: ev.SessionID, Agent: ev.Agent, Host: host,
			Cwd: ev.Cwd, Project: ProjectName(ev.Cwd),
			State: initialState(ev.Kind), StateSince: now,
			PID: ev.PID, PIDStart: ev.PIDStart,
			LastPrompt: ev.Prompt, UpdatedAt: now,
			Terminal: ev.Terminal,
		}
		if ev.Kind == model.EvStop {
			s.LastOutput = ev.Output
		}
		if s.State == model.StateWaiting {
			s.Notice = ev.Notice
		}
		return s, true
	}

	s := *prev
	changed := false
	// Hook payloads report the agent's current directory, which drifts when
	// the agent cd's. Keep the session's cwd unless it is unknown, a fresh
	// session_start re-homes it, or the hook read it from the agent process.
	if ev.Cwd != "" && ev.Cwd != s.Cwd && (s.Cwd == "" || ev.Kind == model.EvSessionStart || ev.CwdFromProc) {
		s.Cwd, s.Project = ev.Cwd, ProjectName(ev.Cwd)
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
	// A hook that knows nothing about its terminal keeps the stored one; one
	// that knows part of it updates only the fields it captured.
	if ev.Terminal != nil {
		t := *ev.Terminal
		// A session_start (new or resumed agent process) describes the
		// terminal afresh; later events only fill in what they know.
		if s.Terminal != nil && ev.Kind != model.EvSessionStart {
			t = mergeTerminal(*s.Terminal, t)
		}
		if s.Terminal == nil || t != *s.Terminal {
			s.Terminal = &t
			changed = true
		}
	}
	if next := transition(s.State, ev.Kind); next != s.State {
		s.State, s.StateSince = next, now
		changed = true
	}
	// The reply belongs to the turn it ended: a new prompt clears it, so a
	// later Stop without output does not show the previous turn's reply.
	output := s.LastOutput
	if ev.Kind == model.EvPrompt {
		output = ""
	} else if ev.Kind == model.EvStop && ev.Output != "" {
		output = ev.Output
	}
	// The notice explains a wait and goes away with it.
	notice := s.Notice
	if s.State != model.StateWaiting {
		notice = ""
	} else if ev.Kind == model.EvWaiting && ev.Notice != "" {
		notice = ev.Notice
	}
	if output != s.LastOutput || notice != s.Notice {
		s.LastOutput, s.Notice = output, notice
		changed = true
	}
	if changed {
		s.UpdatedAt = now
	}
	return s, changed
}

// mergeTerminal overlays the non-empty fields of next on old. CodeServer
// stays true once seen.
func mergeTerminal(old, next model.Terminal) model.Terminal {
	str := func(o, n string) string {
		if n != "" {
			return n
		}
		return o
	}
	num := func(o, n int) int {
		if n != 0 {
			return n
		}
		return o
	}
	return model.Terminal{
		Program:       str(old.Program, next.Program),
		CodeServer:    old.CodeServer || next.CodeServer,
		TTY:           str(old.TTY, next.TTY),
		ITermSession:  str(old.ITermSession, next.ITermSession),
		TmuxSocket:    str(old.TmuxSocket, next.TmuxSocket),
		TmuxPane:      str(old.TmuxPane, next.TmuxPane),
		TmuxBin:       str(old.TmuxBin, next.TmuxBin),
		SSHClientIP:   str(old.SSHClientIP, next.SSHClientIP),
		SSHClientPort: num(old.SSHClientPort, next.SSHClientPort),
		SSHServerIP:   str(old.SSHServerIP, next.SSHServerIP),
		SSHServerPort: num(old.SSHServerPort, next.SSHServerPort),
		SlackChannel:  str(old.SlackChannel, next.SlackChannel),
		SlackTeam:     str(old.SlackTeam, next.SlackTeam),
		SlackThread:   str(old.SlackThread, next.SlackThread),
	}
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
	s.Notice = ""
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

// ProjectName derives a session's display name from its working directory.
func ProjectName(cwd string) string {
	if cwd == "" {
		return ""
	}
	return filepath.Base(cwd)
}
