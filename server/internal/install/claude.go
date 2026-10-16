// Package install wires mudod into systemd, Claude Code and Kiro CLI.
package install

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// ClaudeEvents are the Claude Code hook events mudod listens to (spec 4.1).
var ClaudeEvents = []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"}

const notificationMatcher = "permission_prompt|elicitation_dialog"

// MergeClaudeSettings adds a mudod hook for every event in ClaudeEvents,
// keeping existing hooks. It backs up an existing file before changing it
// and reports whether anything changed.
func MergeClaudeSettings(path, command string, now time.Time) (bool, error) {
	settings, existed, err := readJSONObject(path)
	if err != nil {
		return false, err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	for _, ev := range ClaudeEvents {
		groups, _ := hooks[ev].([]any)
		if containsCommand(groups, command) {
			continue
		}
		group := map[string]any{"hooks": []any{map[string]any{"type": "command", "command": command}}}
		if ev == "Notification" {
			group["matcher"] = notificationMatcher
		}
		hooks[ev] = append(groups, group)
		changed = true
	}
	if !changed {
		return false, nil
	}
	settings["hooks"] = hooks
	if existed {
		if err := copyFile(path, path+".mudo-bak-"+now.Format("20060102-150405"), 0o644); err != nil {
			return false, err
		}
	}
	return true, writeJSON(path, settings)
}

// RemoveClaudeHooks deletes every hook handler running command, dropping
// groups and events left empty.
func RemoveClaudeHooks(path, command string) (bool, error) {
	settings, existed, err := readJSONObject(path)
	if err != nil || !existed {
		return false, err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	changed := false
	for ev, v := range hooks {
		groups, _ := v.([]any)
		var kept []any
		for _, g := range groups {
			group, ok := g.(map[string]any)
			if !ok {
				kept = append(kept, g)
				continue
			}
			handlers, _ := group["hooks"].([]any)
			var rest []any
			for _, h := range handlers {
				if m, ok := h.(map[string]any); ok && m["command"] == command {
					changed = true
					continue
				}
				rest = append(rest, h)
			}
			if len(rest) == 0 {
				continue
			}
			group["hooks"] = rest
			kept = append(kept, group)
		}
		if len(kept) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = kept
		}
	}
	if !changed {
		return false, nil
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
	return true, writeJSON(path, settings)
}

func containsCommand(groups []any, command string) bool {
	for _, g := range groups {
		group, _ := g.(map[string]any)
		handlers, _ := group["hooks"].([]any)
		for _, h := range handlers {
			if m, ok := h.(map[string]any); ok && m["command"] == command {
				return true
			}
		}
	}
	return false
}

func readJSONObject(path string) (map[string]any, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{}, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	m := map[string]any{}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, true, err
		}
	}
	return m, true, nil
}

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(path, append(data, '\n'), 0o644)
}

// writeFile replaces path atomically, creating parent directories.
func writeFile(path string, data []byte, perm os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	if err := os.Chmod(tmp, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func copyFile(src, dst string, perm os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return writeFile(dst, data, perm)
}
