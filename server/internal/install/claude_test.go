package install

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC)

const cmd = "/home/steve/.local/bin/mudod hook --agent claude"

func readSettings(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestMergeClaudeSettingsPreservesExistingHooks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	existing := `{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := MergeClaudeSettings(path, cmd, t0)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	got := readSettings(t, path)
	if got["model"] != "opus" {
		t.Fatalf("model lost: %v", got["model"])
	}
	hooks := got["hooks"].(map[string]any)
	for _, ev := range ClaudeEvents {
		groups, _ := hooks[ev].([]any)
		if !containsCommand(groups, cmd) {
			t.Errorf("%s missing mudod hook", ev)
		}
	}
	if n := len(hooks["Stop"].([]any)); n != 2 {
		t.Errorf("Stop groups = %d, want 2", n)
	}
	note := hooks["Notification"].([]any)[0].(map[string]any)
	if note["matcher"] != "permission_prompt|elicitation_dialog" {
		t.Errorf("notification matcher = %v", note["matcher"])
	}
	backups, _ := filepath.Glob(path + ".mudo-bak-*")
	if len(backups) != 1 {
		t.Fatalf("backups = %v", backups)
	}

	changed, err = MergeClaudeSettings(path, cmd, t0.Add(time.Hour))
	if err != nil || changed {
		t.Fatalf("second merge changed=%v err=%v", changed, err)
	}
	if n := len(readSettings(t, path)["hooks"].(map[string]any)["Stop"].([]any)); n != 2 {
		t.Fatalf("second merge duplicated Stop: %d groups", n)
	}
}

func TestMergeClaudeSettingsCreatesMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude", "settings.json")
	if _, err := MergeClaudeSettings(path, cmd, t0); err != nil {
		t.Fatal(err)
	}
	if _, ok := readSettings(t, path)["hooks"]; !ok {
		t.Fatal("hooks not written")
	}
	if backups, _ := filepath.Glob(path + ".mudo-bak-*"); len(backups) != 0 {
		t.Fatalf("unexpected backup %v", backups)
	}
}

func TestRemoveClaudeHooksKeepsOthers(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	existing := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`
	if err := os.WriteFile(path, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := MergeClaudeSettings(path, cmd, t0); err != nil {
		t.Fatal(err)
	}
	changed, err := RemoveClaudeHooks(path, cmd)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	hooks := readSettings(t, path)["hooks"].(map[string]any)
	if len(hooks) != 1 {
		t.Fatalf("hooks left: %v", hooks)
	}
	stop := hooks["Stop"].([]any)
	if len(stop) != 1 || containsCommand(stop, cmd) || !containsCommand(stop, "say done") {
		t.Fatalf("Stop = %v", stop)
	}
}

func TestRemoveClaudeHooksMissingFile(t *testing.T) {
	changed, err := RemoveClaudeHooks(filepath.Join(t.TempDir(), "none.json"), cmd)
	if err != nil || changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
}

func TestKiroHooks(t *testing.T) {
	var got struct {
		Version string `json:"version"`
		Hooks   []struct {
			Name    string `json:"name"`
			Trigger string `json:"trigger"`
			Action  struct {
				Type    string `json:"type"`
				Command string `json:"command"`
			} `json:"action"`
			Timeout int  `json:"timeout"`
			Enabled bool `json:"enabled"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(KiroHooks("/x/mudod hook --agent kiro"), &got); err != nil {
		t.Fatal(err)
	}
	if got.Version != "v1" || len(got.Hooks) != 4 {
		t.Fatalf("got %+v", got)
	}
	triggers := []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"}
	for i, h := range got.Hooks {
		if h.Trigger != triggers[i] || h.Action.Type != "command" || h.Action.Command != "/x/mudod hook --agent kiro" || h.Timeout != 2 || !h.Enabled {
			t.Errorf("hook %d = %+v", i, h)
		}
	}
}
