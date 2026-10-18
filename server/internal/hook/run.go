package hook

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"mudo/internal/model"
	"mudo/internal/proc"
)

const (
	maxPayload = 1 << 20
	maxLogSize = 1 << 20
)

type Options struct {
	Agent     string
	Stdin     io.Reader
	IngestURL string
	LogPath   string
	Dump      bool
	Proc      proc.FS
	PPID      int
	Cwd       string // used when the payload has no cwd
	Client    *http.Client
	Env       func(string) string // nil: no terminal capture
	Terminal  TerminalDeps
	// CwdOnStartOnly reads the agent's cwd only on session_start (darwin,
	// where it costs an lsof); the daemon's sweep corrects drift later.
	CwdOnStartOnly bool
}

// Run handles one hook invocation. It never fails and never writes to
// stdout or stderr: Kiro adds hook stdout to the agent context and a
// non-zero exit blocks the prompt. Problems go to the log file.
func Run(o Options) {
	defer func() {
		if r := recover(); r != nil {
			logf(o.LogPath, "panic: %v", r)
		}
	}()
	payload, err := io.ReadAll(io.LimitReader(o.Stdin, maxPayload))
	if err != nil {
		logf(o.LogPath, "read stdin: %v", err)
		return
	}
	if o.Dump {
		logf(o.LogPath, "dump agent=%s payload=%s", o.Agent, payload)
	}
	ev, ok, err := Normalize(o.Agent, payload)
	if err != nil {
		logf(o.LogPath, "%v", err)
		return
	}
	if !ok {
		return
	}
	var found bool
	ev.PID, ev.PIDStart, found = o.Proc.FindAgent(o.PPID, o.Agent)
	// The payload cwd drifts with the agent's `cd`; the agent process's own
	// cwd is its launch directory. Trust it only for an agent found by name.
	if found && (!o.CwdOnStartOnly || ev.Kind == model.EvSessionStart) {
		if cwd, err := o.Proc.Cwd(ev.PID); err == nil && cwd != "" {
			ev.Cwd, ev.CwdFromProc = cwd, true
		}
	}
	if ev.Cwd == "" {
		ev.Cwd = o.Cwd
	}
	if o.Env != nil {
		ev.Terminal = CaptureTerminal(o.Env, o.Terminal, ev.PID)
	}
	if ev.SessionID == "" {
		ev.SessionID = fmt.Sprintf("%s-%d", o.Agent, ev.PID)
	}
	body, err := json.Marshal(ev)
	if err != nil {
		logf(o.LogPath, "encode event: %v", err)
		return
	}
	resp, err := o.Client.Post(o.IngestURL, "application/json", bytes.NewReader(body))
	if err != nil {
		logf(o.LogPath, "post event: %v", err)
		return
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		logf(o.LogPath, "post event: status %d", resp.StatusCode)
	}
}

func logf(path, format string, args ...any) {
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return
	}
	if fi, err := os.Stat(path); err == nil && fi.Size() > maxLogSize {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().UTC().Format(time.RFC3339), fmt.Sprintf(format, args...))
}
