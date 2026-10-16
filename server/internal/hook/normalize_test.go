package hook

import (
	"strings"
	"testing"

	"mudo/internal/model"
)

func TestNormalize(t *testing.T) {
	cases := []struct {
		name    string
		agent   string
		payload string
		want    model.Event
		ok      bool
	}{
		{"claude stop", "claude",
			`{"hook_event_name":"Stop","session_id":"abc","cwd":"/w/api"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w/api", Kind: model.EvStop}, true},
		{"claude prompt", "claude",
			`{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/w/api","prompt":"fix  the\nbug"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w/api", Kind: model.EvPrompt, Prompt: "fix the bug"}, true},
		{"claude permission prompt", "claude",
			`{"hook_event_name":"Notification","session_id":"abc","cwd":"/w","notification_type":"permission_prompt"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvWaiting}, true},
		{"claude elicitation", "claude",
			`{"hook_event_name":"Notification","session_id":"abc","cwd":"/w","notification_type":"elicitation_dialog"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvWaiting}, true},
		{"claude idle notification ignored", "claude",
			`{"hook_event_name":"Notification","session_id":"abc","notification_type":"idle_prompt"}`,
			model.Event{}, false},
		{"claude session end", "claude",
			`{"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/w","reason":"prompt_input_exit"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvSessionEnd}, true},
		{"claude pre tool use", "claude",
			`{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/w","tool_name":"Bash"}`,
			model.Event{Agent: "claude", SessionID: "abc", Cwd: "/w", Kind: model.EvTool}, true},
		{"kiro v3 session start", "kiro",
			`{"hook_event_name":"SessionStart","session_id":"k1","cwd":"/w"}`,
			model.Event{Agent: "kiro", SessionID: "k1", Cwd: "/w", Kind: model.EvSessionStart}, true},
		{"kiro camelCase fields", "kiro",
			`{"hookEventName":"agentSpawn","sessionId":"k1","cwd":"/w"}`,
			model.Event{Agent: "kiro", SessionID: "k1", Cwd: "/w", Kind: model.EvSessionStart}, true},
		{"kiro lower-case stop", "kiro",
			`{"hook_event_name":"stop","session_id":"k1","cwd":"/w"}`,
			model.Event{Agent: "kiro", SessionID: "k1", Cwd: "/w", Kind: model.EvStop}, true},
		{"unknown event ignored", "claude",
			`{"hook_event_name":"PostToolUse","session_id":"abc"}`,
			model.Event{}, false},
	}
	for _, c := range cases {
		got, ok, err := Normalize(c.agent, []byte(c.payload))
		if err != nil {
			t.Errorf("%s: unexpected error %v", c.name, err)
			continue
		}
		if ok != c.ok || got != c.want {
			t.Errorf("%s: got %+v ok=%v, want %+v ok=%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestNormalizeRejectsBadJSON(t *testing.T) {
	if _, _, err := Normalize("claude", []byte("not json")); err == nil {
		t.Fatal("expected error")
	}
}

func TestTruncate(t *testing.T) {
	long := strings.Repeat("é", 100)
	got := Truncate(long, 80)
	if n := len([]rune(got)); n != 80 {
		t.Fatalf("len = %d runes", n)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("missing ellipsis: %q", got)
	}
	if got := Truncate("short", 80); got != "short" {
		t.Fatalf("short string changed: %q", got)
	}
}
