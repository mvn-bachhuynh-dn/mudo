// Package install wires mudod into systemd, Claude Code and Kiro CLI.
package install

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// ClaudeEvents are the Claude Code hook events mudod listens to (spec 4.1).
var ClaudeEvents = []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"}

const notificationMatcher = "permission_prompt|elicitation_dialog"

// defaultSettingsMode is used when settings.json does not exist yet.
const defaultSettingsMode os.FileMode = 0o600

// MergeClaudeSettings adds a mudod hook for every event in ClaudeEvents,
// keeping existing hooks. It backs up an existing file before changing it
// and reports whether anything changed. Unexpected shapes are an error and
// the file is left untouched.
func MergeClaudeSettings(path, command string, now time.Time) (bool, error) {
	target, err := resolveTarget(path)
	if err != nil {
		return false, err
	}
	settings, mode, existed, err := loadSettings(target)
	if err != nil {
		return false, err
	}
	hooks, err := hooksObject(settings)
	if err != nil {
		return false, err
	}
	// Validate every event before changing anything.
	groupsByEvent := make(map[string][]any, len(ClaudeEvents))
	for _, ev := range ClaudeEvents {
		groups, err := eventGroups(hooks, ev)
		if err != nil {
			return false, err
		}
		groupsByEvent[ev] = groups
	}
	changed := false
	for _, ev := range ClaudeEvents {
		groups := groupsByEvent[ev]
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
		if err := backupSettings(target, mode, now); err != nil {
			return false, err
		}
	}
	return true, writeJSON(target, settings, mode)
}

// RemoveClaudeHooks deletes every hook handler running command. A group is
// dropped only when a mudod handler was removed from it and it is now empty;
// an event is dropped only when it was modified and is now empty. Anything
// else, including non-conforming values, is left as it is. A backup is
// written before the file changes.
func RemoveClaudeHooks(path, command string, now time.Time) (bool, error) {
	target, err := resolveTarget(path)
	if err != nil {
		return false, err
	}
	settings, mode, existed, err := loadSettings(target)
	if err != nil || !existed {
		return false, err
	}
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return false, nil
	}
	changed := false
	for ev, v := range hooks {
		groups, ok := v.([]any)
		if !ok {
			continue
		}
		var kept []any
		eventChanged := false
		for _, g := range groups {
			group, ok := g.(map[string]any)
			if !ok {
				kept = append(kept, g)
				continue
			}
			handlers, ok := group["hooks"].([]any)
			if !ok {
				kept = append(kept, g)
				continue
			}
			var rest []any
			removed := 0
			for _, h := range handlers {
				if m, ok := h.(map[string]any); ok && m["command"] == command {
					removed++
					continue
				}
				rest = append(rest, h)
			}
			if removed == 0 {
				kept = append(kept, g)
				continue
			}
			eventChanged = true
			if len(rest) == 0 {
				continue
			}
			group["hooks"] = rest
			kept = append(kept, group)
		}
		if !eventChanged {
			continue
		}
		changed = true
		if len(kept) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = kept
		}
	}
	if !changed {
		return false, nil
	}
	if err := backupSettings(target, mode, now); err != nil {
		return false, err
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
	return true, writeJSON(target, settings, mode)
}

// resolveTarget follows symlinks so that rewriting settings.json keeps the
// link. A dangling symlink is an error rather than a silent replacement.
func resolveTarget(path string) (string, error) {
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		return path, nil
	} else if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(path)
}

// loadSettings returns the parsed object, the file mode to keep (0600 for a
// new file), and whether the file existed. A literal null counts as {}.
func loadSettings(target string) (map[string]any, os.FileMode, bool, error) {
	fi, err := os.Stat(target)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{}, defaultSettingsMode, false, nil
	}
	if err != nil {
		return nil, 0, false, err
	}
	data, err := os.ReadFile(target)
	if err != nil {
		return nil, 0, false, err
	}
	settings := map[string]any{}
	if len(bytes.TrimSpace(data)) > 0 {
		var v any
		if err := json.Unmarshal(data, &v); err != nil {
			return nil, 0, true, fmt.Errorf("claude settings: %s: %w", target, err)
		}
		switch t := v.(type) {
		case nil:
			// literal null: treat as an empty object
		case map[string]any:
			settings = t
		default:
			return nil, 0, true, fmt.Errorf("claude settings: %s: top level must be an object", target)
		}
	}
	return settings, fi.Mode().Perm(), true, nil
}

// hooksObject returns the hooks object, or an empty one when it is absent or null.
func hooksObject(settings map[string]any) (map[string]any, error) {
	v, ok := settings["hooks"]
	if !ok || v == nil {
		return map[string]any{}, nil
	}
	h, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New(`claude settings: "hooks" must be an object`)
	}
	return h, nil
}

// eventGroups returns the group array for ev, or an error if it is not an array.
func eventGroups(hooks map[string]any, ev string) ([]any, error) {
	v, ok := hooks[ev]
	if !ok || v == nil {
		return nil, nil
	}
	groups, ok := v.([]any)
	if !ok {
		return nil, fmt.Errorf("claude settings: hooks.%s must be an array", ev)
	}
	return groups, nil
}

func backupSettings(target string, mode os.FileMode, now time.Time) error {
	return copyFile(target, target+".mudo-bak-"+now.Format("20060102-150405"), mode)
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

func writeJSON(path string, v any, perm os.FileMode) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return err
	}
	return writeFile(path, buf.Bytes(), perm)
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
