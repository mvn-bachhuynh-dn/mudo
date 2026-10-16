// Package paths lists every file mudod reads or writes, relative to $HOME.
package paths

import "path/filepath"

type Paths struct {
	Home           string
	Config         string
	State          string
	HookLog        string
	Bin            string
	Unit           string
	ClaudeSettings string
	KiroHooks      string
}

func For(home string) Paths {
	return Paths{
		Home:           home,
		Config:         filepath.Join(home, ".config", "mudo", "config.toml"),
		State:          filepath.Join(home, ".local", "state", "mudo", "state.json"),
		HookLog:        filepath.Join(home, ".local", "state", "mudo", "hook.log"),
		Bin:            filepath.Join(home, ".local", "bin", "mudod"),
		Unit:           filepath.Join(home, ".config", "systemd", "user", "mudod.service"),
		ClaudeSettings: filepath.Join(home, ".claude", "settings.json"),
		KiroHooks:      filepath.Join(home, ".kiro", "hooks", "mudo.json"),
	}
}
