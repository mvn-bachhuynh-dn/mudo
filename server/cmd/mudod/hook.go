package main

import (
	"flag"
	"io"
	"net/http"
	"os"
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
	})
}
