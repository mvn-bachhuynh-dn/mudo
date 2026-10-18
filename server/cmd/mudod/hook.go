package main

import (
	"context"
	"flag"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	"mudo/internal/config"
	"mudo/internal/hook"
	"mudo/internal/proc"
)

// runHook never prints and never fails; see hook.Run.
func runHook(args []string) {
	fs := flag.NewFlagSet("hook", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	agent := fs.String("agent", "claude", "claude or kiro")
	ingest := fs.String("ingest", "http://"+config.DefaultIngestAddr+"/event", "daemon ingest URL")
	if err := fs.Parse(args); err != nil {
		return
	}
	p, err := homePaths()
	if err != nil {
		return
	}
	cwd, _ := os.Getwd()
	hook.Run(hook.Options{
		Agent:     *agent,
		Stdin:     os.Stdin,
		IngestURL: *ingest,
		LogPath:   p.HookLog,
		Dump:      os.Getenv("MUDO_HOOK_DUMP") == "1",
		Proc:      proc.FS{Root: "/proc"},
		PPID:      os.Getppid(),
		Cwd:       cwd,
		Client:    &http.Client{Timeout: 500 * time.Millisecond},
		Env:       os.Getenv,
		Terminal: hook.TerminalDeps{
			GOOS:          runtime.GOOS,
			TTY:           psTTY,
			LookPath:      exec.LookPath,
			TmuxClientSSH: tmuxClientSSH,
		},
		CwdOnStartOnly: runtime.GOOS == "darwin",
	})
}

// hookCmdTimeout bounds each helper command so a wedged tmux or ps cannot
// stall the agent.
const hookCmdTimeout = 500 * time.Millisecond

func output(name string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), hookCmdTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func psTTY(pid int) string {
	return output("/bin/ps", "-o", "tty=", "-p", strconv.Itoa(pid))
}

// tmuxClientSSH returns SSH_CONNECTION of the most recently active client
// attached to pane's session, read from /proc/<client>/environ (Linux).
func tmuxClientSSH(bin, socket, pane string) string {
	session := output(bin, "-S", socket, "display", "-p", "-t", pane, "#{session_name}")
	if session == "" {
		return ""
	}
	clients := output(bin, "-S", socket, "list-clients", "-t", session, "-F", "#{client_activity} #{client_pid}")
	pid := hook.PickClientPID(clients)
	if pid == "" {
		return ""
	}
	env, err := os.ReadFile("/proc/" + pid + "/environ")
	if err != nil {
		return ""
	}
	return hook.SSHFromEnviron(env)
}
