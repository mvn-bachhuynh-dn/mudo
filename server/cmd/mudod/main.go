// Command mudod tracks Claude Code and Kiro CLI sessions for the MuDo Mac app.
package main

import (
	"fmt"
	"os"

	"mudo/internal/paths"
)

var version = "0.1.0"

const usage = `usage: mudod <command>

commands:
  hook --agent claude|kiro   called by agent hooks (reads JSON on stdin)
  serve                      run the daemon
  install                    set up daemon, hooks and systemd unit
  uninstall                  remove daemon unit and hooks
  fake                       serve scripted fake sessions for UI work
  version                    print version`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "hook":
		runHook(os.Args[2:])
		os.Exit(0)
	case "serve":
		err = runServe(os.Args[2:])
	case "install":
		err = runInstall(os.Args[2:])
	case "uninstall":
		err = runUninstall(os.Args[2:])
	case "fake":
		err = runFake(os.Args[2:])
	case "version":
		fmt.Println(version)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "mudod:", err)
		os.Exit(1)
	}
}

func homePaths() (paths.Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return paths.Paths{}, err
	}
	return paths.For(home), nil
}
